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
│   ├── index.test.mjs         #   29 个 fake 层用例（路由分发 / 入参 / base_version / 409，不连 PG）
│   ├── index.integration.test.mjs  # 10 条路由层 PG 集成（AC-KM-01/02 + 级联软删，仅 CI 跑）
│   ├── routes/
│   │   ├── _http.mjs          #   ok/fail/assertValid/readBaseVersion/httpError/readBody/pagination
│   │   ├── index.mjs          #   dispatch()：health 优先，再按 ROUTE_MODULES 顺序问各 match()
│   │   ├── exam_profiles.mjs  #   目标配置 + AC-KM-01 事务 + 级联软删事务
│   │   ├── subjects.mjs       #   科目 + AC-KM-02 层级副本事务
│   │   ├── knowledge_nodes.mjs#   考点树（含扁平/嵌套两种 GET）
│   │   ├── capability_layers.mjs # 层级模板 + customizable gate
│   │   └── defect_tickets.mjs #   缺陷单/模考/复盘/AI（暂为内存实现，BE-03 重写）
│   ├── db/
│   │   ├── pool.mjs           #   createPool() + 7 个 OID 类型解析器（numeric→number 等）
│   │   ├── pool.test.mjs      #   9 个用例（零 PG）
│   │   └── pg-smoke.integration.test.mjs   # 4 条 smoke（仅 RUN_PG_INTEGRATION=1 跑）
│   └── repositories/
│       ├── base.mjs           #   withTransaction / buildUpdateSet / conflictError / mapPgError
│       ├── base.test.mjs      #   20 个用例（fake client）
│       ├── _common.mjs        #   四表共享原语（乐观锁 / 父行加锁 / 查重 / 软删）
│       ├── exam_profiles.mjs  #   考试目标 CRUD
│       ├── subjects.mjs       #   科目 CRUD
│       ├── knowledge_nodes.mjs#   考点树 CRUD + getTree（递归 CTE 防环）
│       ├── capability_layers.mjs # 能力层级模板 + customizable gate
│       └── repositories.integration.test.mjs # 28 条 PG 集成测试
├── migrations/                # PG 迁移入口（psql 的 \ir ../schema.sql）
├── schema.sql                 # 数据库单一事实来源
├── .github/workflows/schema-ci.yml  # schema 幂等/可逆 + Node 单测 + PG 集成
├── *.md                       # 设计 / 决策 / 评审文档
├── package.json               # scripts: test / test:core / test:server / test:integration / start
└── REVIEW-NOTES.md / README.md
```

> 设计取舍：本机无 Flutter SDK、无 PostgreSQL/Docker，故把「与端无关的核心闭环规则」抽成纯 JS 层，当前环境即可验证，且与 `schema.sql` 的触发器/约束/去重/状态机严格对齐、契约零漂移；后续可直接移植到 Dart（FE）或 NestJS（BE）。

---

## 3. 快速开始

环境要求：**Node.js ≥ 20**（本机实测 v24.19.0）。唯一运行时依赖为 `pg`（BE-01 第 2 步引入），需先 `npm install` / `npm ci`。

```bash
npm ci            # 按 package-lock.json 安装（含 pg@8.23.x）

# 跑全部单测（core 规则层 + server 骨架 + 仓储工具层）
npm test

# 分别只跑核心规则层 / API 骨架单测 / 集成测试（后者需 PG）
npm run test:core
npm run test:server
npm run test:integration   # pg-smoke + 四表仓储集成（需 RUN_PG_INTEGRATION=1）

# 启动 HTTP API（默认 http://127.0.0.1:3000，可用 PORT 覆盖）
npm start
```

数据库（需 PG15+，本机未安装，故由 GitHub Actions 的 PG15 service 容器真跑）：

```bash
psql -v ON_ERROR_STOP=1 -f migrations/0001_init_up.sql   # 打印 SCHEMA_VERIFY_OK 即通过
psql -v ON_ERROR_STOP=1 -f migrations/0001_init_down.sql # 回滚
```

集成测试（四表仓储 + 路由层 + PG smoke）需要真实 PG，默认跳过：

```bash
# 集成测试的 before() 会自行执行整份 schema.sql，无需先手动迁移
RUN_PG_INTEGRATION=1 npm test
```

> **集成测试必须串行跑**：`npm test` 已内置 `--test-concurrency=1`。
> 三个 PG 集成测试文件共用同一个数据库（`tillroad_ci`），并行执行时彼此会触发
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
| `POST /defect-tickets` | 建单（禁用语 → `400 {error:"forbidden_phrase"}`；缺归因 → `400 {error:"missing_error_layer_or_cause"}`；未归因草稿 → `201 DRAFT`；带归因 → `201 ANALYZED`） |
| `POST /defect-tickets/:id/analyze` | DRAFT→ANALYZED 补齐归因（缺归因 → `400 missing_error_layer_or_cause`） |
| `POST /defect-tickets/:id/action` | ANALYZED→ACTION_DONE |
| `POST /verifications` | 三次验证规范路径（开发文档 §11 / schema.sql 附录；`actor=ai` 且 `pass` → `403`；记录带 `round`） |
| `POST /defect-tickets/:id/verifications` | 上一行的等价别名（骨架实现） |
| `GET /mock-exams/:id/report` | 模考报告 |
| `GET /review-cycles?type=weekly` | 周期复盘 |
| `POST /ai/questions:generate` | BYOK 生成题（count 1–20 校验） |
| 乐观锁 | 版本冲突 → `409` |

> 契约收敛（详见 REVIEW-NOTES.md §4 附带修正）：`analyze` 规范方法为 `POST`（原骨架的 `PATCH` 保留为兼容别名），缺归因错误码统一为 `missing_error_layer_or_cause`（废弃自造的 `missing_analysis`），`POST /verifications` 为规范路径、嵌套路径为等价别名。
> 第 4 步已完成接线：`exam_profiles` / `subjects` / `knowledge_nodes` / `capability_layers` 四组端点已走 `server/repositories/` + 真 PG（`POST /exam-profiles` 不再是内存实现）；缺陷单 / 模考 / 复盘 / AI 生成仍是内存 Map，等 BE-03/04、BE-05/06、BE-08 重写。

---

## 6. 当前里程碑与后续

- ✅ 文档评审 + 4 项 P0 / 4 项 P1 修订（详见 [REVIEW-NOTES.md](<REVIEW-NOTES.md>)）
- ✅ `core/` 端无关核心规则层 + 14 个单元测试
- ✅ `server/` HTTP API 骨架 + 集成测试
- ✅ **BE-00 归档**：Schema CI 在 GitHub Actions 的 PG15 service 容器上真跑通过（Up#1 幂等 / Up#2 / Down / Up#3）
- ✅ **BE-01 第 1 步**：`core/validators.mjs` 17 个纯校验函数 + 15 个用例
- ✅ **BE-01 第 2 步**：`server/db/pool.mjs` + `server/repositories/base.mjs`（withTransaction / 乐观锁工具 / SQLSTATE 映射 / buildUpdateSet），29 个 fake-pool 单测 + 4 条 PG smoke
- ✅ **BE-01 第 3 步**：四表仓储（`exam_profiles` / `subjects` / `knowledge_nodes` / `capability_layers`）+ 28 条 PG 集成测试（含并发查重竞态），CI 加 `node-tests` job 并防「假绿」
- ✅ **BE-01 第 4 步**：路由层拆分为 `server/routes/`（四表端点全部接 PG、AC-KM-01 模板预置事务、AC-KM-02 层级副本事务、级联软删事务、`base_version` 强制）+ `core/templates.mjs` 模板数据 + 测试改造成 fake 层 22 条 / PG 集成层 9 条
- ⏳ BE-03 / BE-04 → FE-09 / BE-08 → FE-11 → 补 Flutter 工具链后移植 Dart / 接入 NestJS
详细顺序见 [REVIEW-NOTES.md §7](<REVIEW-NOTES.md>) 与 [mvp-tasks.md](<mvp-tasks.md>)。

---

## 7. 一键提交（`git acp`）

仓库不用 husky/lefthook，也不提供 `scripts/acp.sh`——alias 只影响本机、不占仓库、CI 也不依赖它（CI 直接 `npm ci && npm test`）。

**Git Bash** 执行一次：

```bash
git config --global alias.acp '!f() { git add -A && git commit -m "${1:-wip}" && git push; }; f'
```

**PowerShell** 用这条（Windows 的原生参数传递会吃掉裸 `"`，必须写成 `\"`；否则写进配置的是 `-m ${1:-wip}`，引号丢失后 `git acp "四表仓储 + 集成测试"` 会报 `pathspec '四表仓储' did not match`）：

```powershell
git config --global alias.acp '!f() { git add -A && git commit -m \"${1:-wip}\" && git push; }; f'
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
> - 工作区无改动时 `git acp "x"` 会因「nothing to commit」失败（退出码非 0，`&&` 保证不会误 push）——预期行为。
> - 提交前建议先跑 `npm test`（本机无 PG：99 passed / 43 skipped；CI 设 `RUN_PG_INTEGRATION=1` 则全量真跑）。
