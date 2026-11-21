# TillRoad 本地优先数据架构设计

| 项目 | 值 |
| --- | --- |
| 版本 | v1.0（设计评审稿） |
| 日期 | 2026-11-21 |
| 范围 | Flutter 客户端数据读取路径改造（只读设计，不含实现） |
| 依据代码 | `tillroad_app/`（42 个 dart 文件）、`server/`（12 个路由模块 / 9 个仓储）、`schema.sql`（840 行，v0.3-schema1） |
| 前置约束 | 不改后端任何文件、不改 schema、不引运行时新依赖（本轮）、不写实现代码 |

---

## 0. 摘要与边界

### 0.1 问题与目标

现状：每个页面在 `initState` 里直接打云端，且都是「首屏阻塞」式加载。

- 首页 `Future.wait` 3 个请求；验证页 2 个；缺陷单列表 1 个全量；模考页**串行** 3 个；组卷页**瀑布** 3 连（profiles → subjects → knowledge-nodes）。
- 后端部署在 Railway，数据库是 Neon Serverless。Neon 空闲后实例休眠，**冷启动需要 10–30 秒**才接受连接；`ApiClient` 的超时是 **15 秒**（`lib/config/api_config.dart` 的 `kApiTimeout`），因此冷启动窗口内打开任何页面都可能直接抛 `TimeoutException`，用户看到的是「加载失败 + 重试」。
- 更糟的是 `mock_create_page.dart` 的三连瀑布：三个请求各自 15 秒超时上限，最坏情况一个页面要等 45 秒才判定失败。

目标（本轮设计的目标状态）：

> **读走本地 SQLite，云端降级为「后台同步通道 + 写入通道」。**
> 页面打开先渲染本地已有数据（毫秒级），再后台静默刷新；网络不可用时页面依然可用（只读）。

### 0.2 设计原则

1. **本地表是云端表的投影**，不是第二套业务模型。字段名与云端一致（snake_case），派生逻辑（urgency、完成率）在客户端复算，不新增业务概念。
2. **云端仍是唯一事实来源（single source of truth）**。本地是缓存 + 待发送队列，任何时候清空本地库都不应丢数据（除尚未推送成功的写操作，见 §3.4 的失败语义）。
3. **写操作不静默丢失**。离线写入进入 `pending_operations`，联网逐条推送；推送失败保留并可见，用户可在设置页看到积压数。
4. **冲突显式暴露给用户**，不做自动合并（任务书 Q6）。
5. **不引入第二套 schema 真理**：本地 DDL 与 `schema.sql` 的字段名/枚举值逐字对齐；本地**不创建**任何云端没有的业务列（除同步元数据列，见 §2.1）。

### 0.3 明确不做（对应任务书 Q6）

| 不做 | 理由 |
| --- | --- |
| 实时多端协作（CRDT / OT） | 单用户单设备场景，token 体系下同一账号多设备属于低频，冲突用「用户选择」解决即可，CRDT 的成本与收益完全不匹配 |
| WebDAV / 网盘同步 | 这是「备份/导入导出」功能，与「读加速」正交，混在一起会让同步层职责发散 |
| 登录系统改造 | token 方案不变；`Authorization: Bearer` 与 `shared_preferences['api_token']` 继续用 |
| 云端表结构变更 | 本地是投影，`schema.sql` 冻结。**注意**：本轮设计里凡需要「增量拉取」的地方，都建立在「没有 `updated_since` 参数」这一现实上（见 §3.5），不假设后端会加字段 |
| 离线写入的自动合并 | 冲突时让用户选择「保留本地 / 保留云端」 |
| 离线创建模考卷 | 组卷是服务端 `ORDER BY random() LIMIT n`（`server/repositories/mock_exams.mjs:141`），客户端无法复现 → 必须在线（见 §4） |
| 离线生成复盘 | metrics 是服务端六项 SQL 聚合（`server/review_stats.mjs`），客户端不复现 → 必须在线 |
| 本地存题目答案与解析 | `schema.sql:225` 的 `questions.answer` / `questions.analysis` 属敏感内容；后端序列化已经剔除（`HIDDEN_FIELDS = ['answer','analysis']`，`server/routes/mock_exams.mjs:167`）。本地缓存沿用同一原则，**只存题干摘要** |

---

## 1. 当前请求清单

### 1.1 读端点

「触发时机」= 代码里实际调用位置；「频次」按单次会话估算（用户正常使用 3–5 分钟）。
「可离线」= 该请求的响应能否安全落到本地并长期复用；「必须实时」= 数据陈旧是否会直接导致错误行为或错误决策。

| # | 端点 | 调用页面 / 位置 | 触发时机 | 频次 | 可离线 | 必须实时 |
| --- | --- | --- | --- | --- | --- | --- |
| R1 | `GET /health` | `lib/main.dart` `_prewarm()` | App 启动一次 | 1 / 会话 | ❌ 是探活本身 | 否（失败静默） |
| R2 | `GET /users/:id/exam-profiles` | `home_page`、`mock_page:66`、`mock_create_page:87`、`defects_page`（建单入口）、`profile_page` | 首页/模考/组卷/建单/我的 打开时 | 4–6 / 会话 | ✅ | 否（考试日期是天级数据） |
| R3 | `GET /exam-profiles/:id/subjects` | `mock_create_page:117`、建单页 | 选完目标后 | 1–2 | ✅ | 否 |
| R4 | `GET /subjects/:id/knowledge-nodes` | `mock_create_page:145`、`defect_create_page:85` | 选完科目后 | 1–2 | ✅ | 否（考点是静态目录） |
| R5 | `GET /users/:id/defect-tickets` | `defects_page._load()` | 缺陷单页打开 / 筛选切换（实际只在打开时拉一次，筛选是内存过滤） | 1–3 | ✅ | 否（但要能及时看到别人…单用户，见下） |
| R6 | `GET /defect-tickets/:id` | `defect_detail_page:59`、`defect_analyze_page:153`、`defect_verify_page:132`、`verify_page._openDetail`、`mock_report_page`（V3 候选） | 进详情 / **每次写操作前** | **5–8 / 会话** | ✅ 只读 | 读否；**写前那次必须实时**（拿 version） |
| R7 | `GET /users/:id/defect-stats` | `home_page._loadStats()`、`profile_page:562` | 首页 / 我的 打开时 | 2–3 | ✅（可本地算，见 §2.4） | 否 |
| R8 | `GET /users/:id/verification-tasks` | `verify_page._load()` | 验证页打开 / **每次切换筛选** | 2–5 | ✅（urgency 可本地复算） | 否（窗口按天计） |
| R9 | `GET /users/:id/verification-summary` | `home_page`、`verify_page`、`profile_page` | 首页/验证/我的 | 3–4 | ✅（本地聚合） | 否 |
| R10 | `GET /exam-profiles/:id/mock-exams?submitted=true` | `mock_page:83` | 模考页打开 | 1 | ✅ | 否 |
| R11 | `GET /exam-profiles/:id/mock-exams`（未提交残留） | `mock_page:84` | 模考页打开 | 1 | ✅ | 否 |
| R12 | `GET /mock-exams/:id` | `mock_api.dart` 的 `fetchMockExam`（1 处） | 进入答题页时刷新卷面 | 1 / 卷 | ✅ | **是**（卷面题目必须与云端一致） |
| R13 | `GET /mock-exams/:id/report` | `mock_exam_page` 提交后 | 交卷后 | 1 / 卷 | ✅（提交后可缓存） | 是（但如果提交刚返回，报告已在响应里） |
| R14 | `GET /review-cycles?user_id=…&limit=100` | `review_page._load()` | 复盘页打开 / 生成后刷新 | 1–2 | ✅ | 否 |
| R15 | `GET /review-cycles/:id` | `review_page`（409 冲突时取 existing_id） | 重复生成时 | 0–1 | ✅ | 是（要看最新 metrics） |

**合计**：一次冷启动到「我的」页逛一圈，约 **18–25 个请求**。其中 R2/R5/R6/R7/R8 是主力。

### 1.2 写端点

| # | 端点 | 调用位置 | 是否可离线排队 | 说明 |
| --- | --- | --- | --- | --- |
| W1 | `POST /defect-tickets` | `defect_create_page:183` | ✅ 可 | 服务端生成 id + 事务内写 actions 行；离线需本地临时 id（§3.3） |
| W2 | `POST|PATCH /defect-tickets/:id/analyze` | `defect_analyze_page:184` | ✅ 可 | DRAFT→ANALYZED 或 REOPENED→ANALYZED；服务端会 +verification_round |
| W3 | `PATCH /defect-tickets/:id/actions/:actionId` | `defect_detail_page:133` | ✅ 可 | 勾选动作完成；不推进主单 version（子表行） |
| W4 | `PATCH /defect-tickets/:id/begin-verification` | `defect_detail_page:156` | ⚠️ 谨慎 | 服务端**同事务两跳**（ACTION_DONE→V1），返回 version 跳 2；离线排队后本地必须预测两跳 |
| W5 | `POST /defect-tickets/:id/verifications` | `defect_verify_page:160` | ⚠️ 谨慎 | 推进 V1→V2 或 →REOPENED / V3→CLOSED，派生列（reopen_count / closed_at）由触发器维护 |
| W6 | `POST /mock-exams` | `mock_create_page:182` | ❌ 不可 | 随机抽题在服务端 |
| W7 | `POST /mock-exams/:id/submit` | `mock_exam_page` | ❌ 不可 | 报告计算在服务端事务内 |
| W8 | `POST /review-cycles` | `review_page` | ❌ 不可 | 六项聚合在服务端 |
| W9 | `PATCH /review-cycles/:id` | `review_detail_page` | ✅ 可 | 只改 `completed` |
| W10 | `DELETE /review-cycles/:id` | `review_detail_page` | ✅ 可 | 软删，需 base_version |

所有写请求都要求 `version`（乐观锁，0 行命中 → 409 `client_merge`）。这是本地队列设计的关键约束：**排队中的第二条写操作，其 `base_version` 在第一条落地前是未知的**（服务端每写一次 +1，`set_updated()` 触发器无条件递增）。

### 1.3 代码里存在但当前未被调用的端点

`GET /subjects/:id/knowledge-tree`、`POST /questions/import`、`POST /ai/questions:generate`、capability_layers 全部端点 —— 客户端 0 引用。**本地优先设计不为它们建表**（需要时再加）。

### 1.4 现状量化（为什么必须改）

| 场景 | 现状 | 目标 |
| --- | --- | --- |
| 冷启动进首页 | 3 请求并发，任一路超时 → 该卡片降级；全部超时 → 三块全空 | 本地读 < 50ms 出全量，后台刷新 |
| 进验证页切筛选 | 每次切都打后端（`_applyUrgency` → `_load()`），Neon 冷时每次 10–30s | 本地过滤，0 网络 |
| 进模考页 | 串行 3 请求 = 3×RT；冷启动最坏 45s | 本地读，后台串行刷新 |
| 进组卷页 | 瀑布 3 连，最坏 45s | 本地读 3 张缓存表，0 网络 |
| 断网 | 全部页面显示「加载失败」 | 只读页面全部可用（读本地） |

---

## 2. 本地表结构设计

### 2.1 通用约定

**同步元数据列（本地独有，云端没有）** —— 每张被同步的表都加这三列：

| 列 | 类型 | 含义 |
| --- | --- | --- |
| `local_id` | TEXT PRIMARY KEY | 客户端生成的 UUID v4（离线可创建）。**本地所有外键指向它** |
| `server_id` | TEXT UNIQUE NULL | 云端主键；未推送过的本地新建行为 NULL |
| `sync_state` | INTEGER NOT NULL DEFAULT 0 | 0=synced / 1=pending_create / 2=dirty / 3=pending_delete / 4=conflict |

> **为什么需要 `local_id` 与 `server_id` 两套主键**：`POST /defect-tickets` 的入参**不接受 `id`**（`server/repositories/defect_tickets.mjs` 的 `INSERT_COLUMNS` 不含 `id`，主键走 `DEFAULT gen_random_uuid()`）。离线建单必须先有主键才能写 `actions`/`verifications` 子行；离线推送成功后云端返回真实 id，若此时改本地主键就要级联改所有子表与队列里的 payload。用「本地键不变 + 另存 server_id」把这次改写压缩成一次 UPDATE。

**其余列**：与云端同名同语义，时间列一律存 **ISO 8601 UTC 字符串**（TEXT），由 `DateTime.parse(...).toLocal()` 消费 —— 与 `defect_api.dart:215` 的 `_date` 现有行为一致，避免 int 毫秒与时区二次转换。

**软删语义**：云端 `deleted_at` 列在本地保留；但**本地不存已被服务端软删的行**（列表接口已过滤 `deleted_at IS NULL`）。全量拉取对账时，本地存在而拉取结果不存在的行直接物理删除（前提：该行 `sync_state = 0`，见 §3.5）。

**枚举**：与 `schema.sql` 逐字一致，存 TEXT。
- `defect_status`：`DRAFT` / `ANALYZED` / `ACTION_DONE` / `V1` / `V2` / `V3` / `CLOSED` / `REOPENED`
- `verify_stage`：`V1` / `V2` / `V3`；`verify_result`：`pass` / `fail` / `pending`
- `priority_level`；`difficulty`：`easy` / `medium` / `hard`；`cycle_type`：`weekly` / `daily` / `monthly`

### 2.2 表清单

| # | 本地表 | 来源 | 是否实现 | 备注 |
| --- | --- | --- | --- | --- |
| T1 | `exam_profiles` | R2 | 全量 | 每用户 1–5 行 |
| T2 | `subjects` | R3 | 全量 | 跟随 profile |
| T3 | `knowledge_nodes` | R4 | 全量 | 静态目录，可按 subject 增量更新 |
| T4 | `defect_tickets` | R5 + R6 | **精简**（去重 jsonb） | 核心表 |
| T5 | `defect_actions` | R6 的 `actions` | 从表 | 云端 `actions` 表投影 |
| T6 | `verifications` | R6 的 `verifications` | 从表 | 决定 V1/V2/V3 显示 |
| T7 | `questions_cache` | R12/R13 的题目 | **摘要** | 无 answer/analysis |
| T8 | `mock_exams` | R10/R11/R12/R13 | 精简 | `questions`/`report` 存 JSON TEXT |
| T9 | `review_cycles` | R14/R15 | 精简 | `metrics` 存 JSON TEXT |
| T10 | `pending_operations` | — | 本地独有 | 写队列 |
| T11 | `sync_state` | — | 本地独有 | 每资源的拉取水位 |

### 2.3 逐表字段

#### T1 `exam_profiles`

| 本地列 | 云端列（`schema.sql:163`） | 差异 / 理由 |
| --- | --- | --- |
| `local_id` / `server_id` / `sync_state` | — | 同步元数据 |
| `user_id` TEXT | `user_id` | 原样（token 决定，客户端只读） |
| `exam_type` TEXT | `exam_type` enum | 原样 |
| `target_label` TEXT | `target_label` | 原样 |
| `target_score` REAL | `target_score numeric(6,2)` | SQLite 无 numeric，用 REAL；展示时 `toStringAsFixed(2)` |
| `subject_target` TEXT | `subject_target jsonb` | JSON 原文 |
| `exam_date` TEXT | `exam_date date` | `YYYY-MM-DD` |
| `daily_minutes` INTEGER | `daily_minutes` | |
| `source_scope` TEXT / `baseline` TEXT | jsonb | JSON 原文 |
| `status` TEXT | `status` CHECK('active','archived') | 原样 |
| `created_at` / `updated_at` TEXT | timestamptz | ISO 8601 |
| `version` INTEGER | `version` | 乐观锁；本地写队列要用 |
| ~~`deleted_at`~~ | `deleted_at` | **不落本地**：服务端软删 = 本地删行 |

索引：`CREATE UNIQUE INDEX ux_ep_server ON exam_profiles(server_id);`、`idx_ep_user ON exam_profiles(user_id, status)`

#### T2 `subjects`

| 本地列 | 云端（`:183`） | 差异 |
| --- | --- | --- |
| 同步三列 | — | |
| `exam_profile_id` TEXT | 同 | **存 cloud id**（不是 local_id），因为 subjects 一定来自云端、先有 profile 后有 subject |
| `name` / `kind` / `layer_template_id` | 同 | `kind` 存 TEXT |
| `created_at` / `updated_at` / `version` | 同 | |

> **投递关系简化**：T2/T3 属于「只读目录表」，永不在本地创建，因此外键直接用 `server_id` 语义的 TEXT，不设 local_id 关联。只有 T4 及其子表需要 local_id 双键。

索引：`uq_sub_server(server_id)`、`idx_sub_ep(exam_profile_id)`

#### T3 `knowledge_nodes`

| 本地列 | 云端（`:197`） | 差异 |
| --- | --- | --- |
| 同步三列 | — | |
| `subject_id` / `title` / `parent_id` | 同 | |
| `freq_tag` TEXT | CHECK('high','mid','low') | |
| `weight_to_target` REAL | numeric(4,3) | |
| 时间/版本列 | 同 | |

索引：`uq_kn_server(server_id)`、`idx_kn_subject(subject_id)`、`idx_kn_parent(parent_id)`

#### T4 `defect_tickets`（核心）

| 本地列 | 云端（`:292`） | 差异 / 理由 |
| --- | --- | --- |
| `local_id` PK / `server_id` UNIQUE / `sync_state` | — | 见 §2.1 |
| `user_id` | `user_id` | |
| `exam_profile_id` | `exam_profile_id` | **存 server_id 语义的 TEXT**（profile 必来自云端） |
| `knowledge_node_id` | `knowledge_node_id` | 可空 |
| `question_id` | `question_id` | 可空 |
| `q_type` | `q_type` | 可空 TEXT |
| `error_layer` / `error_cause` | 同 | 可空（DRAFT 允许 null，P0-3） |
| `priority` | `priority_level` enum | TEXT |
| `status` | `defect_status` | TEXT |
| `verification_round` INTEGER NOT NULL DEFAULT 1 | 同 | **必须存**：`verifications` 的 round 过滤靠它 |
| `reopen_count` INTEGER DEFAULT 0 | 同 | |
| `reopen_reason` | 同 | |
| `closed_at` | 同 | |
| `created_at` / `updated_at` / `version` | 同 | `version` 是写队列的乐观锁基准 |
| **不落** `actions` jsonb | `defect_tickets.actions` | 云端这列是**冗余快照**，规范化行在 `actions` 表（`defect_tickets.mjs:111` 注释）。本地读子表 T5 |
| **不落** `verification_state` jsonb | 云端该列实测恒 `{"v1":"pending",...}` | 客户端已改为从 `verifications` 数组推导（`defect_api.dart:142 _verifyResults`）。本地同样只用 T6 |
| **不落** `knowledge_node_title` / `subject_name` / `knowledge_node_freq_tag` | 服务端 JOIN 出的展示字段 | 本地 JOIN T3/T2 得到，避免冗余不一致 |
| ~~`deleted_at`~~ | | 不落；拉取对账时删行 |

索引（对齐真实查询）：
```sql
CREATE UNIQUE INDEX ux_dt_server ON defect_tickets(server_id);
CREATE INDEX idx_dt_user_status ON defect_tickets(user_id, status);
CREATE INDEX idx_dt_created ON defect_tickets(created_at ASC, local_id ASC); -- 对齐服务端 ORDER BY created_at ASC
CREATE INDEX idx_dt_node ON defect_tickets(knowledge_node_id);
CREATE INDEX idx_dt_sync ON defect_tickets(sync_state) WHERE sync_state <> 0;
```
> 为什么按 `created_at ASC` 建索引：服务端 `listByUser` 就是 `ORDER BY dt.created_at ASC, dt.id ASC`（`defect_tickets.mjs:222`）。本地必须复现同一顺序，否则列表顺序会跳。

#### T5 `defect_actions`

| 本地列 | 云端（`:320`） | 差异 |
| --- | --- | --- |
| `local_id` PK / `server_id` UNIQUE / `sync_state` | — | 离线建单时动作也需本地键 |
| `defect_ticket_local_id` TEXT NOT NULL | `defect_ticket_id` | **指向 T4.local_id** |
| `content` TEXT | 同 | |
| `done` INTEGER (0/1) | bool | SQLite 无 bool |
| `due` TEXT | timestamptz | |
| `created_at` / `updated_at` / `version` | 同 | PATCH 动作完成需要 version |

索引：`uq_act_server(server_id)`、`idx_act_ticket(defect_ticket_local_id)`

#### T6 `verifications`

| 本地列 | 云端（`:334`） | 差异 |
| --- | --- | --- |
| `local_id` PK / `server_id` UNIQUE / `sync_state` | — | |
| `defect_ticket_local_id` TEXT NOT NULL | `defect_ticket_id` | 指向 T4.local_id |
| `stage` TEXT | `verify_stage` | `V1`/`V2`/`V3` |
| `round` INTEGER NOT NULL DEFAULT 1 | 同 | **唯一键的一半** |
| `verify_type` TEXT | `verify_type` enum | `redo_hidden` 等 |
| `question_id` TEXT | 同 | 可空 |
| `result` TEXT | `verify_result` | `pass`/`fail`/`pending` |
| `evidence` TEXT | 同 | 可空 |
| `verified_at` | 同 | |
| `created_at` / `version` | 同 | |

索引（对齐云端唯一约束 `idx_ver_dt_stage`）：
```sql
CREATE UNIQUE INDEX ux_ver_ticket_stage_round
  ON verifications(defect_ticket_local_id, stage, round);
```
> 本地也建唯一索引：云端 409 重复提交在本地应先行拦截（体验更好），否则要等一次往返。

#### T7 `questions_cache`（摘要，**不含答案**）

| 本地列 | 云端（`:225`） | 差异 / 理由 |
| --- | --- | --- |
| `server_id` TEXT PRIMARY KEY | `id` | 题目永不在本地创建，不需要 local_id |
| `subject_id` / `knowledge_node_id` | 同 | |
| `type` TEXT | 同 | |
| `stem` TEXT | 同 | 题干全文（用于模考报告里回看题目） |
| `options` TEXT | `options jsonb` | JSON 原文 |
| `difficulty` TEXT | enum | |
| `is_subjective` INTEGER | bool | |
| `tags` TEXT | jsonb | |
| **不落** `answer` / `analysis` | 同 | **敏感**：协议上服务端序列化已剔除（`HIDDEN_FIELDS`）；本地若存等于绕过该保护 |
| **不落** `formula_text` / `asset_refs` / `content_hash` / `generation_meta` | 同 | 客户端当前不使用 |

索引：`idx_q_node(knowledge_node_id)`、`idx_q_subject(subject_id)`

> 写入时机：只在 `GET /mock-exams/:id` 或组卷响应里出现题目时缓存；不做独立同步。旧题目用 LRU 上限（建议 2000 行）裁剪。

#### T8 `mock_exams`

| 本地列 | 云端（`:354`） | 差异 |
| --- | --- | --- |
| `server_id` TEXT PRIMARY KEY | `id` | 卷子永远在云端创建 → 无需 local_id |
| `exam_profile_id` TEXT | 同 | |
| `mode` TEXT | `module`/`full` | |
| `duration_limit_ms` INTEGER | 同 | |
| `questions` TEXT | `mock_exams.questions jsonb` | **JSON 原文**：`[{question_id, attempt_id, is_correct, duration_ms}]`。这里存的是「条目」不是题面，题面在 T7 |
| `report` TEXT | `report jsonb` | JSON 原文；NULL = 未提交 |
| `submitted_at` TEXT | 由 report/attempts 派生 | 客户端 `MockExam.submittedAt` 字段，本地保留 |
| 时间/版本列 | 同 | |

索引：`idx_me_profile(exam_profile_id, created_at DESC)`

#### T9 `review_cycles`

| 本地列 | 云端（`:369`） | 差异 |
| --- | --- | --- |
| `server_id` TEXT PRIMARY KEY | `id` | 复盘在云端生成 → 无需 local_id |
| `user_id` / `cycle_type` / `period` | 同 | |
| `metrics` TEXT | `metrics jsonb` | JSON 原文（体积较大，见 §4 的刷新策略） |
| `completed` INTEGER | bool | |
| 时间/版本列 | 同 | |

索引：`uq_rc_user_type_period(user_id, cycle_type, period)`（对齐云端 `idx_rc_user`）、`idx_rc_period(period DESC)`

#### T10 `pending_operations`（本地独有）

| 列 | 类型 | 说明 |
| --- | --- | --- |
| `op_id` | INTEGER PK AUTOINCREMENT | 单调递增 = 全局发送顺序 |
| `entity` | TEXT | `defect_ticket` / `defect_action` / `verification` / `review_cycle` |
| `entity_local_id` | TEXT | 指向对应表的 local_id |
| `method` | TEXT | `POST` / `PATCH` / `DELETE` |
| `path` | TEXT | **推送时**才拼出真实 URL（因为 server_id 可能当时才拿到） |
| `path_template` | TEXT | 如 `/defect-tickets/{server_id}/analyze`，占位符在推送时替换 |
| `payload` | TEXT | JSON；`{}` 表示无 body |
| `base_version` | INTEGER NULL | 乐观锁基准；NULL 表示服务端当时也不需要（如 POST 建单） |
| `status` | INTEGER | 0=pending / 1=inflight / 2=failed_retryable / 3=conflict / 4=dead |
| `attempts` | INTEGER DEFAULT 0 | |
| `next_retry_at` | TEXT NULL | 指数退避 |
| `last_error` | TEXT NULL | 存 `ApiException.message` + statusCode |
| `created_at` | TEXT | |

索引：`idx_po_status_next(status, next_retry_at)`、`idx_po_entity(entity, entity_local_id, op_id)`

#### T11 `sync_state`（本地独有）

| 列 | 类型 | 说明 |
| --- | --- | --- |
| `resource` | TEXT PK | `exam_profiles` / `subjects` / `knowledge_nodes` / `defect_tickets` / `mock_exams` / `review_cycles` |
| `last_full_pull_at` | TEXT | 上次**完整**全量拉取成功时间 |
| `last_success_at` | TEXT | 上次任一成功拉取 |
| `last_error` | TEXT | |
| `last_server_max_updated_at` | TEXT NULL | 从拉取结果里算出的最大 `updated_at`（客户端的「软游标」，见 §3.5） |
| `row_count` | INTEGER | 便于设置页展示与调试 |

### 2.4 派生数据在客户端复算（不落表）

| 派生值 | 云端算法 | 本地实现 | 依据 |
| --- | --- | --- | --- |
| `urgency` / `daysLeft` / `overdueDays` | `server/verify_window.mjs` `computeUrgency`：`V1=7 / V2=14 / V3=21` 天，`DUE_SOON_DAYS=3`，`elapsed = floor((now-start)/86400000)`，`daysLeft<=0→overdue`、`<=3→due_soon` | **移植同一套纯函数**到 `lib/data/verification_window.dart`（常量抄 `VERIFY_WINDOWS`，逐行同算法） | 若不移植，离线时只能显示「未知」，把离线能力砍掉一半 |
| `entered_at`（进入当前验证态的时刻） | SQL：V2/V3 取「本 round 上一 stage pass 的 `created_at`」，V1 退化用 `updated_at` | 本地同源：查 T6 同 `round` 的上一 stage `pass` 行的 `verified_at`（优先）→ 无则取 T4.`updated_at` | 与云端一致的**已知偏差**：V1 被 patch 过会把「已过天数」少算，方向是「宁可晚报，不误报逾期」 |
| `defect-stats`（八态计数 + layer 分布） | `defectStats` SQL GROUP BY | 本地 `SELECT status, count(*) ... GROUP BY status`；layer 用 `COALESCE(NULLIF(trim(error_layer),''),'unclassified')` 且 `status <> 'CLOSED'` | 完全可复现 |
| `verification-summary` | 复用 `listVerificationTasks` 再内存聚合 | 本地同一份过滤后内存聚合 | 数字必须与列表页一致 |
| 验证完成率（我的页） | 前端 `CLOSED / total`（`profile_page.dart`） | 不变，读本地 | |
| `doneActionCount` / `currentStage` | 前端 getter | 不变 | |

> ⚠️ 一处必须写进代码注释的风险：`verify_window.mjs` 的窗口天数是**服务端口径**。若将来后端改了 `VERIFY_WINDOWS`，客户端副本会漂移。缓解：把常量放进 `kVerifyWindows` 并在设置页「关于 → 诊断」里显示，便于线上比对。

---

## 3. 同步策略

### 3.0 本地存储选型（Drift vs sqflite）

| 维度 | sqflite | Drift |
| --- | --- | --- |
| 新增依赖 | `sqflite`（1 个直接依赖） | `drift` + `drift_flutter` + `sqlite3_flutter_libs` + dev `drift_dev` + `build_runner`（5 个） |
| 代码生成 | 无 | 必需（`build_runner`），与仓库「手写 snake_case 映射、不引 json_serializable」的既有取向**相反** |
| 类型安全 | 手写 `Map<String,Object?>` → 模型 | 编译期生成，强 |
| 迁移管理 | 手写 `onUpgrade` 版本号 | `MigrationStrategy`，更强 |
| 复杂查询 | 原生 SQL 字符串（本项目查询都很简单：`WHERE`/`ORDER BY`/`GROUP BY`） | Dart DSL 或自定义 SQL |
| Windows 桌面 | 需 `sqflite_common_ffi`（额外 1 个 + 原生 sqlite3） | `sqlite3_flutter_libs` 已覆盖桌面 |
| 与现有测试风格 | 可直接用内存库 + 手写 DAO 断言 | 需要 codegen 产物入库 |

**结论：选 sqflite（+ 仅测试用的 `sqflite_common_ffi`）。**

理由：
1. 本设计的本地查询一共约 15 条，全是单表过滤 + 一次 JOIN + 两次 GROUP BY，**不需要 ORM 的表达力**。
2. 仓库的既有取向是「少依赖、手写映射」。引入 `build_runner` 会给每次 `flutter test` 增加一个生成步骤，与当前「`flutter analyze` 0 error + `flutter test` 秒级」的稳定状态冲突。
3. Drift 的类型安全收益，可以被「DAO 层单元测试 + `sqlite3` 的真实执行」覆盖（本仓库已经用 PGlite 做过同类验证）。

**已知限制（必须写进实现提示词）**：`sqflite` 只在 Android/iOS 可用。仓库有 `windows/` 平台。选项：
- (a) 加 `sqflite_common_ffi` 并在 `main()` 里按平台 `databaseFactory = databaseFactoryFfi` —— **多 1 个依赖**；
- (b) 本轮只保证 Android/iOS，Windows 桌面退回「无本地库，直连云端」模式（`kLocalFirstEnabled = Platform.isAndroid || Platform.isIOS`）。

推荐 (b) 作为 MVP 范围，Windows 的本地库留到后续（§7 拍板问题 5）。

### 3.1 首次全量同步

**触发条件**（三者同时满足）：
1. `sync_state` 表为空 或 所有 `last_full_pull_at IS NULL`；
2. 有 token（`hasApiToken`）；
3. 网络可达（`GET /health` 成功，或首次请求不超时）。

**顺序（严格）：**

```
① GET /users/:id/exam-profiles            （limit=200，1 页）
② for each exam_profile:
     GET /exam-profiles/:id/subjects       （limit=200）
③ for each subject:
     GET /subjects/:id/knowledge-nodes     （limit=200，page until len<limit）
④ GET /users/:id/defect-tickets           （limit=200，page until len<limit）
     for each ticket（可并发限 3）:
       GET /defect-tickets/:id            ← 为拿 verifications + actions
⑤ GET /exam-profiles/:id/mock-exams       （limit=200，page until len<limit）
⑥ GET /review-cycles?user_id=…&limit=200 （page until len<limit）
```

**为什么必须「先父后子」**：本地 T4 的 `exam_profile_id` / `knowledge_node_id` 存的是云端 id，如果先拉缺陷单再拉 knowledge_nodes，列表页会短暂显示「考点 <uuid 前 8 位>」占位（`defect_api.dart:101` 的兜底逻辑）。先父后子可避免这个视觉抖动。

**分批 vs 一次性**：
- 列表接口 `limit` 上限 **200**（`server/repositories/_common.mjs:180` 的 `pageParams`：合法范围 1–200，越界回落默认 50）。
- 用户数据规模：缺陷单 10–100 条、模考 20–50 卷、复盘 20–100 条。**全部可一两页拉完**，不需要复杂的分页调度。
- 但 `defect-tickets` **没有 `total` 字段**（`routes/defect_tickets.mjs:282` 只返回 `items/limit/offset`），`mock-exams` 的 `total` 是 `items.length`（假 total，`routes/mock_exams.mjs:155`）。**分页终止条件只能是「本页 `items.length < limit`」**，不能信 `total`。
- 单条详情（④ 内层）是 N 次请求，N = 缺陷单条数。这是首启最慢的部分：100 单 = 100 请求。**优化**：内层并发 3、失败跳过（下次增量补），并把首页的 3 个请求排在「列表级同步完成」之后立刻执行，让用户先看到可用界面。

**UI 表现（推荐）**：
- 启动**不阻塞**：进 RootTabs，首页正常显示骨架屏；同时在导航栏下方显示一条 **3px 细进度条**（`SyncBanner`：`正在首次同步 12/34`）。
- 各页面在本地无数据时显示 `EmptyState`，文案区分两种情况：
  - 首次同步进行中 →「正在从云端同步…」（带 spinner）
  - 首次同步失败 →「同步失败，点此重试」（带 `SyncErrorBanner` 的重试按钮）
- 设置页 → 新增「数据同步」分区：上次同步时间 / 本地行数 / 待推送数 / 手动「立即同步」。

### 3.2 写入排队（`pending_operations`）

**入队规则**：页面写操作统一走 `SyncQueue.enqueue(...)`，本地立即生效（乐观 UI），网络部分异步：

```
用户点「标记完成」
  → 本地 UPDATE defect_actions SET done=1, sync_state=2
  → INSERT pending_operations(method=PATCH,
        path_template='/defect-tickets/{ticketServerId}/actions/{actionServerId}',
        payload={}, base_version=<该 action 的 version>)
  → 返回，UI 立即更新
  → SyncEngine 唤醒（若在线，500ms 内开始推送）
```

**关键设计点 1：`base_version` 的级联问题**

服务端每次写都会 `version+1`（`set_updated()` 触发器）。若一个缺陷单排队了 3 条写操作，第 2、3 条的 `base_version` 在第 1 条落地前是错的。

处理方式：**同一实体的操作严格串行推送，且推送时重算版本**。
- `pending_operations` 里 `base_version` 记为「入队时本地已知的 version」，仅用于**冲突检测的初始判断**；
- 实际发送时，若同实体上一条刚成功，则用「上一条响应里返回的 `version`」覆盖本条 `base_version`；
- 若同实体上一条还在 `inflight`，本条**等待**（同实体队头阻塞，不同实体可并行——但 MVP 建议全局串行，简单且量小）。

**关键设计点 2：本地创建 → server_id 映射**

```
离线建单：
  local_id = uuid v4（客户端生成）
  T4 INSERT (local_id, server_id=NULL, sync_state=1, status='ANALYZED', version=1)
  T5 INSERT 每个 action (local_id=..., defect_ticket_local_id=local_id, done=0)
  pending_operations INSERT (entity=defect_ticket, method=POST,
      path_template='/defect-tickets', payload={...}, base_version=NULL)

推送 POST /defect-tickets 成功（201 返回裸行，含 id/version/actions[]）：
  ① T4: server_id = resp.id, sync_state=0, version=resp.version
  ② 把本地临时 actions 与响应里的 actions 对齐：
     - 响应 actions 是按插入顺序返回的，条数与本地相同 → 按序回填 server_id
     - 若条数不同（理论上不会）→ 以响应为准，删除多出的本地行
  ③ 队列里所有 path_template 含 {ticketServerId} 的后续操作，推送前解析到 server_id
```

> 为什么不在推送成功后改本地主键：会让 T5/T6 的外键、队列里的 payload、以及任何已打开页面的对象引用全部失效。成本远高于「多一列 server_id」。

**重试与退避**：
- `2xx` → 删除队列行，本地 `sync_state=0`。
- `409`（`{error:'conflict', current, incoming, resolution:'client_merge'}`）→ `status=3 (conflict)`，**该实体后续操作全部暂停**，UI 弹冲突卡片（§3.4）。
- `400`（业务校验，如 `FORBIDDEN_PHRASE_IN_ERROR_CAUSE` / `ACTIONS_NOT_DONE` / `MISSING_ERROR_LAYER_OR_CAUSE`）→ `status=4 (dead)`。**这类不可重试**：本地已经做了同样的前置校验（`core/index.mjs` 的纯函数已移植？—— 注意：客户端目前**没有**移植这些校验，见 §6 的技术债），所以理论上不该发生；一旦发生说明本地校验有洞，需要提示用户「该操作被服务端拒绝：<message>」并**回滚本地乐观修改**。
- 网络错误 / 超时 / 5xx → `status=2`，`attempts+1`，`next_retry_at = now + min(2^attempts * 5s, 5min)`，最多 8 次后转 `4 (dead)` 并在设置页显示「N 条操作待处理」。

**幂等性**：`POST /defect-tickets` 不幂等（服务端每次新建一行）。因此「请求已到达但响应丢失」的情形会重复建单。缓解：
- 队列行在发送前先标记 `inflight` 并持久化；
- 恢复后遇到 `inflight` 且**未确认**的行，先做一次「对账探测」：拉 `GET /users/:id/defect-tickets`，比对 `created_at` 在最近 5 分钟内、`error_cause` + `q_type` 完全相同的行 → 若找到则视为已成功，回填 server_id 并删除队列行；
- MVP 可接受「极少数重复单需用户手动删除」（缺陷单有 `DELETE` 端点）。

### 3.3 增量拉取

**现状约束（必须正视）**：后端**没有任何增量能力**。全仓 grep `since|updated_after|updated_since|If-None-Match|etag` 只命中 `server/routes/_http.mjs:137` 的 CORS 允许头字符串，没有任何路由实现过滤或条件请求。

因此在**不改后端**的前提下，增量拉取只有三条可行路径：

| 方案 | 做法 | 代价 | 采纳 |
| --- | --- | --- | --- |
| A. 全量分页拉 + 本地对账 | 每资源从 offset=0 拉到末页，本地按 `server_id` upsert，比对 `updated_at` | 请求数 O(n/200)，数据量小可接受 | ✅ **主方案** |
| B. 单条定点刷新 | 只对「用户正在看的那一屏」逐条 `GET /:id` | 请求数随屏幕条数增长 | ✅ 作为**前台刷新**补充 |
| C. 后端加 `updated_since` | 需改后端 | 本轮禁止 | ❌ 记为后续优化（§7 拍板项） |

**本地「软游标」**：`sync_state.last_server_max_updated_at` 记录上次拉取结果里的最大 `updated_at`。它**不能用于请求服务端过滤**（没有该参数），只用于：
- 判断「本地是否有比游标更新的行」（用于 UI 上的「有新数据」提示）；
- 跳过无变化的写库（若拉回的行 `updated_at` 与本地相同，不做 UPDATE，减少 IO）。

**刷新时机（建议配置）**：

| 触发 | 动作 | 依据 |
| --- | --- | --- |
| App 启动（`main()`，`_prewarm()` 之后） | 若距上次全量拉取 > 5 分钟 → 后台全量刷新 | 替代现在的「每页各拉一遍」 |
| 进入前台（`AppLifecycleState.resumed`） | 同上，阈值 5 分钟 | 覆盖「切出去再回来」 |
| 下拉刷新（`CupertinoSliverRefreshControl`） | 强制全量刷新当前页资源，**等完成**再收起 | 用户显式操作要可见结果 |
| 页面 `initState` | **只读本地**，不发起请求；若本地为空则触发一次该资源的全量拉取 | 本设计的核心改动 |
| 写操作成功后 | 用响应体直接更新本地（不额外拉） | `POST /defect-tickets` 返回裸行；`PATCH` 等同样返回行 |
| 写操作推送成功后 | 触发该实体的 `GET /defect-tickets/:id` 一次 | 拿回服务端派生列（reopen_count、closed_at、verification_round） |

**不做的**：前台定时轮询（每 N 分钟）——服务端无增量参数，轮询等于不断全量拉，收益低、耗流量与电量。改为「事件驱动 + 手动刷新」。

### 3.4 冲突仲裁

**判定**（同一实体）：

```
local.version  ≠  server.version
且 local.sync_state ∈ {2(dirty), 1(pending_create)} 或 队列里有该实体的 pending 操作
→ CONFLICT
```

`server.version` 从哪来：解析失败时后端 409 的 `body.current` 里就带回整行（`versionConflict()`，见 `server/routes/_http.mjs` 的 409 约定）；主动刷新时则是拉取结果里的 `version`。

**仲裁 UI 形态（三选一，见拍板项 2）**：
- A. **就地卡片**：列表/详情顶部插入一张橙色 `ConflictCard`：「这条缺陷单在云端已被修改」。两个按钮「保留我的修改（重新提交）」「使用云端版本（丢弃本地）」。展开可看字段级 diff。
- B. **集中页**：设置页 →「待处理冲突 N」，逐条处理。
- C. 混合：详情页就地卡片 + 设置页汇总入口（**推荐**）。

**两种选择的语义**：

| 选择 | 实现 |
| --- | --- |
| 保留本地 | 先 `GET /:id` 拿最新 `version`，把队列里该实体所有 pending 操作的 `base_version` 重写为最新 version，然后把 `sync_state` 复位为 2、队列 `status=0`，重新推送。**若再次 409（又被改了）→ 再次进入冲突，最多 3 次后转 dead 并提示** |
| 保留云端 | 删除该实体所有 pending 操作，`GET /:id` 覆盖本地行（含子表），`sync_state=0`。**不可撤销** → 需确认弹窗（`isDestructiveAction: true`） |

**不做**：字段级自动合并。即使「本地改了 A 字段、云端改了 B 字段」也按整行冲突处理——理由：缺陷单的字段间有业务耦合（`error_layer` 与 `status` 由触发器联动），字段级合并可能产生服务端状态机不接受的行。

### 3.5 全量拉取的对账（删除传播）

服务端列表接口过滤 `deleted_at IS NULL`，**不会告诉客户端「哪些被删了」**。因此：

```
拉取某资源完整成功（最后一页 items.length < limit）后：
  DELETE FROM <table>
   WHERE server_id NOT IN (本次拉取到的所有 server_id)
     AND sync_state = 0            ← 只删「干净」的行
     AND local_id NOT IN (SELECT entity_local_id FROM pending_operations WHERE status IN (0,1,2,3))
```

两个例外：
- `sync_state <> 0` 的行（本地新建/有未推送修改）**绝不删**，即使云端看不见；
- 队列里有引用的行**绝不删**。

`questions_cache` / `mock_exams` / `review_cycles` 不做这种删除（它们是按需缓存，不是全量镜像）；只用 LRU 上限裁剪。

### 3.6 同步状态机与不变量

**引擎状态**：`idle → checking → pulling → pushing → idle`，全局单例，同一时刻只有一个 pull 或 push 在跑（MVP 不做并发调度）。

**必须成立的不变量（写单元测试）**：
1. 队列里同一 `entity_local_id` 的操作，`op_id` 严格递增发送；前一条未成功，后一条不发送。
2. 任何 `sync_state <> 0` 的行必须有对应的 pending 操作，或处于 conflict 状态。（反例 = 数据丢失）
3. 任何 pending 操作的目标行必须存在。（反例 = 悬空队列）
4. 拉取对账删除的行，不可能是 `sync_state <> 0` 或有引用的行。
5. `verifications` 的 `(defect_ticket_local_id, stage, round)` 唯一。
6. 本地 `version` 只会因为「服务端响应」或「拉取结果」而更新，不会因优化 UI 而本地 +1。

---

## 4. 读写降级边界

判定规则（三条，按顺序）：
1. **是否依赖服务端不可复现的计算**（随机组卷 / 六项聚合 / 报告生成 / 状态机派生列）→ 是 = 必须在线。
2. **是否是写操作**→ 是 = 走队列（可离线）或必须在线（见下）。
3. 其余 → 先读本地，后台刷新。

| 页面 | 首次渲染 | 后台刷新 | 写操作 | 离线可用性 |
| --- | --- | --- | --- | --- |
| **首页** `home_page` | 读本地 T1 + 本地算 R7/R9 | 3 个请求（现有的 `Future.wait`） | 无 | ✅ 完全可用（倒计时、分布、待验证、快捷入口都在） |
| **缺陷单列表** `defects_page` | 读本地 T4 + JOIN T3/T2 | `GET /users/:id/defect-tickets` 全量对账 | 无 | ✅ 可用（筛选是本地内存过滤，`DefectFilter.matches`） |
| **缺陷单详情** `defect_detail_page` | 读本地 T4 + T5 + T6 | `GET /defect-tickets/:id` | W3 动作勾选（队列）、W4 进入验证（队列） | ✅ 可读 + 可排队写 |
| **缺陷单归因** `defect_analyze_page` | 读本地 T4 | 提交前**必须** `GET /:id` 拿最新 version | W2（队列） | ⚠️ 可读可填，提交进队列 |
| **缺陷单验证提交** `defect_verify_page` | 读本地 T4/T6 | 同上 | W5（队列，需谨慎预测两跳） | ⚠️ 同上 |
| **建单页** `defect_create_page` | 读本地 T2/T3 | 后台刷 T2/T3 | W1（队列 + 本地 id） | ✅ 完全可离线建单 |
| **验证任务页** `verify_page` | 读本地 T4，**本地复算 urgency** | `GET /users/:id/verification-tasks`（不带筛选参数，全量） | 无 | ✅ 可用，**筛选改本地**（消除现状的「每切一次打一次后端」） |
| **模考列表** `mock_page` | 读本地 T8 | 3 个请求（并行化，不再串行） | 无 | ✅ 可用 |
| **组卷页** `mock_create_page` | 读本地 T1/T2/T3 | 后台刷新 | W6 `POST /mock-exams` | ⚠️ 可浏览选择，**生成必须在线** |
| **答题页** `mock_exam_page` | 题目由上一页传入（内存） | `GET /mock-exams/:id`（如需刷新卷面） | W7 提交 | ❌ 必须在线（报告计算） |
| **模考报告页** `mock_report_page` | 上一页传入 | 本地 T8.report | 无 | ✅ 可读（历史卷报告） |
| **复盘列表** `review_page` | 读本地 T9 | `GET /review-cycles` | W8 生成 | ⚠️ 可浏览，生成必须在线 |
| **复盘详情** `review_detail_page` | 传入对象 | 本地 T9.metrics | W9 标记已读（队列）、W10 删除（队列） | ✅ 可读 + 可排队 |
| **我的页** `profile_page` | 读本地 T1，读本地算 stats/summary | 2 个请求 | 无 | ✅ 可用 |
| **设置页** `settings_page` | 无网络 | 新增「数据同步」分区 | — | ✅ |

**必须实时（不走本地）**：
1. `GET /defect-tickets/:id` —— **写操作前的版本校验**。本地缓存里的 `version` 可能已过期，直接用它提交必然 409。这条请求不允许本地兜底（离线时写操作才进队列，且队列里的 `base_version` 标记为「待刷新」，推送前先 GET 一次）。
2. `POST /mock-exams`、`POST /mock-exams/:id/submit`、`POST /review-cycles`。
3. `GET /review-cycles/:id`（409 existing 场景，必须看最新 metrics）。
4. `GET /health`（探活本身）。

**关键 UI 改动（不改页面结构，只改数据来源）**：
- 每页 `initState`：`repo.readXxx()` → `setState` → `unawaited(sync.refreshXxx())`。
- 现状「错误态 + 重试」保留，但语义变化：只有「本地也无数据 + 后台刷新失败」才显示；本地有数据时改为顶部细条 `SyncErrorBanner`（不遮挡内容）。
- 现状的 `kUseMock` 分支（`kUseMock = true` 时用 `mock/*.dart` 的假数据）**保留**：它服务于 widget test 与离线演示，与本地优先不冲突。

---

## 5. 迁移路径（现有用户首次升级）

现有用户：云端已有数据（缺陷单 9 条、模考若干、复盘若干），本地无库。

```
App 启动
  │
  ├─ main(): openLocalDb()（建表/升级，< 50ms）
  │
  ├─ ApiTokenGate: hasApiToken?
  │     ├─ 否 → ApiTokenPage（与现状一致；填完 token 后进入下一步）
  │     └─ 是 → RootTabs 立即渲染（不阻塞）
  │
  ├─ 后台：SyncEngine.bootstrap()
  │     │
  │     ├─ 读 sync_state 表
  │     │     ├─ 空 / last_full_pull_at 全为 NULL  → 【首次同步分支】
  │     │     └─ 非空                              → 【增量刷新分支】→ 直接空闲
  │     │
  │     ├─【首次同步分支】
  │     │     ├─ 本地行数 > 0?（异常情况：用户曾在别的设备/旧版本同步过）
  │     │     │     └─ 是 → 走对账模式（upsert + 删除未被引用的孤儿），不整体清库
  │     │     │
  │     │     ├─ 本地行数 = 0 且云端有数据（拉第一页 items.length > 0）
  │     │     │     └─ 【M1 首次全量导入】按 §3.1 顺序拉取
  │     │     │           每完成一个资源 → 更新 sync_state → SyncBanner 进度 +1
  │     │     │
  │     │     └─ 本地行数 = 0 且云端也空（新用户）
  │     │           └─ 写入 last_full_pull_at=now（表示「已确认云端为空」），
  │     │              不留 NULL，避免每次启动都重跑首次同步
  │     │
  │     └─【失败处理】
  │           ├─ 401/403（token 失效）→ 不清本地库；提示重新填 token（设置页 → 切换 Token）
  │           ├─ 网络/超时 → SyncBanner 变「同步失败，重试」；本地数据仍可读
  │           └─ 部分资源失败 → 记 last_error，其余资源继续；下次启动补
  │
  └─ 用户操作：读本地 → 立即可用
```

**关键判断**：

| 情况 | 判据 | 处理 |
| --- | --- | --- |
| 新装 + 云端有数据（**主场景**） | `sync_state` 空 && 第一页有数据 | 首次全量导入 |
| 新装 + 云端空 | `sync_state` 空 && 第一页空 | 标记已同步，不反复重试 |
| 老版本升级（无本地库） | 本地库文件不存在 | 等价于「新装」，走首次同步 |
| 本地库存在但有数据（重装失败/回滚） | `sync_state` 有行 | 走对账，**不清库**（防止把未推送的写操作抹掉） |
| token 换了（换了账号） | `kApiToken` 变化 | **必须清库**：本地存的是上一个账号的数据。设计：token 变化时把 `sync_state` 与所有业务表清空，保留 `api_token`。检测点：`initializeApiToken()` 之后比对 `sync_state['token_fingerprint']`（存 token 的 SHA-256 前 8 位，**不存 token 本体**） |
| DB 升级（本地 schema 版本 +1） | `PRAGMA user_version` | `onUpgrade` 逐版本迁移；若跨太多版本无法迁移 → 删库重建 + 强制首次同步（数据在云端，安全） |

> ⚠️ **token 指纹校验是必需的**，否则「A 账号的缺陷单出现在 B 账号的界面里」是严重数据串号事故。注意：客户端 `kDemoUserId` 是硬编码 seed UUID，服务端会用 token 改写 `user_id`（`server/index.mjs` 的鉴权边界），所以**不能用 `kDemoUserId` 判断账号是否变化**，只能用 token 指纹。

---

## 6. 投入评估

### 6.1 新增文件（12 个）

| 文件 | 职责 | 预估行数 |
| --- | --- | --- |
| `lib/data/local_db.dart` | `openLocalDb()`、`databaseFactory` 选择、单例、`close()` | 90 |
| `lib/data/migrations.dart` | `onCreate`（DDL 全集）/ `onUpgrade`（版本步进）、`kLocalSchemaVersion = 1` | 260 |
| `lib/data/verification_window.dart` | 移植 `server/verify_window.mjs` 的 `VERIFY_WINDOWS` + `computeUrgency`（纯函数，可单测） | 80 |
| `lib/data/derived_stats.dart` | 本地 `defect-stats` / `verification-summary` 聚合 | 120 |
| `lib/data/dao/defect_dao.dart` | T4/T5/T6 的 CRUD + JOIN 列表查询 + 八态统计 | 340 |
| `lib/data/dao/catalog_dao.dart` | T1/T2/T3 的 upsert + 读取 | 160 |
| `lib/data/dao/mock_dao.dart` | T7/T8 | 150 |
| `lib/data/dao/review_dao.dart` | T9 | 110 |
| `lib/data/sync/sync_queue.dart` | `pending_operations` 入队/出队/重试/冲突标记 | 260 |
| `lib/data/sync/puller.dart` | 首次全量 + 增量对账 + 分页终止（`len < limit`）+ 删除传播 | 320 |
| `lib/data/sync/pusher.dart` | 队列串行推送、`base_version` 重算、server_id 回填、错误分类 | 280 |
| `lib/data/sync/sync_engine.dart` | 单例状态机、生命周期钩子、手动同步入口、进度广播（`ValueNotifier<SyncProgress>`） | 200 |
| `lib/data/sync/sync_conflict.dart` | 冲突模型与「保留本地/云端」的两条执行路径 | 120 |

合计约 **2 400 行**新增（含注释；本仓库注释密度高，实际逻辑量约 1 500 行）。

附加（若采纳 Windows 支持）：`sqflite_common_ffi` 初始化 1 个文件 20 行。

### 6.2 改动文件（约 16 个）

| 文件 | 改动 | 风险 |
| --- | --- | --- |
| `pubspec.yaml` | 加 `sqflite`（dev 加 `sqflite_common_ffi`） | 低 |
| `lib/main.dart` | `await openLocalDb()`；`SyncEngine.instance.start()`；`AppLifecycleListener` 接 resumed | 低 |
| `lib/pages/home_page.dart` | `_loadAll()` 改为「读本地 → 后台刷新」；错误态语义改为 banner | 中（3 块卡片各有独立 error，改动面广） |
| `lib/pages/defects_page.dart` | `_load()` 读本地 + 后台对账 + 下拉刷新 | 低 |
| `lib/pages/defect_detail_page.dart` | 读本地；写操作走队列；保留写前 `GET /:id` | **高**（4 处写操作、乐观 UI、409 冲突 UI） |
| `lib/pages/defect_analyze_page.dart` | 提交入队 | 中 |
| `lib/pages/defect_verify_page.dart` | 提交入队 | 中 |
| `lib/pages/defect_create_page.dart` | 读本地 T2/T3；提交入队（本地 id） | 中 |
| `lib/pages/verify_page.dart` | **筛选改本地**（`_applyUrgency` 不再打后端）；urgency 本地复算 | 中 |
| `lib/pages/mock_page.dart` | 读本地；3 个请求改并行 | 低 |
| `lib/pages/mock_create_page.dart` | 读本地三级目录；生成必须在线（离线时禁用按钮 + 说明） | 低 |
| `lib/pages/review_page.dart` | 读本地 + 后台刷新；生成必须在线 | 低 |
| `lib/pages/review_detail_page.dart` | 标记已读/删除入队 | 低 |
| `lib/pages/profile_page.dart` | 读本地聚合 | 低 |
| `lib/pages/settings_page.dart` | 新增「数据同步」分区（上次同步/本地行数/待推送数/立即同步/清空本地库） | 低 |
| `lib/api/*.dart` | **不改**（继续作为 transport）；仅新增分页辅助（`fetchAll` 循环） | 低 |

> 明确不改：`lib/api/api_client.dart` 的请求逻辑、`lib/logging/*`、`lib/theme/*`、`lib/widgets/*`（除新增 `sync_banner.dart`）、后端全部文件、`schema.sql`。

### 6.3 实施轮次（建议 5 轮）

| 轮次 | 内容 | 交付判据 |
| --- | --- | --- |
| **R1 本地库地基**（0.5 轮） | `local_db` + `migrations` + 三个目录 DAO + `verification_window` 移植 + 单元测试（内存库） | `flutter test` 新增用例全过；`flutter analyze` 0 error；**UI 零改动** |
| **R2 读取切换**（1 轮） | 首页 / 缺陷单列表 / 验证页 / 我的页 改读本地；**尚无同步**（先用手工灌数据的测试库验证渲染） | 冷启动 < 200ms 出内容；断网四页可用 |
| **R3 首次同步 + 对账**（1 轮） | `puller` + `SyncEngine.bootstrap` + `SyncBanner` + 删除传播 + token 指纹 | 新装 → 全量导入 → 数据与云端一致（脚本比对行数与关键字段） |
| **R4 写队列**（1.5 轮） | `sync_queue` + `pusher` + 详情页/归因页/验证页/建单页改造 + 冲突 UI | 飞行模式建单/勾动作/提交验证 → 恢复网络自动推送成功；409 场景可复现并可选择 |
| **R5 收尾**（0.5 轮） | 模考/复盘的读缓存、设置页同步分区、下拉刷新、日志埋点（复用 `AppLogger`）、README / REVIEW-NOTES | `flutter analyze` 0 error；`flutter test` 全绿；Android 真机 4 张截图（离线首页 / 同步中 / 待推送 / 冲突卡片） |

合计约 **4.5 轮**。R2 与 R3 可并行（不同文件），R4 必须在 R2+R3 之后。

### 6.4 主要风险

| 风险 | 描述 | 缓解 |
| --- | --- | --- |
| **R-1 写队列的 `base_version` 级联** | 同实体多条排队操作，版本号必须串行重算；实现错会连丢多条写 | 强制同实体队头阻塞 + 单元测试覆盖「3 条排队、第 1 条 409」 |
| **R-2 `begin-verification` 的两跳** | 服务端同事务两跳（ACTION_DONE→V1），`version` 跳 2（`defect_tickets.mjs:553`）。本地若按「+1」预测，第二条操作必然 409 | 本地对该操作**不做 version 预测**：排队时标记 `requires_online_refresh`，推送前必 GET 一次 |
| **R-3 删除不可传播** | 服务端无 tombstone；只能靠全量对账推断 | 仅在「完整拉取成功」后执行删除；保留 `sync_state<>0` 与有引用的行 |
| **R-4 迁移失败** | 本地库建表/升级异常会让 App 起不来 | `openLocalDb()` 全程 try/catch：失败则删库重建（云端仍是真理源）+ 记日志 + 走首次同步；提供设置页「重建本地库」 |
| **R-5 数据串号** | token 换了但本地未清 | `token_fingerprint` 校验（§5）；不同指纹 → 清业务表 |
| **R-6 双写不一致** | 本地乐观更新与服务端结果不同（如服务端触发器改了派生列） | 写成功后必拉一次该实体详情覆盖本地；**派生列永远以服务端为准** |
| **R-7 本地 urgency 与服务端漂移** | 窗口常量两处 | 常量单点 + 诊断页展示 + 单元测试对照 `server/verify_window.mjs` 的用例值（7/14/21） |
| **R-8 Windows 无 sqflite** | 桌面端不可用 | MVP 限定 Android/iOS；其他平台 `kLocalFirstEnabled=false` 回退现状 |
| **R-9 本地校验缺失** | 客户端**目前没有**移植 `core/index.mjs` 的禁用语 / 状态机校验（`defect_analyze_page` 只做空值检查），离线时可能录进去必然被服务端拒的内容 | R4 里顺带移植最小集：`assertNoForbiddenPhrase` + `assertTransition`（约 80 行），否则 dead 队列会堆积 |

---

## 7. 待拍板问题（5 个）

| # | 问题 | 选项 | 建议 |
| --- | --- | --- | --- |
| **1** | **增量拉取/刷新频率** | (a) 仅事件驱动：启动（>5min）、回前台（>5min）、下拉刷新、写后 (b) 上述 + 前台每 5 分钟自动 (c) 上述 + 前台每 15 分钟 | **(a)**：服务端无 `updated_since`，轮询=反复全量，性价比低 |
| **2** | **冲突仲裁的 UI 形态** | (a) 详情页就地 `ConflictCard` (b) 集中到「设置 → 待处理冲突」 (c) 两者都有 | **(c)**：就地处理最顺手，汇总入口防止遗漏 |
| **3** | **首次同步是否阻塞启动** | (a) 不阻塞：进首页 + 顶部进度条，各页显示「同步中」空态 (b) 阻塞：全屏「正在同步 12/34」等完成再进 (c) 首次同步阻塞、后续不阻塞 | **(a)**：本地优先的整个意义就是「不等网络」；阻塞会把 10–30s 的冷启动问题换个地方重现 |
| **4** | **本地缓存的数据范围** | (a) 全量（所有未删除行） (b) 只缓存未关闭缺陷单 + 最近 90 天模考/复盘 (c) 可配置 | **(a)**：单用户数据量小（十到百量级），(b) 的收益不足以支付复杂度 |
| **5** | **是否本轮支持 Windows 桌面本地库** | (a) 不支持，桌面回退直连（需加 `kLocalFirstEnabled` 开关） (b) 支持，加 `sqflite_common_ffi` + `sqlite3_flutter_libs` 两个依赖 | **(a)**：MVP 验证在 Android 模拟器；桌面是开发便利，不是交付目标 |

补充说明（供评审参考，不占拍板名额）：

- **`questions_cache` 是否真的需要**：目前唯一用到题面的是模考报告页（回看题目）与答题页（卷面本身在内存）。若报告页已有 `report` JSON 里的题面副本，T7 可以砍掉。**建议：R1 先不建 T7，R5 时按报告页实际需要再定**（可省约 150 行）。
- **`sync_state.token_fingerprint`** 虽然是本地独有列，但属于安全必需项，已并入 §5，不单独拍板。
- **后端若要支持真正的增量同步**，最小改动是给列表接口加 `updated_since` 参数 + 按 `updated_at` 过滤（`defect_tickets` / `mock_exams` / `review_cycles` 三处仓储各加一个 `WHERE updated_at > $n`）。这属于**下一个后端里程碑**，本轮明确不做。

---

## 8. R1 实现记录（本地 SQLite 库地基）

> 本章是**实现回填**，记录 R1 实际落地与上文设计的差异。上文 §0–§7 保持设计时的原貌，未改动。

### 8.1 实际建成的 10 张表

设计文档 §2.2 列的是 T1–T11 共 11 项，R1 实建 10 张，差异及理由如下：

| 设计编号 | 设计表名 | R1 实现 | 说明 |
| --- | --- | --- | --- |
| T1 | `exam_profiles` | ✅ 同名 | 字段与 §2.3 一致 |
| T2 | `subjects` | ✅ 同名 | 同上 |
| T3 | `knowledge_nodes` | ✅ 同名 | 同上 |
| T4 | `defect_tickets` | ✅ 同名 | **精简 4 类列**（见 8.2） |
| T5 | `defect_actions` | ⚠️ 改名为 `actions` | 与云端表名一致，减少两层命名映射的心智负担 |
| T6 | `verifications` | ✅ 同名 | 含 `(defect_ticket_local_id, stage, round)` 唯一索引 |
| T7 | `questions_cache` | ❌ **不建** | 拍板第 6 条：R1 不建，R5 按报告页实际需要再定 |
| T8 | `mock_exams` | ✅ 同名 | 主键 `server_id`（模考不可离线创建） |
| T9 | `review_cycles` | ✅ 同名 | 主键 `server_id` |
| T10 | `pending_operations` | ✅ 同名 | 字段按任务书 B2 的 9 列 + 补充 4 列 |
| T11 | `sync_state` | ⚠️ 并入 `local_meta` | 见 8.3 |

另有一张 `local_meta`（key/value），是 T11 的替代品 + 全局水位载体。因此**实建 10 张 = T1–T6、T8–T10 共 9 张 + `local_meta`**。

### 8.2 `defect_tickets` 精简掉的具体列

设计 §2.3 T4 要求「不落本地」的 4 类列，R1 建表时全部未建：

| 云端列 | 不落本地的原因 | 本地如何补 |
| --- | --- | --- |
| `actions` (jsonb) | 与 `actions` 表重复的快照，双写会不一致 | 只读 `actions` 表（`ActionsDao.listByTicket`） |
| `verification_state` (jsonb) | 实测恒为 `{v1:pending,...}` 不反映真实状态，前端早已改为读 `verifications` 数组 | 从 `verifications` 表按 `round` 聚合 |
| `knowledge_node_title` / `subject_name` | 服务端是 LEFT JOIN 出来的展示字段，不是 `defect_tickets` 的列 | 本地 JOIN `knowledge_nodes` / `subjects` |
| `deleted_at` | 本地是投影，软删行在拉取时直接不落库 | 无（删除靠 §3.5 对账传播） |

### 8.3 `sync_state` 表改为 `local_meta` key/value

设计 T11 是「每资源一行水位表」，R1 改成 `local_meta(key TEXT PRIMARY KEY, value TEXT, updated_at TEXT)`，键形如 `sync.<resource>.<field>`（`MetaKey.sync('defect_tickets','row_count')` → `sync.defect_tickets.row_count`）。

**理由**：省一张表 + 一套 DAO 约 80 行；键空间开放，将来加 `sync.mock_exams.last_full_pull_at` 不需要迁移表结构。
**代价**：查「哪些资源完全没拉过」要 `LIKE 'sync.%'` 再在 Dart 里聚合，不能一句 `WHERE last_full_pull_at IS NULL`。R3 若觉得别扭，加一张 3 列小表即可，不影响业务表。

### 8.4 不声明 FOREIGN KEY

10 张表全部**没有** `REFERENCES`。理由：本地是「云端投影 + 待推送队列」，父子行到达顺序由同步批次决定，硬外键会让「先到子行、父行还没拉下来」的中间态直接写失败（`FOREIGN KEY constraint failed`）。引用完整性由三个手段保证：

1. R3 的首次全量按「先父后子」顺序拉取（设计 §3.1）；
2. 列表查询一律通过本地索引 JOIN 或二次查询，不假设外键存在；
3. `pending_operations.status` 的 `dead` 状态兜住推送失败（R4）。

`onConfigure` 里仍执行了 `PRAGMA foreign_keys = ON`——当前无外键，这句是**为将来预留**的，注释已写明。

### 8.5 与设计文档的其他偏差

| 项 | 设计 | 实现 | 理由 |
| --- | --- | --- | --- |
| `kLocalFirstEnabled` 的修饰 | 任务书写 `const bool` | `bool`（可变顶层变量） | 任务书 D2 要求初始化失败时**强制降为 false**，`const` 无法赋值。与既有 `kUseMock` 的做法一致 |
| `pending_operations` 的列 | 任务书 B2 列 9 个 | 实建 13 个（+`path_template`、`next_retry_at`、`last_error`、`inflight`/`conflict`/`dead` 三个状态） | B2 的 9 列无法表达「请求打到哪个端点」与「重试退避」，R4 推送必须要有 |
| `actions` 表的 `done` 列类型 | 设计写 BOOLEAN 语义 | `INTEGER NOT NULL DEFAULT 0` | SQLite 没有 BOOLEAN；`toLocalValue()` 统一把 `bool` 转 0/1，读侧由 DAO 调用方自行 `== 1` |
| 时间列类型 | 设计写「ISO 8601 TEXT」 | 一致，且 `toLocalValue()` 在写入前把 `DateTime` 转成 **UTC** ISO | 避免本地时区差异导致 `ORDER BY created_at` 与服务端排序不一致 |
| 唯一索引 | 设计写「`server_id` UNIQUE」 | 一律带 `WHERE server_id IS NOT NULL` | 离线新建的行 `server_id` 为 NULL，若不带谓词会被 SQLite 视为「相等」而互相冲突 |

### 8.6 测试覆盖

`test/local_db_test.dart`（661 行，**27 个用例**）覆盖任务书 E1–E5：

| 分组 | 用例数 | 覆盖点 |
| --- | --- | --- |
| E1 建表 | 4 | 10 表齐全、22 索引齐全、无 `sqlite_` 前缀用户表、`defect_tickets` 缺 4 类列且含 6 个核心列 |
| E2 基础 CRUD | 5 | 8 张表参数化 `insert→get→update→delete`、`insertAll` 批量、`bool→0/1`、`DateTime→ISO UTC`、`server_id` 唯一索引（含两个 NULL 共存） |
| DAO 专有查询 | 7 | `listByUser` 排序与状态过滤、`listVerifiable` 八态筛出 V1/V2/V3、`findByStageRound` 唯一命中、同 `(单,stage,round)` 二次插入只剩 1 行、`listByTicket`、`listByProfile`/`listBySubject`、`count`/`countUnsynced`/`deleteAll` |
| E3 写队列 | 5 | `enqueue→listPending→markDone`、`markFailed` 保留+记录、`incrementRetry` 只加计数、`listByEntity` 入队顺序、`markConflict`/`markDead` |
| E4 local_meta | 3 | `setMeta`/`getMeta`/`deleteMeta` 覆盖写、`setAll`+`listByPrefix`、`MetaKey.sync` 拼键 |
| E5 持久化 | 2 | `close()` 重开后数据仍在、并发 `database` 只开一次 |
| 开关 | 1 | `kLocalFirstEnabled` 默认 false |

测试用 `sqflite_common_ffi`（dev_dependency）把同一套 API 桥接到宿主 sqlite3，故 `flutter test` 在 Windows 上能跑真实 SQL；**不进运行时依赖**。

### 8.7 R1 明确没做的事

- 没有页面读本地库（`kLocalFirstEnabled` 恒 false，App 行为与 R1 之前完全一致）。
- 没有同步引擎、没有冲突仲裁、没有队列推送（R3/R4）。
- 没有移植 `computeUrgency` 到 Dart（设计 §2.4 要求在 R2 做，因为 R1 没有页面需要它）。
- 没有移植状态机/禁用语校验（设计 R-9，R4 做）。
- 没有建 `questions_cache`（拍板第 6 条）。
- `api_client.dart`、`schema.sql`、后端任何文件均零改动。

### 8.8 R2/R3/R4 的入口点（留给下一轮）

| 轮次 | 入口 | 具体位置 |
| --- | --- | --- |
| R2 | 页面 `initState` 改读本地 | `home_page.dart` 的 `_loadAll()`、`defects_page.dart` 的 `_load()`、`verify_page.dart` 的 `_load()`、`profile_page.dart` 的 `_loadAll()` —— 四处都是「先给本地快照、再后台刷新」的天然切入点 |
| R2 | urgency 本地复算 | 新建 `lib/local/verify_window.dart`，常量对齐 `server/verify_window.mjs` 的 `VERIFY_WINDOWS = {V1:7,V2:14,V3:21}` 与 `DUE_SOON_DAYS = 3` |
| R3 | 首次同步触发点 | `main.dart` 的 `_initLocalDb()` 之后（后台 `unawaited`，不阻塞 `runApp`）；判据读 `local_meta` 的 `token_fingerprint` 与各资源 `sync.*.row_count` |
| R3 | 拉取顺序 | 严格按「父→子」：`exam_profiles → subjects → knowledge_nodes → defect_tickets → actions → verifications → mock_exams → review_cycles` |
| R4 | 写队列推送 | `pending_operations` 按 `op_id ASC` 出队；同 `entity_local_id` 队头阻塞；`begin-verification` 打 `requires_online_refresh` |