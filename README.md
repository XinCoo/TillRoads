# 题路 TillRoad

> 一款「不追刷题量、追缺陷闭环」的成人考试备考管理 App。
> 核心闭环：**目标配置 → 能力层级 → 缺陷单 → 三次验证关闭 → 周期复盘**。
> 仅面向成人考试，不碰 K12 / 社交 / 押题；AI 全 BYOK（自带密钥），且核心闭环不依赖 AI。

本仓库当前状态：**文档已通过评审并完成 P0/P1 修订，进入开发阶段；首个可验证里程碑（端无关核心规则层 + HTTP API 骨架）已落地**。评审详情见 [REVIEW-NOTES.md](<REVIEW-NOTES.md>)。

---

## 1. 文档导航

| 文件 | 作用 | 版本 |
|---|---|---|
| [题路TillRoad-开发文档初稿.md](<题路TillRoad-开发文档初稿.md>) | PRD / 技术设计总纲（15 节：产品边界、画像、数据模型、AC-\* 功能需求、页面 IA、AI 设计、多考试模板、非功能、技术架构、API 契约、测试、MVP 范围、成功指标、假设与已决策） | v0.5 |
| [mvp-tasks.md](<mvp-tasks.md>) | MVP 任务拆分与依赖链（BE / FE / AI / QA 全量任务 + BE-00 CI 门禁 + 里程碑） | v0.3 |
| [schema.sql](<schema.sql>) | PostgreSQL 15+ DDL（14 枚举 / 18 表 / 触发器 / 去重哈希 / 乐观锁 / 接口契约附录 / 末尾自检 DO 块） | v0.3-schema1 |
| [migrations/0001_init_up.sql](<migrations/0001_init_up.sql>) / [0001_init_down.sql](<migrations/0001_init_down.sql>) | 迁移入口（`\ir ../schema.sql`，单一事实来源） | — |
| [byok-key-lifecycle.md](<byok-key-lifecycle.md>) | BYOK 密钥生命周期决策（KMS 信封加密 / 撤销轮换 / 审核七态 / SSRF 约束 / cooldown） | v1.2 |
| [offline-sync-spec.md](<offline-sync-spec.md>) | 离线与增量同步规格（本地队列 / 凭证缓存边界 / 冲突仲裁 / AI 任务挂起） | v1.2 |
| [fe-11-audit-motion-spec.md](<fe-11-audit-motion-spec.md>) | FE-11 审核七态 UI 动效规范（iOS 26 原生风格基准） | v1.1 |
| [REVIEW-NOTES.md](<REVIEW-NOTES.md>) | 本次评审结论、4 项 P0 + 4 项 P1 修订对照、环境实测、后续建议 | 评审记录 |

> 版本 / 编号易错点：审核七态 UI 是 **FE-11**（不是 FE-02，FE-02 为建题/导入页）；`flutter/local_ai_task_queue.dart` 为 **FE-09 待建产物**，本仓尚未创建。

---

## 2. 目录结构

```
TillRoads/
├── core/                      # 端无关核心规则层（零第三方依赖，纯 JS；不 import pg）
│   ├── index.mjs              #   状态机 / 禁用语 / 三次验证 / 去重哈希 / 优先级 / BYOK 校验
│   ├── index.test.mjs         #   14 个 node:test 用例
│   ├── validators.mjs         #   BE-01 输入校验 V1–V12（扁平 result 形状，17 个导出）
│   ├── validators.test.mjs    #   15 个用例
│   ├── templates.mjs          #   AC-KM-01 官方科目模板（纯数据，5 个 exam_type）
│   └── templates.test.mjs     #   4 个用例
├── server/                    # HTTP API 骨架 + PG 仓储
│   ├── index.mjs              #   启动 + pool/state 注入 + 交给 dispatch()（已瘦身至 ~150 行）
│   ├── index.test.mjs         #   30 个 fake 层用例（路由分发 / 入参 / base_version / 409，不连 PG）
│   ├── verify_window.mjs       #   BE-04 窗口常量 + computeUrgency（纯函数，零依赖）
│   ├── verify_window.test.mjs  #   13 个用例（urgency 三态边界）
│   ├── _fake_repos.mjs         #   内存 fake 仓储（供 fake 层测试注入，不 import pg）
│   ├── mock_report.mjs         #   BE-05 报告纯函数 reportGenerator + BE-06 computeStability（零依赖）
│   ├── mock_report.test.mjs    #   22 个用例（四项计算 + cv + v3_candidates + 边界）
│   ├── review_period.mjs       #   BE-06 周期起止纯函数（ISO 周 + Asia/Shanghai 时区）
│   ├── review_period.test.mjs  #   10 个用例（跨年周 / 闰年 / 非法 period）
│   ├── review_stats.mjs        #   BE-06 六项 metrics 聚合（全 SQL 层，不拉全量到 JS）
│   ├── index.integration.test.mjs  # 11 条路由层 PG 集成（AC-KM-01/02 + 级联软删，仅 CI 跑）
│   ├── routes/review_cycles.integration.test.mjs # 12 条 BE-06 复盘集成（仅 CI 跑）
│   ├── routes/
│   │   ├── _http.mjs          #   ok/fail/assertValid/readBaseVersion/httpError/readBody/pagination
│   │   ├── index.mjs          #   dispatch()：health 优先，再按 ROUTE_MODULES 顺序问各 match()
│   │   ├── exam_profiles.mjs  #   目标配置 + AC-KM-01 事务 + 级联软删事务
│   │   ├── subjects.mjs       #   科目 + AC-KM-02 层级副本事务
│   │   ├── knowledge_nodes.mjs#   考点树（含扁平/嵌套两种 GET）
│   │   ├── capability_layers.mjs # 层级模板 + customizable gate
│   │   ├── defect_tickets.mjs #   缺陷单状态机全链（BE-03：PG 仓储 + begin-verification 两跳）
│   │   ├── questions_import.mjs   # POST /questions/import（BE-02 导入端点，JSON+base64）
│   │   ├── mock_exams.mjs      #   BE-05 组卷 / 提交收卷 / 报告 / 列表（5 个端点）
│   │   ├── verification_tasks.mjs  # BE-04：验证任务列表 + 看板聚合（纯 GET，不写库）
│   │   └── review_cycles.mjs    #   BE-06：日/周/月复盘快照（5 个端点）

│   ├── db/
│   │   ├── pool.mjs           #   createPool() + 7 个 OID 类型解析器（numeric→number 等）
│   │   ├── pool.test.mjs      #   9 个用例（零 PG）
│   │   └── pg-smoke.integration.test.mjs   # 4 条 smoke（仅 RUN_PG_INTEGRATION=1 跑）
│   ├── repositories/
│   │   ├── base.mjs           #   withTransaction / buildUpdateSet / conflictError / mapPgError
│   │   ├── base.test.mjs      #   20 个用例（fake client）
│   │   ├── _common.mjs        #   共享原语（乐观锁 / 父行加锁 / 查重 / 软删 / jsonb 参数）
│   │   ├── _common.test.mjs   #   7 个用例（JSONB_COLUMNS / toJsonbParam）
│   │   ├── exam_profiles.mjs  #   考试目标 CRUD
│   │   ├── subjects.mjs       #   科目 CRUD
│   │   ├── knowledge_nodes.mjs#   考点树 CRUD + getTree（递归 CTE 防环）
│   │   ├── capability_layers.mjs # 能力层级模板 + customizable gate
│   │   ├── questions.mjs      #   题库 CRUD + content_hash 查重（BE-02）
│   │   ├── assets.mjs         #   多态资产附件（owner_type/owner_id，不走乐观锁）
│   │   ├── defect_tickets.mjs    #   缺陷单 CRUD + 状态机 + 验证任务查询（BE-04）
│   │   ├── actions.mjs           #   处理动作（markDone / assertAllDone）
│   │   ├── verifications.mjs     #   三次验证记录（按 stage+round 唯一）
│   │   ├── mock_exams.mjs      #   BE-05 组卷 / 提交收卷 / 报告 / 列表
│   │   ├── attempts.mjs        #   BE-05 作答记录（is_correct 三态保留）
│   │   ├── review_cycles.mjs     #   BE-06 复盘快照 CRUD + 同周期查重（ALREADY_EXISTS）
│   │   └── repositories.integration.test.mjs # 29 条 PG 集成测试
│   └── import/                # BE-02 导入管线（抽取→切题→去重→入库）
│       ├── splitter.mjs       #   规则切题（四类分隔符，纯函数零依赖）
│       ├── splitter.test.mjs  #   8 个用例（三份样本 + PDF 端到端）
│       ├── extract.mjs        #   mime 分派 + 体积/页数上限（413/415/422）
│       ├── xlsx.mjs           #   手写最小 xlsx 读取（只读首个 sheet）
│       ├── dedupe.mjs         #   按 content_hash 查重
│       ├── separate.mjs       #   第四阶段：图片占位识别（MVP 不落库）
│       ├── separate.test.mjs  #   8 个用例
│       └── import.integration.test.mjs      # 7 条导入链路集成（仅 CI 跑）
├── tests/fixtures/questions/  # 切题样本（3 份文本 + 2 个 PDF + 生成脚本）
├── migrations/                # PG 迁移入口（psql 的 \ir ../schema.sql）
├── schema.sql                 # 数据库单一事实来源
├── .github/workflows/schema-ci.yml  # schema 幂等/可逆 + Node 单测 + PG 集成
├── *.md                       # 设计 / 决策 / 评审文档
├── package.json               # scripts: test / test:core / test:server / test:integration / start
├── tillroad_app/              # Flutter 前端（FE-01 已初始化，iOS/Android/Windows 三平台）
│   ├── lib/                   #   13 个 dart 文件：main / theme / mock / pages×5 / widgets×5
│   ├── assets/icons/          #   1024 图标源（白底 app_icon + 透明底 foreground）
│   └── screenshots/           #   FE-01 验收截图（Windows + Android）
└── REVIEW-NOTES.md / README.md
```

> 设计取舍：`core/` 把「与端无关的核心规则」抽成纯 JS 层（零依赖、不 import pg），当前环境即可验证，且与 `schema.sql` 的触发器/约束/去重/状态机严格对齐、契约零漂移；后续可直接移植到 Dart（FE）或 NestJS（BE）。
>
> **前端**（`tillroad_app/`）已接入 Flutter 3.50.0，但 FE-01 只用 `home_mock.dart` 假数据、**不连后端**——真实数据接入是后续前端里程碑的事。

---

## 3. 快速开始

环境要求：**Node.js ≥ 20**（本机实测 v24.19.0）。运行时依赖两个：`pg`（BE-01 第 2 步引入，PG 访问）与 `pdfjs-dist`（BE-02 引入，文字型 PDF 抽文本），需先 `npm install` / `npm ci`。

> **改动依赖后必须验一次 `npm ci`**：`pdfjs-dist` 带 `optionalDependencies`（`@napi-rs/canvas`，渲染用，我们只抽文本从不用它）。若新增/升级带可选依赖的包后只跑 `npm test` 而不跑 `npm ci`，lockfile 可能缺可选子树，CI 会在 `npm ci` 报 `EUSAGE ... Missing: X from lock file`。修法：`npm install --package-lock-only --include=optional`（详见 `REVIEW-NOTES.md` §15）。

```bash
npm ci            # 按 package-lock.json 安装（含 pg@8.23.x + pdfjs-dist@6.5.x）

# 跑全部单测（core 规则层 + server 骨架 + 仓储工具层）
npm test

# 分别只跑核心规则层 / API 骨架单测 / 集成测试（后者需 PG）
npm run test:core
npm run test:server
npm run test:integration   # pg-smoke + 四表仓储 + 路由层 + 导入链路集成（需 RUN_PG_INTEGRATION=1）

# 启动 HTTP API（默认 http://127.0.0.1:3000，可用 PORT 覆盖）
npm start
```

数据库（需 PG15+，本机未安装，故由 GitHub Actions 的 PG15 service 容器真跑）：

```bash
psql -v ON_ERROR_STOP=1 -f migrations/0001_init_up.sql   # 打印 SCHEMA_VERIFY_OK 即通过
psql -v ON_ERROR_STOP=1 -f migrations/0001_init_down.sql # 回滚
```

集成测试（四表仓储 + 路由层 + 导入链路 + PG smoke）需要真实 PG，默认跳过：

```bash
# 集成测试的 before() 会自行执行整份 schema.sql，无需先手动迁移
RUN_PG_INTEGRATION=1 npm test
```

> **集成测试必须串行跑**：`npm test` 与 `test:integration` 已内置 `--test-concurrency=1`。
> 四个 PG 集成测试文件共用同一个数据库（`tillroad_ci`），并行执行时彼此会触发
> **死锁**（`40P01 deadlock_detected`）—— 仓储层的并发竞态用例会持锁 200ms，
> 与路由层的建单抢同一行。这是 BE-01 第 4 步 CI 实际踩过的坑，不要把这层保护去掉。
> 单测（core/ 与 fake 层）不受影响，仍可 `npm run test:core` 并行跑。

> 集成测试的 `before()` 会自行执行整份 `schema.sql`（单一事实来源，无 psql 元命令），
> 因此 CI 中无需额外跑迁移步骤；本地若已迁移也是幂等的，不冲突。

---

## 4. 核心规则速查（core/index.mjs）

### 状态机

```
DRAFT → ANALYZED → ACTION_DONE → V1 → V2 → V3 → CLOSED
                                  ↓fail  ↓fail  ↓fail
                                REOPENED ──────→ ANALYZED（verification_round +1）
```

- 缺陷单状态：`DRAFT / ANALYZED / ACTION_DONE / V1 / V2 / V3 / REOPENED / CLOSED`。
- 不变量：**`ACTION_DONE` ≠ `CLOSED`**；任一验证 `fail` → `REOPENED` 且 `reopen_count+1`；连续重开 ≥3 提示抽验；**仅用户可标记 pass，AI 不能关单**。
- 两阶段建单：未归因 → `DRAFT`（仅记录错题）；`POST /defect-tickets/:id/analyze` 补齐归因 → `ANALYZED`。转 `ANALYZED` 时强制 `error_layer` / `error_cause` 非空，且禁用语校验。

### 禁用语

`粗心 / 马虎 / 没掌握 / 我懂了 / 大意 / 差不多 / 忘了` —— 出现在归因文本即拒绝（`FORBIDDEN_PHRASE_IN_ERROR_CAUSE`），迫使归因落到可操作的能力层级。

### 三次验证窗口

| 阶段 | 窗口 | 方式 |
|---|---|---|
| V1 | 3–7 天 | 无答案重做 / 同类变式 / 讲题 |
| V2 | 1–2 周 | 新题识别（同 `knowledge_node_id` + 同 `error_layer` + 同题型且未作答过） |
| V3 | 限时模考 | 稳定性验证 |

### 主要导出

| 函数 | 作用 |
|---|---|
| `canTransition(from,to)` / `assertTransition(from,to)` | 状态迁移合法性（非法抛 `ILLEGAL_DEFECT_TRANSITION`） |
| `findForbiddenPhrases(text)` / `assertNoForbiddenPhrase(text)` | 禁用语检测 |
| `assertAnalyzable({status,error_layer,error_cause})` | 转 ANALYZED 前的归因 + 禁用语校验 |
| `applyVerification(ticket,stage,result)` | 三次验证推进（fail→REOPENED+reopen_count，pass→V1/V2/V3/CLOSED，≥3 次重开抽验提示） |
| `beginVerification(ticket)` / `reanalyze(ticket)` | ACTION_DONE→V1 / REOPENED→ANALYZED（轮次 +1） |
| `isSimilarQuestion(base,candidate,answeredIds)` | 同类变式判定 |
| `normalizeQuestionText(stem,options,formula)` | 全角/顿号归一 + 去空白 + sha256 去重哈希 |
| `computePriority({frequency,loss,closability,targetContribution})` | 优先级 → P0 / P1 / P2 |
| `validateAIGenerateRequest(payload)` | BYOK 生成题校验：count 1–20、provider 锁死 `deepseek`/`openai_compatible`、SSRF 拦截 |

### 输入校验（core/validators.mjs，BE-01 第 1 步）

统一返回扁平形状 `{ok:true}` 或 `{ok:false, code, message, ...extra}`（**不抛错**，与 `core/index.mjs` 的 `assertXxx` 明确区分，供 HTTP 层直接映射 400）：

| 函数 | 校验内容 / 失败码 |
|---|---|
| `validateExamType(v)` | `exam_type` 枚举；K12 类 → `EXAM_TYPE_K12_FORBIDDEN` |
| `validateSubjectKind(v)` | `objective` / `subjective` / `essay` |
| `validateFreqTag(v)` | `high` / `mid` / `low` |
| `validateProfileStatus(v)` | `active` / `archived` |
| `validateTargetScore(n)` | `0 … 9999.99`（numeric(6,2)） |
| `validateDailyMinutes(n)` | 非负整数，`null/undefined` 放行（可空列） |
| `validateWeightToTarget(n)` | `0 … 9.999`（numeric(4,3)） |
| `validateExamDate(v)` | 真实日历日（拒 `2026-02-30`），`YYYY-MM-DD` |
| `validateLayers(arr, opts)` | `[{order,key,label,desc}]` 结构与重复检测；`opts.mode='create'` 时 `null` → `LAYERS_REQUIRED` |
| `validateCustomizableGate(current, patch)` | AC-KM-02 gate，失败关闭；锁 `layers`/`customizable` → `CUSTOMIZABLE_LOCKED` |
| `validateExamProfileRequired(input)` | AC-EXAM-01 四项必填，一次收集 `fields[]` → `MISSING_REQUIRED_FIELD` |
| `validateBaseVersion(v)` | 乐观锁基版号：正整数 |
| `firstInvalid(...results)` | 串起多个校验，返回第一个失败（全通过返回 `{ok:true}`） |
---

## 4.5 PG 仓储层（server/repositories/，BE-01 第 3 步）

四张表各一个模块（不用工厂函数：每表的可写列白名单是独立常量，静态审计时更好 grep）。
**首参一律是同一个事务内的 `client`**，写操作必须包在 `withTransaction` 里。

| 模块 | 方法 | 说明 |
|---|---|---|
| `exam_profiles` | `create / getById / listByUser / update / archive` | 查重：同 `user_id` 下 `target_label`（锁 `users` 行） |
| `subjects` | `create / getById / listByProfile / update / archive` | 查重：同 `exam_profile_id` 下 `name`（锁父目标行） |
| `knowledge_nodes` | `create / getById / listBySubject / getTree / update / archive` | 查重：同 `subject_id` + 同 `parent_id` 下 `title`；`getTree` 返回嵌套根节点数组，递归 CTE 防环 |
| `capability_layers` | `create / getById / list / findByName / update / archive` | 不查重，走 `customizable` gate（失败关闭） |

铁律（与 `schema.sql` 对齐，违反会在集成测试里报错）：

- `SET` 永不出现 `id / created_at / updated_at / version / deleted_at`（后两者由 `set_updated()` 触发器维护）。
- `UPDATE ... WHERE` 恒含 `version = $base_version AND deleted_at IS NULL`；0 行 → 取当前行（**含软删**）抛 `409`。
- 空 patch 直接返回当前行，**不发 UPDATE**（避免 `version` 无意义 +1 后产生幽灵 409）。
- 查重冲突统一 `409 { error:'conflict', field, current, incoming, resolution:'user_choice' }`，与乐观锁的 `resolution:'client_merge'` 明确区分。
- 所有 SQL 值均参数化；列名只来自各模块的硬编码白名单（`buildUpdateSet` 三道闸校验）。
- `core/` 一行 `pg` 都不 import；`capability_layers.mjs` 反向 import `core/validators.mjs` 的纯函数是唯一例外。

### 路由层（server/routes/，BE-01 第 4 步）

`server/index.mjs` 只做三件事：建 HTTP server、注入 `pool` / `state`、把 `(method, seg)` 交给 `server/routes/index.mjs` 的 `dispatch()`。四个连 PG 的模块各占一个文件；`defect_tickets.mjs` 暂存内存实现（BE-03 会重写到 PG）。

`base_version` 传递方式：**只认请求体的 `version` 字段**，刻意不支持 `If-Match` 头（现有 16 条测试、`conflictBody`、`offline-sync-spec.md` 与 SQL 骨架 `WHERE version = $base_version` 都以 body 为准；同时支持两者会产生「不一致时听谁的」歧义）。缺失或非正整数：

```json
{ "error": "INVALID_BASE_VERSION", "message": "version 必须是正整数（乐观锁基版号）" }
```

409 有两种形状，客户端按 `resolution` 分支；HTTP 层只有一处 `catch`，直接用 `err.body` 输出，不重新拼：

```json
{ "error": "conflict", "current": {...}, "incoming": 3, "resolution": "client_merge" }
{ "error": "conflict", "field": "name", "current": {...}, "incoming": {"name":"x"}, "resolution": "user_choice" }
```

> 四张 PG 表的**所有写操作**（`POST` / `PATCH` / `DELETE`）都包在 `withTransaction` 里。`PATCH /exam-profiles/:id` 也不例外：它的 patch 一旦含 `target_label`，仓储层要先 `lockParentRow(users)` 再加查重，不包事务的话 `FOR UPDATE` 会在语句自动提交后立刻释放，两个并发改名会双双通过查重。查重 + 写入必须同一快照。

> 缺陷单等内存端点本轮**未**强制 `base_version`（保持原行为）；强制范围仅限已接 PG 的四张表，BE-03 重写缺陷单时一并统一。

## 5. HTTP API（server/routes/）

| 方法 & 路径 | 说明 |
|---|---|
| `GET /health` | 健康检查 |
| `POST /exam-profiles` | 建目标配置（**AC-KM-01**：同事务按 `exam_type` 模板预置科目 → `201 {profile, subjects}`） |
| `GET /exam-profiles/:id` | 取单个目标配置 |
| `GET /users/:userId/exam-profiles` | 某用户的目标配置列表（分页 `{items,...page}`） |
| `PATCH /exam-profiles/:id` | 更新（**`base_version` 必填**；空 patch 不发 UPDATE、不推进 `version`） |
| `DELETE /exam-profiles/:id` | 软删（**`base_version` 必填**；级联软删 subjects + knowledge_nodes，返回 `cascaded` 行数） |
| `GET /exam-profiles/:id/subjects` | 某目标下的科目列表 |
| `POST /subjects` | 建科目（缺 `exam_profile_id` → `400 missing_exam_profile_id`） |
| `GET /subjects/:id` | 取单个科目 |
| `PATCH /subjects/:id` | 更新科目（`base_version` 必填） |
| `DELETE /subjects/:id` | 软删科目（`base_version` 必填） |
| `POST /subjects/:id/customize-layers` | **AC-KM-02**：同事务建自定义层级副本并把该科目重指向它 → `201 {subject, capability_layer}` |
| `POST /knowledge-nodes` | 建考点（缺 `subject_id` → `400 missing_subject_id`；跨科目挂子 / 成环 → `400 parent_subject_mismatch` / `cyclic_parent`） |
| `GET /knowledge-nodes/:id` | 取单个考点 |
| `GET /subjects/:id/knowledge-nodes` | 某科目下扁平考点列表（分页） |
| `GET /subjects/:id/knowledge-tree` | 某科目下**嵌套**考点树（AC-KM-03，不分页） |
| `PATCH`/`PUT /knowledge-nodes/:id` | 更新/移动考点（`base_version` 必填；递归 CTE 防环） |
| `DELETE /knowledge-nodes/:id` | 软删考点（`base_version` 必填） |
| `POST /capability-layers` | 建层级模板（`layers` 必填，缺失 → `400 LAYERS_REQUIRED`） |
| `GET /capability-layers` | 模板列表（分页） |
| `GET /capability-layers/:id` | 取单个模板 |
| `PATCH /capability-layers/:id` | 更新模板（`base_version` 必填；`customizable=false` 时改 `layers` → `400 CUSTOMIZABLE_LOCKED`） |
| `DELETE /capability-layers/:id` | 软删模板（`base_version` 必填；**同样受 gate 拦截**，刻意加严） |
| `POST /questions/import` | **BE-02** 题库导入（JSON + base64；四阶段：抽取→切题→去重→入库）→ `200 {imported, duplicates, errors, stats}` |
| `POST /questions-import` | 上一行的路径别名 |
| `POST /defect-tickets` | **BE-03** DRAFT 建单（归因列可空）；带完整归因直接 `201 ANALYZED`；禁用语 → `400 forbidden_phrase`；缺归因 → `400 missing_error_layer_or_cause` |
| `GET /defect-tickets/:id` | 取单个缺陷单（回带 `verifications` + `actions` 历史） |
| `GET /users/:userId/defect-tickets?status=` | 某人缺陷单列表（可按 status 过滤，分页） |
| `POST`/`PATCH /defect-tickets/:id/analyze` | DRAFT/REOPENED→ANALYZED 补齐归因（`PATCH` 为兼容别名，`base_version` 必填） |
| `POST /defect-tickets/:id/actions` | 添加处理动作（一单多动作） |
| `PATCH /defect-tickets/:id/actions/:actionId` | 标记动作 done（`base_version` 必填） |
| `PATCH /defect-tickets/:id/begin-verification` | **手动进入验证**：要求至少一条 action 且全 done，同事务两跳 ANALYZED→ACTION_DONE→V1（`base_version` 必填） |
| `POST /verifications` | **三次验证规范路径**（`base_version` 必填；`actor=ai` 且 `pass` → `403 ai_cannot_close`；记录带 `round`） |
| `POST /defect-tickets/:id/verifications` | 上一行的等价别名 |
| `PATCH /defect-tickets/:id/reanalyze` | REOPENED→ANALYZED，DB 触发器 `verification_round+1`（`base_version` 必填） |
| `PATCH /defect-tickets/:id` | 通用字段更新（priority/q_type 等；`base_version` 必填；不接受 status） |
| `DELETE /defect-tickets/:id` | 软删（`base_version` 必填） |
| `POST /mock-exams` | **BE-05** 组卷建模考（`{exam_profile_id, mode:'module'\|'full', subject_id?, knowledge_node_id?, question_count, duration_limit_ms?}`）→ `201 {mock_exam, questions, question_count}`；题量不足 → `400 INSUFFICIENT_QUESTIONS`（body 带 `available`/`requested`）；**响应不含 `answer`/`analysis`**（提交前不泄题） |
| `GET /mock-exams/:id` | 取单个模考（含 `questions` jsonb 与 `report`） |
| `POST /mock-exams/:id/submit` | **BE-05** 提交收卷（`base_version` 必填）→ `200 {mock_exam, report, timed_out, elapsed_ms}`；同事务写 attempts + 回填 `questions[].attempt_id` + 生成 `report`；重复提交 → `409 already_submitted` |
| `GET /mock-exams/:id/report` | 读已生成报告；未提交 → `404 not_submitted` |
| `GET /exam-profiles/:id/mock-exams` | 某目标下模考列表（`mode` 过滤 + 分页，最新在前） |
| `DELETE /mock-exams/:id` | 软删模考（`base_version` 必填） |
| `POST /review-cycles` | **BE-06** 生成周期复盘快照（`{user_id, cycle_type:'daily'\|'weekly'\|'monthly', period?}`）→ `201 {id, cycle_type, period, metrics, completed, version, period_start_at, period_end_at, time_zone}`；同 `user_id`+`cycle_type`+`period` 已存在 → `409 ALREADY_EXISTS`（body 带 `existing_id`，**不覆盖**） |
| `GET /review-cycles?user_id=&cycle_type=&period=&completed=` | **BE-06** 复盘列表（`user_id` 必填，否则 `400 missing_user_id`；按 `period DESC` 排序，分页 `{items,...page}`） |
| `GET /review-cycles/:id` | **BE-06** 取单份复盘快照 |
| `PATCH /review-cycles/:id` | **BE-06** 只允许改 `completed`（`base_version` 必填；改 `metrics`/`period` 等 → `400 IMMUTABLE_FIELD` 带 `immutable_fields`） |
| `DELETE /review-cycles/:id` | **BE-06** 软删（`base_version` 必填） |
| `GET /users/:userId/verification-tasks` | **BE-04** 验证任务列表（只出 `V1/V2/V3`；可按 `status` / `urgency` 过滤，分页；每行带回 `entered_at` / `window_days` / `days_left` / `urgency`） |
| `GET /users/:userId/verification-summary` | **BE-04** 验证看板聚合（各 stage 数量 + 逾期/临期/正常计数） |
| `POST /ai/questions:generate` | BYOK 生成题（count 1–20 校验） |
| 乐观锁 | 版本冲突 → `409` |
> 契约收敛（详见 REVIEW-NOTES.md §4 附带修正）：`analyze` 规范方法为 `POST`（`PATCH` 为兼容别名），缺归因错误码统一为 `missing_error_layer_or_cause`（废弃自造的 `missing_analysis`），`POST /verifications` 为规范路径、嵌套路径为等价别名。
> BE-03 完成：缺陷单 / actions / verifications 全部迁到 `server/repositories/` + 真 PG。四表 + 三张缺陷单相关表都已走仓储层；**仅 AI 生成任务仍在内存**（BE-08 同步服务时再迁）。
> BE-04 是**纯查询层**：两个 `GET` 端点，不写 `UPDATE`/`INSERT`/`DELETE`，也不做状态迁移（状态机归 BE-03）。
### 缺陷单状态机与 round 机制（BE-03）

状态迁移图（每步均经 `core/index.mjs` 纯函数前置校验 → 400 可读码；DB 触发器 `check_defect_transition` 兜底 → 防绕过）：

```
DRAFT ──analyze(补全归因)──▶ ANALYZED ──begin-verification──▶ ACTION_DONE ──▶ V1
                                                                  │
                              ▲                                  │ 三次验证 pass
                              │ reanalyze(round+1)               ▼
                         REOPENED ◀──fail── V1/V2/V3            V2 ──pass──▶ V3 ──pass──▶ CLOSED
                              ▲                    │
                              └──────── fail ──────┘
```

- **不变量**：`ACTION_DONE !== CLOSED`；任一验证 `fail → REOPENED` 且 `reopen_count+1`；连续重开 ≥3 提示抽验；**仅用户可 mark pass**（`actor=ai && pass → 403 ai_cannot_close`）。
- **进入验证必须手动**：`PATCH /:id/begin-verification` 要求至少一条 action 且全 done，同事务两跳 `ANALYZED→ACTION_DONE→V1`（直接跳 V1 会被 DB 触发器拒绝）。
- **`verification_round` 机制**：`REOPENED→ANALYZED` 时由 DB 触发器 `+1`；`verifications` 唯一索引为 `(defect_ticket_id, stage, round)`，故新 round 可重新提交 V1/V2/V3，**历史验证记录全部保留**。应用层只读取 `verification_round` 当 round 值，绝不写回（派生列由触发器维护）。
- **base_version 强制**：所有 PATCH/DELETE 与 `POST /verifications` 必填 `version`；冲突 → `409 client_merge`（当前行 + incoming）。
### 验证任务列表与临期提醒（BE-04）

纯查询层：只读、不写状态。两个端点都按 `user_id` 隔离。

**窗口值**（`server/verify_window.mjs` 的 `VERIFY_WINDOWS`，**不硬编码在 SQL**）：

| stage | 窗口 | 取值依据 |
|---|---|---|
| `V1` | 7 天 | 开发文档「3–7 天」取上限 |
| `V2` | 14 天 | 开发文档「1–2 周」取上限 |
| `V3` | 21 天 | 限时模考给更宽松的观察期 |

**urgency 三态**（`computeUrgency(enteredAt, windowDays, now)`）：

| 值 | 条件 | 含义 |
|---|---|---|
| `overdue` | `daysLeft <= 0` | 已逾期（`daysLeft = 0` 即今天到期，也算逾期） |
| `due_soon` | `1 <= daysLeft <= 3` | 临期，3 天内要做 |
| `normal` | `daysLeft > 3` | 正常 |

计算口径：`elapsedDays = floor((now - enteredAt) / 1天)`、`daysLeft = windowDays - elapsedDays`、`overdueDays = max(0, -daysLeft)`。**不足一天向下取整**，避免刚进入不到 24 小时就被算成「已过 1 天」。

#### `GET /users/:userId/verification-tasks`

Query：`status`（逗号分隔 `V1,V2,V3`，非法 → `400 INVALID_STAGE`）、`urgency`（逗号分隔 `overdue,due_soon,normal`，非法 → `400 INVALID_URGENCY`）、`limit`、`offset`。

数据源：`defect_tickets.status IN ('V1','V2','V3') AND deleted_at IS NULL`。**不查 `REOPENED`**（那需要重新归因，不属于待验证）、**不查 `ACTION_DONE`**（还没进验证窗口）。

响应：

```json
{
  "items": [
    {
      "id": "...", "stage": "V2",
      "entered_at": "2026-11-11T02:00:00.000Z",
      "window_days": 14, "days_left": 9, "overdue_days": 0, "elapsed_days": 5,
      "due_at": "2026-11-25T02:00:00.000Z",
      "urgency": "normal",
      "verification_round": 1, "reopen_count": 0,
      "knowledge_node_id": "...", "knowledge_node_title": "极限与连续",
      "knowledge_node_freq_tag": "high",
      "subject_id": "...", "subject_name": "数学一"
    }
  ],
  "total": 1, "limit": 50, "offset": 0
}
```

`total` 是 **urgency 过滤后的总数**（因为 urgency 在应用层算，无法下推到 SQL 计数），不随 `limit/offset` 变化。排序：`entered_at ASC, id ASC`（越早进入越靠前）。

#### `GET /users/:userId/verification-summary`

```json
{
  "total": 7,
  "by_stage":   { "V1": 3, "V2": 2, "V3": 2 },
  "by_urgency": { "overdue": 1, "due_soon": 2, "normal": 4 },
  "overdue": 1, "due_soon": 2, "normal": 4
}
```

实现上**直接复用 `listVerificationTasks` 再内存聚合**，保证两个端点的数字永不因两份 SQL 漂移而不一致。

#### ⚠️ 「进入当前阶段的时间」是混合取法

`schema.sql` **没有** `v1_started_at` / `status_changed_at` 之类字段（已冻结，本轮不改）。取法如下：

| stage | `entered_at` 来源 | 精确度 |
|---|---|---|
| `V2` | 本 round 内 **V1 `pass` 记录的 `created_at`** | 精确 |
| `V3` | 本 round 内 **V2 `pass` 记录的 `created_at`** | 精确 |
| `V1` | `defect_tickets.updated_at`（退化） | **近似** |

V1 为什么只能近似：`begin-verification` 只把 `status` 写成 `V1`，**不落 `verifications` 行**（验证记录是提交结果时才写的），所以没有「刚进入 V1」的时间戳可查。

**语义偏差**：`updated_at` 会被 `set_updated()` 在任何 `UPDATE` 时刷新，包括与状态无关的 `patch`（改 priority / 改归因等）。结果是 V1 的 `entered_at` **往后漂移 → 已过天数少算 → 晚报而非误报逾期**。方向上是刻意选的安全侧（宁可晚提醒，不能冤枉用户）。影响面：仅 V1 阶段；BE-06 复盘统计若要算「V1 待了多久」，同样只有这个近似值，需在统计口径里注明。

### 限时模考与报告（BE-05）

生命周期只有**两态**：创建即 `in_progress`（组卷完成、计时开始），提交即生成报告。没有「created→in_progress→submitted→analyzed」四态，也没有后台任务——报告同步算出。

**组卷抽题**（`server/repositories/mock_exams.mjs`）：

```sql
-- 1) 先探可用量（不足则 400 INSUFFICIENT_QUESTIONS，body 带 available/requested）
SELECT count(*)::int AS available FROM questions
 WHERE deleted_at IS NULL AND subject_id = $1;

-- 2) 真抽题：随机 + 只取公开列（不含 answer/analysis）
SELECT id, subject_id, knowledge_node_id, type, stem, options, difficulty, is_subjective, tags
  FROM questions
 WHERE deleted_at IS NULL AND subject_id = $1
 ORDER BY random() LIMIT $2;
```

不复用 `questions.listBySubject/listByKnowledgeNode`：它们按 `created_at` 排序（不随机）且 `limit` 封顶 200。

**报告字段**（`server/mock_report.mjs` 的 `reportGenerator`，纯函数零依赖）：

| 字段 | 内容 | 说明 |
|---|---|---|
| `module_accuracy` | `{[knowledge_node_id]: {title, correct, total, accuracy, ungraded}}` | 按考点直接分组（MVP 不引入「模块」新概念）；无考点的题归 `__ungrouped__`；`accuracy` 分母只算已判分 |
| `avg_duration_ms` | `{overall, by_knowledge_node:{[id]:{title, count, avg_duration_ms}}}` | 四舍五入到毫秒 |
| `stability` | 近 3 次同 mode + 同 profile 模考总正确率的**变异系数**（总体口径，除以 n） | 首次模考返回 `null`；<2 个有效样本也 `null` |
| `defect_repeat_rate` | `{repeat_count, total_wrong, rate}` | 只统计**错题**中 `question_id` 命中 `CLOSED` 缺陷单的；分母 0 时 `rate=0`（非 NaN） |
| `strategy_execution` | **恒 `null`** | 跳过的理由见 REVIEW-NOTES §20 |
| `v3_candidates` | `[{defect_ticket_id, question_id, knowledge_node_id}]` | 错题的考点命中该用户 `status='V3'` 缺陷单 |
| `overall` | `{correct, total, accuracy, ungraded}` | **`total` 只计已判分**（未判分题不进分母，单独由 `ungraded` / `ungraded_count` 反映）；`accuracy = correct / total` |

**判分口径**：主观题（`is_subjective=true` 或 `type` 为 `essay`/`short_answer`）与非空标准答案缺失 → `is_correct=null`（**未判分，不进准确率分母**）；有标准答案但用户未作答 → `false`（计错）。归一比较 = `NFKC` + 去空白/全半角标点 + `toUpperCase`，与 `normalizeQuestionText()` 同口径。

**超时收卷**（拍板项 1）：创建时记 `duration_limit_ms`，计时在前端；提交时后端算 `elapsedMs = submitted_at - created_at`，`elapsedMs > duration_limit_ms + 60_000`（60s 宽限）即判 `timed_out=true`，**未作答题一律计错**，并按已作答部分出报告。

**V3 绑定流程**（BE-05 不直接触发状态迁移）：

1. 模考提交 → 报告里出现 `v3_candidates`（每项含 `defect_ticket_id`）；
2. 前端展示引导：「这道错题对应的缺陷单正在 V3 验证」；
3. 用户点确认 → 走 **BE-03 已有**的 `POST /defect-tickets/:id/verifications`（`verify_type='timed_mock'`，`base_version` 必填）；
4. 状态迁移由 BE-03 状态机负责，BE-05 只负责「指出该做哪道」。

**事务边界**：`POST /mock-exams/:id/submit` **整段 `withTransaction`**——写 attempts 多行 + 回填 `mock_exams.questions[].attempt_id` + 写 `report` jsonb，全成或全败。组卷 `POST /mock-exams` 也是单事务（查量 + 抽题 + 插行）。

### 日/周/月复盘（BE-06）

**用户触发，非定时任务**（拍板项 1）：`POST /review-cycles` 当场算一份快照落库，`GET` 读历史。不跑 cron、不推送、不导 PDF。

周期格式与默认值：

| `cycle_type` | `period` 格式 | 示例 | 不传 `period` 时 | 时区 |
|---|---|---|---|---|
| `daily` | `YYYY-MM-DD` | `2026-11-17` | 当前**日历日** | `Asia/Shanghai` |
| `weekly` | ISO 8601 周 `YYYY-Www` | `2026-W47` | 当前 ISO 周 | `Asia/Shanghai` |
| `monthly` | `YYYY-MM` | `2026-11` | 当前月 | `Asia/Shanghai` |

> 时区为何是上海而不是 UTC：`users.timezone` 默认 `Asia/Shanghai`，若按 UTC 切日界，中国用户的 daily 复盘会横跨两天（08:00 → 次日 08:00）。周期边界统一用 `Intl.DateTimeFormat` + `timeZone` 求「当地午夜」，转成 UTC 后左闭右开（`startAt <= t < endAt`）。ISO 周用标准算法（第 1 周 = 含 1 月 4 日那周），带回读校验——`2026-W53` 合法（2026 恰有 53 周），`2025-W53`/`2027-W53` 被拒。

**七项 metrics 口径**（存在 `review_cycles.metrics` jsonb）：

| 字段 | 含义 | 关键口径 |
|---|---|---|
| `open_defects` | 手中还压着多少单 | `{total, by_status}`，**时点量**：看 `created_at < 周期结束` 且 `status <> CLOSED` 的全部单（历史单仍算）；`by_status` 固定七键（不含 CLOSED） |
| `layer_dist` | 本周新长了多少 | `{error_layer: count}`，**周期内增量**：只看 `created_at` 落在周期内，**不按 status 过滤**（含已 CLOSED）；空/null 归 `unclassified` |
| `verify_pass_rate` | 验证通过率 | `{pass, fail, total, rate}`；`total=0 → rate=null`（区分「没做验证」与「全错」） |
| `mock_stability` | 近 3 次模考稳定度 | 复用 BE-05 `computeStability()`；只取周期结束前的模考；样本 < 2 → `null` |
| `target_progress` | 离目标分还差多少 | `{target_score, latest_mock_score, rate}`；`latest_mock_score = report.overall.accuracy × 100`；`target_score` 缺失或 0 → `rate=null` |
| `reopen_hotspots` | 反复重开集中在哪 | 周期内**新建**且 `reopen_count>0` 的单按考点 `SUM(reopen_count)`，`top 5` → `[{knowledge_node_id, title, reopen_count_sum}]` |
| `strategy_execution` | 策略执行度 | MVP **恒为 `null`**（无「主动跳过」行为记录，强算即伪指标）；不在 `metrics` 里，见 BE-05 报告 |

响应示例：

```json
{
  "id": "8f0f...",
  "cycle_type": "weekly",
  "period": "2026-W47",
  "version": 1,
  "completed": false,
  "period_start_at": "2026-11-15T16:00:00.000Z",
  "period_end_at":   "2026-11-22T16:00:00.000Z",
  "time_zone": "Asia/Shanghai",
  "metrics": {
    "open_defects": { "total": 3, "by_status": { "DRAFT": 0, "ANALYZED": 1, "ACTION_DONE": 0, "V1": 1, "V2": 1, "V3": 0, "REOPENED": 0 } },
    "layer_dist": { "concept": 3, "method": 1 },
    "verify_pass_rate": { "pass": 1, "fail": 1, "total": 2, "rate": 0.5 },
    "mock_stability": 0.816497,
    "target_progress": { "target_score": 400, "latest_mock_score": 50, "rate": 0.125 },
    "reopen_hotspots": [ { "knowledge_node_id": "...", "title": "资料分析", "reopen_count_sum": 5 } ]
  }
}
```

**为什么同周期重复提交回 409 而不是 upsert**（拍板项 2）：复盘是「点按钮那一刻的快照」，覆盖会让历史数字无法复现。要重算就 `DELETE` 旧的再 `POST`（body 的 `resolution: 'delete_then_recreate'` 就是这个意思）。`schema.sql` 没有 `(user_id, cycle_type, period)` 唯一约束，靠仓储层 `lockParentRow(users)` + `findByPeriod` 同事务查重实现——并发两次只留一条（集成测试覆盖）。

**计算与写入分离**：`POST /review-cycles` 先**在写事务外**算完六项聚合，再开事务落库。理由是聚合要跑 6 条 SQL，若全包进写事务会长时间持有 `users` 行锁；而这个窗口是安全的——复盘本就是快照，读到稍早的数据也算正确。
### 题目导入（BE-02：`POST /questions/import`）

管线四阶段：`extractText`（按 mime 分派）→ `splitQuestions`（规则切题）→ `dedupe`（按 `content_hash`）→ `separateAssets`（图片占位识别，MVP 只计数不落库）→ 逐题入库，**整段包在 `withTransaction` 内**，任一步失败整批回滚。

请求体（JSON，只支持 base64 —— 见下方说明）：

```json
{
  "filename": "exam.md",
  "mime": "text/markdown",
  "content_base64": "IyDnq6DliI3popguLi4=",
  "subject_id": "可选 uuid（题目挂载的科目）",
  "knowledge_node_id": "可选 uuid",
  "source": "import",
  "default_type": "choice"
}
```

响应 `200`：

```json
{
  "imported": 12,
  "duplicates": [{ "content_hash": "…", "existing_id": "…", "stem": "…" }],
  "errors": [],
  "stats": { "kind": "markdown", "mime": "text/markdown", "total": 12, "preamble_lines": 3, "bytes": 2702, "image_placeholders": 0 }
}
```

| 支持格式 | mime | 说明 |
|---|---|---|
| Markdown | `text/markdown` | 直接按 UTF-8 读 |
| 纯文本 | `text/plain` | 同上 |
| CSV | `text/csv` | 同上（不解析列语义，靠行内题号切题） |
| 文字型 PDF | `application/pdf` | `pdfjs-dist` 抽文本；**扫描版无文本层 → `422 UNSUPPORTED_PDF`** |
| Excel | `application/vnd.openxmlformats-officedocument.spreadsheetml.sheet` | 手写最小读取，**只读第一张 sheet** 的纯文本，不做复杂版式 |
| 图片 | `image/*` | MVP 不支持 OCR → `422 UNSUPPORTED_IMAGE`（V1 补） |

**体积上限（MVP 收紧，比开发文档的 50MB/200 页更严）**：单文件 ≤ **10MB**、文字型 PDF ≤ **100 页**、图片 ≤ 20 张。超限 → `413 PAYLOAD_TOO_LARGE`，`body` 提示「请拆分后重试」。收紧理由：同步导入没有任务表可承载长任务，超过这个量级客户端等待与超时风险不可控。

**为什么只有 base64 JSON、没有 multipart**：Node 原生无 multipart 解析器，引 `busboy`/`formidable` 会打破「运行时依赖只保留 `pg` + `pdfjs-dist`」这条线；导入是低频操作，base64 的 +33% 体积在 10MB 上限内可接受。multipart 与 `import_jobs` 异步任务表一起放 V1。

**切题规则（`server/import/splitter.mjs`，纯函数零依赖）**：只认四类行首编号 —— `1.` / `1、`、`（1）`、`一、`、`第1题`。题干内部自带的编号列表会被误判成新题起点（已知局限，样本集 `tests/fixtures/questions/` 与 `splitter.test.mjs` 把这个基线写成了测试），V1 上 AI 切题解决。

| 错误码 | 状态码 | 含义 |
|---|---|---|
| `PAYLOAD_TOO_LARGE` | 413 | 超过 10MB / 100 页 |
| `UNSUPPORTED_PDF` | 422 | 扫描版 PDF（无文本层）或 PDF 损坏 |
| `UNSUPPORTED_IMAGE` | 422 | 图片（OCR 未实现） |
| `UNSUPPORTED_XLSX` | 422 | xlsx 解析失败 |
| `UNSUPPORTED_MEDIA` | 415 | 不支持的 mime |
| `EMPTY_CONTENT` | 400 | 空文件，或抽到文字但切不出任何题 |
| `MISSING_FILENAME` / `MISSING_CONTENT` / `INVALID_BASE64` | 400 | 请求体缺字段或 base64 非法 |

**图片占位**：题干/选项里的 `![alt](asset:...)`、`data:` 内联图、`http(s)://` 外链会被识别并计入 `stats.image_placeholders`，但 **MVP 不下载、不存储、不写 `assets` 行**（入库后 `questions.asset_refs` 仍为 `null`）。真正的图片分离放 V1，与对象存储、OCR 一起做。
---

## 5.5 应用界面与字体（`tillroad_app/`）

### 字体

接入第三方中文字体 **霞鹜新致宋（LXGW Neo ZhiSong）**，SIL Open Font License 1.1，可免费商用与嵌入。

| 项 | 值 |
|---|---|
| 文件 | `tillroad_app/assets/fonts/霞鹜新致宋字体.ttf` |
| 体积 | 3,881,858 B（约 3.7 MiB） |
| Flutter 注册名 | `LXGWNeoZhiSong`（`lib/theme/app_theme.dart` 的 `kFontFamily`） |
| 字体内部族名 | `霞鹜新致宋 简`（与注册名不同，互不冲突） |
| 字重 | **仅 Regular**（`OS/2.usWeightClass = 400`，无 `fvar` 表，非可变字体） |
| 授权 | SIL OFL 1.1（嵌入应用、随包分发、商用均允许；修改后须换名） |

**为什么只在 `textTheme.textStyle` 写一次不够**：`WidgetsApp` 会把 `textTheme.textStyle` 装成全局 `DefaultTextStyle`（`flutter/lib/src/widgets/app.dart` 里 `DefaultTextStyle(style: widget.textStyle!)`），页面里没有显式 `style` 的 `Text` 会继承它。但 `CupertinoNavigationBar` / `CupertinoSliverNavigationBar` / `CupertinoTabBar` / `CupertinoButton` / `CupertinoPicker` 内部各自重新铺 `DefaultTextStyle`，继承链在那里断掉。所以 `CupertinoTextThemeData` 的 **9 个 TextStyle 全部逐个写了 `fontFamily`**：`textStyle` / `navTitleTextStyle` / `navLargeTitleTextStyle` / `tabLabelTextStyle` / `actionTextStyle` / `actionSmallTextStyle` / `navActionTextStyle` / `pickerTextStyle` / `dateTimePickerTextStyle`。

**`CupertinoAlertDialog` 是例外**：它在 `cupertino/dialog.dart` 里把标题/正文/按钮文字**硬编码成 `fontFamily: 'CupertinoSystemText'`**，而构造函数只暴露 `title`/`content`/`actions` 三个 Widget，没有 `titleTextStyle`/`messageTextStyle` 参数 → **无法从主题覆盖**。唯一办法是给每个 `Text` 显式写 `style: TextStyle(fontFamily: kFontFamily, ...)`（`Merge` 时显式值胜出）。参见 `lib/pages/home_page.dart` 的 `_showComingSoon`。

**合成加粗的代价**：字体只有一个字重，所以界面里所有 `fontWeight: 600/700`（大标题、卡片标题、对话框标题）都是引擎的**伪粗体（faux bold）**——把 Regular 字形填充加厚，笔画会略糊。要真正印刷质量的粗宋，需另补 Bold 字重文件到同一 `family` 下（`fonts:` 列表里加第二项 `weight: 700`），本轮未做（用户硬约束：不擅自下载 Bold）。

**体积提示**：一个 3.7 MiB 的字体文件只放单个字重，对 APK 体积影响明显（debug APK 从 143 MB → 约 147 MB）。V1 若引入 Bold 会再增加同等体积，可考虑按需裁剪子集。

### 目录与依赖

- `tillroad_app/lib/` 18 个 dart 文件：`main.dart` / `theme/app_theme.dart` / `mock/` 2 个（`home_mock`、`defects_mock`）/ `pages/` 6 个 / `widgets/` 8 个。
- 运行时依赖只有 `cupertino_icons`；dev 依赖 `flutter_lints` + `flutter_launcher_icons`。**无状态管理库、无网络库、无路由库、无图表库**。
- 兼容平台：`android` / `ios` / `windows`（Windows 仅为本机开发期验证用，交付目标是移动端）。
- 已知 `flutter analyze` 输出：**0 error / 0 warning / 12 info**，12 条全是同一条 `deprecated_member_use`（`package:flutter/cupertino.dart` 在 3.47+ 提示改用 `package:cupertino_ui/cupertino_ui.dart`）。刻意不改——改它需要引入第二个运行时依赖，与「只加 cupertino_icons」的约束冲突。

### 缺陷单界面（FE-03）

列表页与详情页，数据全部来自 `lib/mock/defects_mock.dart`（8 条 mock，**覆盖全部 8 个 status 各一条**），不连后端。

| 文件 | 职责 |
|---|---|
| `lib/mock/defects_mock.dart` | `DefectStatus`（八态）/ `DefectPriority` / `VerifyResult` / `DefectAction` / `StatusEvent` / `DefectTicket` + 8 条 mock + `relativeTime` / `absoluteTime` |
| `lib/widgets/defect_badges.dart` | `statusColor` / `priorityColor` / `StatusBadge`（`AnimatedContainer` 250ms）/ `PriorityBadge` / `RoundChip` / `ReopenChip` / `CardShell` / `InfoRow` / `InfoText` |
| `lib/widgets/defect_card.dart` | `DefectCard`（三行卡片）+ `FilterChipRow`（横向滚动筛选条） |
| `lib/widgets/verification_progress.dart` | `VerificationProgress`（V1/V2/V3 当前阶段橙色左边框高亮）+ `StatusTimeline`（手画圆点竖线） |
| `lib/pages/defects_page.dart` | 列表页（`CupertinoSliverNavigationBar` + 筛选条 + `SliverList`） |
| `lib/pages/defect_detail_page.dart` | 详情页（六栏基本信息 + 处理动作 + 三次验证 + 状态时间线 + 底部固定操作区） |

**筛选分组**：全部 / 进行中（DRAFT+ANALYZED+ACTION_DONE+**REOPENED**）/ 待验证（V1+V2+V3）/ 已关闭（CLOSED）。`REOPENED` 归入进行中，卡片上带红色「重开 N 次」角标。

**为什么详情页用 `CupertinoSliverNavigationBar` 而不是 `CupertinoPageScaffold(navigationBar:)`**：后者**不会给 child 预留导航栏高度**，`ListView` 的内容会钻到导航栏下面（实测截图里归因首行被压住）。改成 sliver 导航栏后与首页/列表页同构，顺带获得大标题折叠。

**为什么筛选条不用 `CupertinoSegmentedControl`**：5 个中文标签挤在 375pt 宽下会换行或截断，且选中色被系统主题覆盖；改用 `AnimatedContainer` 手写 chip，可精确控制 250ms `easeInOut` 与配色。

**底部主按钮**按状态分支：DRAFT→「去归因」/ ANALYZED→「暂无操作」/ ACTION_DONE→「进入验证」/ V1·V2·V3→「提交验证」/ REOPENED→「重新归因」/ CLOSED→不给按钮，居中显示绿色「已关闭」。当前点击只弹提示（需接后端 API）。

---

## 6. 当前里程碑与后续

- ✅ 文档评审 + 4 项 P0 / 4 项 P1 修订（详见 [REVIEW-NOTES.md](<REVIEW-NOTES.md>)）
- ✅ `core/` 端无关核心规则层 + 14 个单元测试
- ✅ `server/` HTTP API 骨架 + 集成测试
- ✅ **BE-00 归档**：Schema CI 在 GitHub Actions 的 PG15 service 容器上真跑通过（Up#1 幂等 / Up#2 / Down / Up#3）
- ✅ **BE-01 第 1 步**：`core/validators.mjs` 17 个纯校验函数 + 15 个用例
- ✅ **BE-01 第 2 步**：`server/db/pool.mjs` + `server/repositories/base.mjs`（withTransaction / 乐观锁工具 / SQLSTATE 映射 / buildUpdateSet），29 个 fake-pool 单测 + 4 条 PG smoke
- ✅ **BE-01 第 3 步**：四表仓储（`exam_profiles` / `subjects` / `knowledge_nodes` / `capability_layers`）+ 28 条 PG 集成测试（含并发查重竞态），CI 加 `node-tests` job 并防「假绿」
- ✅ **BE-01 第 4 步**：路由层拆分为 `server/routes/`（四表端点全部接 PG、AC-KM-01 模板预置事务、AC-KM-02 层级副本事务、级联软删事务、`base_version` 强制）+ `core/templates.mjs` 模板数据 + 测试改造成 fake 层 32 条 / PG 集成层 11 条
- ✅ **BE-02**：题目导入管线（`server/import/` 四阶段 + `POST /questions/import`）+ `questions`/`assets` 仓储（`content_hash` 查重）+ 3 份切题样本与 `pdfjs-dist` 依赖（8 条切题单测 + 7 条导入集成）
- ✅ **BE-03**：缺陷单完整状态机迁 PG（DRAFT→ANALYZED→ACTION_DONE→V1→V2→V3→CLOSED/REOPENED + `verification_round` + 应用层/DB 触发器双层防线）+ `defect_tickets`/`actions`/`verifications` 三仓储 + `begin-verification` 手动门禁 + fake 层改造；13 条真 PG 集成测试留在 CI
- ✅ **BE-04**：验证任务列表 + 临期提醒（**纯查询层**）：`server/verify_window.mjs` 窗口常量与 `computeUrgency` 纯函数（13 条单测）+ `listVerificationTasks` / `verificationSummary` 两仓储查询 + 2 个 GET 端点（fake 层 11 条、真 PG 集成 19 条）；进入时间采用 V2/V3 精确 + V1 近似（`updated_at`）混合取法
- ✅ **BE-05**：限时模考 + 报告生成（两态生命周期）：`server/mock_report.mjs` 四项报告纯函数（22 条单测）+ `mock_exams`/`attempts` 两仓储（随机组卷 + 同事务收卷）+ 5 个端点（组卷/详情/提交/报告/列表/软删）；`v3_candidates` 只指路不当迁移，`strategy_execution` 返回 `null`
- ✅ **BE-06**：日/周/月复盘统计（**用户触发快照**）：`server/review_period.mjs` 周期起止纯函数（ISO 周 + `Asia/Shanghai` 日界，10 条单测）+ `server/review_stats.mjs` 六项 metrics 全 SQL 层聚合 + `review_cycles` 仓储与 5 个端点（同周期 `409 ALREADY_EXISTS`）+ 删掉 BE-03 遗留的假 `/review-cycles`；fake 层 6 条、真 PG 集成 12 条
- ✅ **FE-01**：Flutter 项目初始化 + 首页看板（纯 Cupertino、无第三方状态/网络/路由/图表库）：`tillroad_app/` 13 个 dart 文件 + `home_mock.dart` 假数据；大标题折叠、弹簧按压、倒计时 `AnimatedSwitcher`、Reduce Motion 降级；`flutter analyze` 0 error；Android 17 模拟器真机跑通并截图
- ✅ **FE-01 字体**：接入霞鹜新致宋（`assets/fonts/霞鹜新致宋字体.ttf`，SIL OFL 1.1），`CupertinoTextThemeData` 九个 TextStyle 逐项覆盖 + `CupertinoAlertDialog` 三处硬编码 `CupertinoSystemText` 的显式覆盖；Android 17 模拟器真机复核四张截图
- ✅ **FE-03**：缺陷单列表 + 详情页（纯 mock，不连后端）：`defects_mock.dart` 8 条覆盖八态 + `defect_badges`/`defect_card`/`verification_progress` 三组共用组件 + 状态筛选条（进行中含 REOPENED）+ 详情页六栏/处理动作/三次验证进度/手画状态时间线/底部状态化操作区；`flutter analyze` 0 error，`flutter test` 5/5，Android 17 模拟器真机截图（列表页 + 详情页 + 时间线）
- ⏳ **下一批**：FE-02 建题/导入页 → FE-11 审核七态 UI → BE-07 缺陷分布看板 / BE-08 同步服务 → 补 Flutter 工具链后移植 Dart / 接入 NestJS
详细顺序见 [REVIEW-NOTES.md §7](<REVIEW-NOTES.md>) 与 [mvp-tasks.md](<mvp-tasks.md>)。

---

## 7. 一键提交（`git acp`）

仓库不用 husky/lefthook，也不提供 `scripts/acp.sh`——alias 只影响本机、不占仓库、CI 也不依赖它（CI 直接 `npm ci && npm test`）。

**Git Bash** 执行一次：

```bash
git config --global alias.acp '!f() { git add -A; if ! git diff --cached --quiet; then git commit -m "${1:-wip}"; fi; git push; }; f'
```

**PowerShell** 用这条（Windows 的原生参数传递会吃掉裸 `"`，必须写成 `\"`；否则写进配置的是 `-m ${1:-wip}`，引号丢失后 `git acp "四表仓储 + 集成测试"` 会报 `pathspec '四表仓储' did not match`）：

```powershell
git config --global alias.acp '!f() { git add -A; if ! git diff --cached --quiet; then git commit -m \"${1:-wip}\"; fi; git push; }; f'
```

之后每个里程碑一条命令即可：

```bash
git acp "feat(be-01): 四表仓储 + 集成测试 + README 一键提交说明"   # add + commit + push
git acp                                                         # 不带文案 → commit message 为 wip
```

装完建议核一下：Git Bash 那条应原样打印 `-m "${1:-wip}"`；PowerShell 那条会多一层反斜杠（`-m \"${1:-wip}\"`）——两者执行效果相同，都正常。

```bash
git config --get alias.acp   # 关键：必须看到 ${1:-wip}（否则引号已丢失，多词文案会报 pathspec）
```

> - 本仓已跟踪 `origin/main`，所以裸 `git push` 可用；新克隆若未设上游，先 `git push -u origin main` 一次。
> - **工作区无改动时也会 push**：`git add -A` 后若暂存区为空则跳过 commit 直接 push（旧版用 `&&` 串联，`nothing to commit` 返回非 0 会让 `&&` 短路、push 永远不执行）。这使得「上一条 commit 已在本地但没推上去」的情况下再跑一次 `git acp` 能补推。
> - 已跟踪但无任何改动的仓库上跑 `git acp` 会输出 `Everything up-to-date`，退出码 0——正常。
> - 提交前建议先跑 `npm test`（本机无 PG：190 passed / 115 skipped；CI 设 `RUN_PG_INTEGRATION=1` 则全量真跑）。
