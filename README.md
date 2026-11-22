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
├── package.json               # scripts: test / test:core / test:server / test:integration / start / dev / db:*
├── scripts/                   # 本地运维脚本（联调新增，均 process.loadEnvFile()）
│   ├── migrate.mjs            #   用 pg 跑 schema.sql（代替 psql，避开 \ir 元命令）
│   ├── verify-schema.mjs      #   校验表/枚举/触发器/索引/函数数量
│   ├── seed-dev.mjs           #   幂等 seed：8 条缺陷单覆盖全 8 个 status
│   └── dev-start.mjs          #   探活 + 监听 0.0.0.0:3000（供 Android 模拟器 10.0.2.2 访问）
├── .env                       # 本地连接参数（已 gitignore，不入库）
├── tillroad_app/              # Flutter 前端（FE-01 已初始化，iOS/Android/Windows 三平台）
│   ├── lib/                   #   21 个 dart 文件：main / theme / config×1 / api×2 / mock×2 / pages×5 / widgets×8
│   ├── lib/api/               #   api_client（http 薄封装）+ defect_api（snake_case 映射）
│   ├── lib/config/            #   api_config（kUseMock / kApiBaseUrl / kDemoUserId）
│   ├── assets/icons/          #   1024 图标源（白底 app_icon + 透明底 foreground）
│   ├── assets/fonts/          #   霞鹜新致宋（单个 Regular 字重）
│   └── screenshots/           #   FE-01 / FE-03 / FE-03 联调验收截图
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

数据库（PG15+）：

- **CI**：由 GitHub Actions 的 PG15 service 容器真跑（`psql -v ON_ERROR_STOP=1 -f migrations/0001_init_up.sql`）。
- **本地**：本机未安装 PostgreSQL，联调时改用 Neon 云库（连接参数放 `.env`，已被 `.gitignore` 忽略），并用 `scripts/migrate.mjs` 代替 `psql`（因为 `migrations/0001_init_up.sql` 只有 `\ir ../schema.sql` 这条 psql 元命令，`pg` 驱动执行不了；脚本改为直接跑纯 SQL 的 `schema.sql`）。

```bash
npm run db:migrate      # = node scripts/migrate.mjs，跑 schema.sql，跑完自行校验
npm run db:verify       # = node scripts/verify-schema.mjs，打印表/枚举/触发器/索引/函数数量
npm run db:seed         # = node scripts/seed-dev.mjs，幂等灌 8 条缺陷单（覆盖全部 8 个 status）

# 有 psql 的机器仍可用原来的方式
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

### 本地联调（App ↔ 后端 ↔ 云数据库）

```bash
# 1. 准备连接参数（只需一次）：把 PG* 变量写进 .env
#    PGHOST / PGPORT / PGUSER / PGPASSWORD / PGDATABASE
#    PGSSLMODE=require        # 云库强制 TLS
#    PGCONNECT_TIMEOUT=30     # 云库冷启动可能超过 pool 的 5s 连接超时

# 2. 建库 + 灌数据（幂等，可重复跑）
npm run db:migrate && npm run db:seed

# 3. 启动后端（监听 0.0.0.0，否则 Android 模拟器连不上）
npm run dev             # = node scripts/dev-start.mjs
```

`npm run dev` 会先探活数据库、打印记录数，再监听 `0.0.0.0:3000`，并打印三个可用地址：

| 客户端 | 地址 |
|---|---|
| Android 模拟器 | `http://10.0.2.2:3000`（模拟器到宿主机的固定映射） |
| iOS 模拟器 / Windows 桌面 / curl | `http://localhost:3000` |

> **`PGSSLMODE` 与 `PGCONNECT_TIMEOUT` 都能直接生效，不需要改 `server/db/pool.mjs`**：
> `pg@8.23.1` 的 `readSSLConfigFromEnvironment()` 原生读 `PGSSLMODE`（`require`/`verify-full` 等→启用 TLS，`no-verify`→启用但不校验证书），
> `PGCONNECT_TIMEOUT` 也由驱动自己读（`node_modules/pg/lib/connection-parameters.js`）。
> 这样「接云库」不会污染业务代码——`pool.mjs` 至今没有一行 `ssl` 配置。
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

- `tillroad_app/lib/` 59 个 dart 文件：`main.dart` / `theme/` 1 / `config/` 3（`api_config`、`app_info`、`local_config`）/ `mock/` 2（`home_mock`、`defects_mock`）/ `api/` 5 / `logging/` 4 / `local/` 16（其中 `local/dao/` 5）/ `pages/` 16 / `widgets/` 11。
- 运行时依赖 `cupertino_icons` + `http` + `shared_preferences` + `share_plus` + `sqflite` + `path`（后两个是本地优先 R1 引入，见下节）；dev 依赖 `flutter_lints` + `flutter_launcher_icons` + `sqflite_common_ffi`（**仅测试用**，不进产物）。**无状态管理库、无路由库、无图表库、无 ORM、无 build_runner**。
- 兼容平台：`android` / `ios` / `windows`（Windows 仅为本机开发期验证用，交付目标是移动端；**Windows 上不启用本地库**，见下节）。
- 已知 `flutter analyze` 输出：**0 error / 0 warning / 51 info**（R1 前是 30 info，R1 新增 2 条、R2 新增 5 条、R4a 新增 14 条，均为同一 `deprecated_member_use`）。全部 info 都是同一条 `deprecated_member_use`（`package:flutter/cupertino.dart` 在 3.47+ 提示改用 `package:cupertino_ui/cupertino_ui.dart`）。刻意不改——改它需要引入第二个运行时依赖，与「纯 Cupertino」的约束冲突。

### 缺陷单界面（FE-03）

列表页与详情页。**FE-01/FE-03 初版数据全部来自 `lib/mock/defects_mock.dart`（8 条 mock，覆盖全部 8 个 status 各一条）；FE-03 联调后默认走真实 API**，mock 仅作离线回退（`kUseMock = true`）。

| 文件 | 职责 |
|---|---|
| `lib/mock/defects_mock.dart` | `DefectStatus`（八态）/ `DefectPriority` / `VerifyResult` / `DefectAction` / `StatusEvent` / `DefectTicket` + 8 条 mock + `relativeTime` / `absoluteTime` |
| `lib/config/api_config.dart` | `kUseMock` 总开关（**非 const**，便于测试翻转）/ `kDemoUserId` / `kApiBaseUrl`（按平台切）/ `kApiTimeout` |
| `lib/api/api_client.dart` | 薄封装 `http`：统一超时、非 2xx → `ApiException`（带 `statusCode` / `body` / `isNetworkError`） |
| `lib/api/defect_api.dart` | 读：`fetchDefectTickets`（支持 `status` 逗号多值）/ `fetchDefectDetail` / `fetchKnowledgeNodes` / `fetchExamProfiles` / `fetchSubjects`；写：`createDefectTicket` / `analyzeDefectTicket`（含 REOPENED→reanalyze）/ `markActionDone` / `beginVerification` / `submitVerification`。手写 snake_case 映射，不引 `json_serializable` |
| `lib/widgets/form_field.dart` | 表单共用件：`FormFieldGroup`（标题+红星+hint+内联红字）/ `FormTextField` / `FormChipGroup` / `FormSubmitButton`（busy 转圈）/ `FormErrorBanner` / `FormScaffold` / `FormEmptyHint` |
| `lib/pages/defect_create_page.dart` | 建单表单（q_type / error_layer 六 chip / error_cause 多行 / 考点 chip / priority 三 chip / 动态动作列表） |
| `lib/pages/defect_analyze_page.dart` | 归因表单，DRAFT「补充归因」与 REOPENED「重新归因」共用；409 后自动回填服务端最新值 |
| `lib/pages/defect_verify_page.dart` | 提交验证表单：`verify_type` 按 stage 白名单给选项、`result` 二选一、`evidence` 自证说明 |
| `lib/widgets/defect_badges.dart` | `statusColor` / `priorityColor` / `StatusBadge`（`AnimatedContainer` 250ms）/ `PriorityBadge` / `RoundChip` / `ReopenChip` / `CardShell` / `InfoRow` / `InfoText` |
| `lib/widgets/defect_card.dart` | `DefectCard`（三行卡片）+ `FilterChipRow`（横向滚动筛选条） |
| `lib/widgets/verification_progress.dart` | `VerificationProgress`（V1/V2/V3 当前阶段橙色左边框高亮）+ `StatusTimeline`（手画圆点竖线） |
| `lib/pages/defects_page.dart` | 列表页（`CupertinoSliverNavigationBar` + 筛选条 + `SliverList` + 加载/错误/空态三态） |
| `lib/pages/defect_detail_page.dart` | 详情页（六栏基本信息 + 处理动作 + 三次验证 + 状态时间线 + 底部固定操作区） |
**筛选分组**：全部 / 进行中（DRAFT+ANALYZED+ACTION_DONE+**REOPENED**）/ 待验证（V1+V2+V3）/ 已关闭（CLOSED）。`REOPENED` 归入进行中，卡片上带红色「重开 N 次」角标。

**为什么详情页用 `CupertinoSliverNavigationBar` 而不是 `CupertinoPageScaffold(navigationBar:)`**：后者**不会给 child 预留导航栏高度**，`ListView` 的内容会钻到导航栏下面（实测截图里归因首行被压住）。改成 sliver 导航栏后与首页/列表页同构，顺带获得大标题折叠。

**为什么筛选条不用 `CupertinoSegmentedControl`**：5 个中文标签挤在 375pt 宽下会换行或截断，且选中色被系统主题覆盖；改用 `AnimatedContainer` 手写 chip，可精确控制 250ms `easeInOut` 与配色。

**底部主按钮**按状态分支（已全部接真实写接口）：DRAFT→「去归因」push 归因页 / **ANALYZED 与 ACTION_DONE→ 都是「进入验证」** / V1·V2·V3→「提交验证」push 验证页 / REOPENED→「重新归因」push 归因页 / CLOSED→不给按钮，居中显示绿色「已关闭」。

**为什么 ANALYZED 也走「进入验证」**：DB 触发器只接受 `ANALYZED → ACTION_DONE → V1` 逐步跳，而 `PATCH /:id/begin-verification` 已在同一事务里做了这两跳（应用层先 `assertTransition(cur.status,'ACTION_DONE')` → `actions.assertAllDone` 门禁 → 写 ACTION_DONE → 再 `beginVerification({status:'ACTION_DONE'},'V1')`，两次都过 core 纯函数，触发器再兜底）。所以「进入验证」是 ANALYZED 唯一的前进路径——早期把它写成「暂无操作」会让整条闭环卡在 ANALYZED 无法推进。动作未完成时后端返回 `NO_ACTIONS` / `ACTIONS_NOT_DONE`，由 `_handleWriteError` 给出可操作提示。

#### 写路径的错误处理（乐观锁 / 禁用语 / AI 关单）

| HTTP | `error` 字段 | 前端表现 |
|---|---|---|
| 409 | `conflict` + `current` | toast「该单已被修改，正在刷新到最新状态。」并自动 `_refreshDetail()`；归因页还会把表单回填成服务端最新值 |
| 400 | `forbidden_phrase` / `FORBIDDEN_PHRASE_IN_ERROR_CAUSE` | **内联红字**（在「具体错因」字段下方）「请写出具体哪一步算错或记错，不要写「X」这类词」，不弹 alert |
| 400 | `missing_error_layer_or_cause` | 内联到对应字段（层级/错因） |
| 400 | `NO_ACTIONS` / `ACTIONS_NOT_DONE` | toast「先添加至少一条处理动作」/「还有处理动作未完成，全部勾选后才能进入验证」 |
| 400 | `INVALID_BASE_VERSION` | 「缺少版本号（乐观锁）。请刷新页面后重试。」 |
| 400 | `INVALID_VERIFICATION_STAGE` / `ILLEGAL_DEFECT_TRANSITION` | 「当前状态不支持这个操作，正在刷新到最新状态。」+ 刷新 |
| 403 | `ai_cannot_close` | 「AI 不能替用户关单：验证通过必须由你本人标记。」 |
| — | 网络错误（`statusCode == null`） | 顶部橙色 `FormErrorBanner` + 「重试」 |

**禁用语是 7 个不是 5 个**：`粗心 / 马虎 / 没掌握 / 我懂了 / 大意 / 差不多 / 忘了`（见 `core/index.mjs:29-31` `FORBIDDEN_PHRASES`）。表单提示与 `kForbiddenPhrases` 常量必须与 core 同源，漏一个就会让用户先过前端预校验、再被后端 400 抦下。

**`verify_type` 选项按 core 白名单而不是自拟**：`V1 = redo_hidden / similar_variant / teach_back`、`V2 = new_question`、`V3 = timed_mock`（见 `core/index.mjs:40-44` `STAGE_WINDOWS`）。注意 **V3 只有 `timed_mock`**，没有「讲题」——后端枚举能收但不合 core 阶段语义，前端只列白名单内的。

**归因层级是自由文本**：`defect_tickets.error_layer` 在 schema 里是 `text`（`schema.sql:299`），不是枚举。六个选项（知道/识别/执行/抗压/策略取舍/稳定迁移）来自开发文档 §20 行测六层，仅作前端常用项；后端不做白名单校验。

#### 验证任务页（FE-04）

`lib/pages/verify_page.dart` 整页重写，接 BE-04 的两个只读端点：

| 文件 | 职责 |
|---|---|
| `lib/api/verification_api.dart` | `VerificationTask`（18 字段，派生 `daysLabel` / `windowLabel` / `freqLabel`）+ `VerificationSummary`（`total/overdue/dueSoon/normal/byStage`）+ `VerificationApi` 两个 fetch |
| `lib/pages/verify_page.dart` | 三色摘要卡片（可点击即筛选）+ stage 筛选条 + 三态列表 + 每卡局部 loading 拉详情再 push |
| `lib/pages/home_page.dart` | 「今日待验证」标题右侧改为真实三色计数（`_CountDot` 圆点 + 数字），失败回落 mock 条数并标「离线」 |

设计取舍（三条都写进了源码 JSDoc）：

1. **urgency 由后端算，前端只展示**。窗口天数是后端常量（`server/verify_window.mjs` 的 `{V1: 7, V2: 14, V3: 21}`），前端再算一遍就会出现「服务端说逾期、客户端说还剩 1 天」的双口径。
2. **筛选走后端**。BE-04 的 `status` 与 `urgency` 都支持逗号分隔多值，所以切筛选 = 重新请求，而不是内存过滤。这与 FE-03 缺陷单列表不同（那里首轮后端只支持单值，只能在本地算）——**别再照搬**。
3. **摘要始终拉全量，不随筛选变**。否则「逾期 3」在筛到 V1 后会变成「逾期 1」，用户会以为数据丢了。

点卡片进详情不走 `pushReplacement`：`DefectDetailPage` 构造要求一个完整 `DefectTicket`（它先用传入数据首屏渲染，再 `initState` 补拉 `verifications`/`actions`），所以 `_openDetail` 先 `fetchDefectDetail`，拿到后一次性 push；点击到 push 之间只给**该卡片**局部 `CupertinoActivityIndicator`，不遮全屏。
后端同轮修（只改 `create` 路径，未动状态机/触发器/schema）：`server/repositories/defect_tickets.mjs` 的 `create` 原本只把 `actions` 写进 `defect_tickets.actions` **jsonb 冗余列**，**不生成 `actions` 表行**；而 `begin-verification` 的门禁 `actions.assertAllDone()` 读的是 `actions` 表 → 新单永远是 `NO_ACTIONS`，闭环走不通。现在 `create` 在插完主行后调 `insertActionsForTicket()` 逐条插表（入参兼容 `['文案']` 与 `[{content, due}]`，空串静默跳过），并在同一个 `withTransaction` 内（任一条失败整笔回滚），返回 `{...ticket, actions: created}`。

> 前端 `createDefectTicket` 里「建单后逐条 `POST /:id/actions`」的补丁**保留但已非必需**（向后兼容旧后端）：新客户端直接建单即可。

---
#### 接真实 API 后的状态与取舍（FE-03 联调）

列表页与详情页都改为**三态**：`CupertinoActivityIndicator` 加载中 → 数据或「加载失败 + 重试」。详情页额外做了一层保护：**先用列表页传来的 `ticket` 立即渲染**，再在 `initState` 补拉详情，失败时只在顶部加一条橙色提示条（`_RefreshFailedBanner`）而不是把整页换成错误屏——因为详情页的归因/状态/优先级本来就能看，把可见内容换掉反而更差。

**筛选曾有一轮在本地算，现在改回服务端了**：联调首轮时后端 `GET /users/:userId/defect-tickets` 的 `status` 参数是**单值**（`status = $1`），而「进行中」= DRAFT+ANALYZED+ACTION_DONE+REOPENED、「待验证」= V1+V2+V3 都是**多状态集合**，所以只能客户端过滤。写操作联调时后端已把该参数改成**逗号分隔多值**（`status::text = ANY($n::text[])`，参数化数组、不拼字符串），前端筛选因此可以交给后端。
**真实响应暴露的 3 个契约缺口（均已处理）**：

| 缺口 | 现象 | 处理 |
|---|---|---|
| 无考点/科目名 | 列表与详情都只有 `knowledge_node_id`（两端点走 `SELECT *` 不 JOIN） | ✅ **写操作联调已修**：仓储 `SELECT_WITH_DISPLAY` 用 `LEFT JOIN knowledge_nodes`（`title`→`knowledge_node_title`、`freq_tag`→`knowledge_node_freq_tag`）与 `LEFT JOIN subjects`（→`subject_name`）。用 LEFT 不用 INNER，因为 `knowledge_node_id` 可空，INNER 会丢单 |
| 字段名是 `status` 不是 `stage` | 缺陷单响应里状态字段叫 `status`，而验证记录里同概念叫 `stage` | 保持现状（两者语义确实不同：单的状态 vs 某次验证的阶段） |
| `verification_state` 恒 `pending` | 该 jsonb 列不会随 `verifications` 表变化自动更新 | 前端从响应里的 `verifications` 数组按 stage + 当前 round 推导（**只取 `round` 等于当前 `verification_round` 的记录**，否则重开后旧 round 的 pass 会误显示成新 round 已通过） |
**状态时间线只显示两个节点**：schema 没有 `defect_events` 表，无法还原完整状态变更历史。当前用 `created_at` + 当前 `status` 造最小序列（创建 → 当前状态）。完整历史需新增 `defect_events(defect_ticket_id, from_status, to_status, at, reason)` 并让触发器写入。

---
#### 首页看板与冷启动降级（FE-07）

首页四块（倒计时 / 今日待验证 / 缺陷分布 / 快捷入口）现在全部接真实数据，三路请求用 `Future.wait` 并发发出：

| 卡片 | 数据源 | 失败时 |
|---|---|---|
| 倒计时 | `GET /users/:userId/exam-profiles`（取首个 `active`） | `_GoalEmptyCard`（「考试目标加载失败 / 还没有设置考试目标」+ 重试/去设置） |
| 今日待验证 | `GET /users/:userId/verification-summary` | 回落 mock 条数 + 「（离线）」小字 |
| 缺陷分布 | `GET /users/:userId/defect-stats` | 回落 mock 分布 + 「离线数据」小字 |

**为什么加后端聚合端点而不是前端算**（决策理由写进了源码）：①前端已经为缺陷单页拉过一次全量列表，首页再拉就是两次全量；②「未关闭」的业务定义（`status::text <> 'CLOSED'`）只应存在一处，两边各写一遍必然漂移；③八态计数一次 `GROUP BY status` 算完，不会漏键——返回的 `by_status` 用 `ALL_STATUSES` 白名单预填 0，即使将来 schema 新增状态也不会改契约形状。

**骨架屏与超时**：数据未到时显示 `_SkeletonBlock`（灰块 + `_Bone` 呼吸动画，`reduceMotion` 时静态）而不是 0 或 mock 数字；数据到达用 `AnimatedSwitcher` 250ms 淡入。`kApiTimeout` 为 **15s**——不是拉到 40s（用户早走了），而是 15s 内拿到就显示真实数据、拿不到就逐卡片降级。

**三个在真机验收时才暴露的 UI 缺陷（已修）**：

1. `_SkeletonBlock` 写死 `height: 108` 但内容实高是 `32(padding) + 13 + 14 + 32 + 10 + 13 = 114` → 真机出现 `BOTTOM OVERFLOWED BY 6.0 PIXELS` 黄黑警告条。改为 `constraints: BoxConstraints(minHeight: height)`，让内容自撑。
2. 骨架阶段「今日待验证」右侧仍显示 mock 的「3 项」→ 违反「首屏不显示 mock」。`_summaryTrailing()` 返回类型改 `Widget?`，骨架阶段直接返回 `null`。
3. 同一问题在「缺陷分布」的 `共 N 条` 上也存在 → `_openCount` 改 `int?`，骨架阶段返回 `null`，trailing 用 `switch` 表达式不渲染。

> 「离线数据」小字原本贴在卡片圆角上显得被裁，已补 `left/right: 16` + `bottom: 14` 内边距。

**冷启动实测（Android 17 模拟器 + Neon 云库）**：`am force-stop` 后冷启，899ms / 1753 / 2597 / 3467ms 四帧均仍为原生闪屏，**4194ms 起稳定在加载完成画面**——即冷启动到首帧完整内容约 **4.2s**（其中包含 Neon 冷启动）。热启动（不杀进程）回前台无重新加载。用 `adb root` + `iptables -A OUTPUT -p tcp --dport 3000 -j DROP` 阻断后端可稳定复现骨架屏与离线兜底（`-j REJECT` 更快，避免等满 15s）。
#### 限时模考页（FE-05）

模考链路四页 + 列表页，把 BE-05 的五个端点接到界面：

| 文件 | 职责 |
|---|---|
| `lib/api/mock_api.dart` | 14 个数据类（`MockExam` / `MockQuestion` / `MockReport` / `V3Candidate` …）+ `MockExamApi` 五方法 |
| `lib/pages/mock_create_page.dart` | 组卷配置：考试目标 → 模式 → 科目/考点 → 题量 → 限时 |
| `lib/pages/mock_exam_page.dart` | 答题页：计时 + 点阵导航 + 交卷确认 + 超时自动交卷 |
| `lib/pages/mock_report_page.dart` | 报告页：总分 / 模块正确率 / 平均用时 / 稳定性与重复率 / V3 候选 |
| `lib/pages/mock_page.dart` | 「我的模考」列表：已交卷历史 + 进行中分区 + 下拉刷新 |
| `lib/pages/home_page.dart` | 「开始模考」快捷入口 push 组卷页（唯一改动处） |

**四个和后端有关的坑（都写在源码注释里）**：

1. **组卷响应里的题干在顶层，不在 `mock_exam` 里**。`mock_exam.questions` 只是 jsonb 索引行 `[{question_id, attempt_id, is_correct, duration_ms}]`，没有题干/选项；可渲染的题目在响应顶层的 `questions` 数组。所以 `POST /mock-exams` 返回的是 `MockExamCreated`（exam + questions）而不是裸 `MockExam`。
2. **`mock_exams` 表没有 `submitted_at` 列**。列表页要显示「交卷时间」时取 `updated_at`（提交是同事务 `UPDATE`，`updated_at` 由触发器刷新）。
3. **报告的 `title` 曾恒为 `null`（FE-06 已修）**——`server/repositories/mock_exams.mjs` 传给 `reportGenerator` 的键是 `title:`，而 `server/mock_report.mjs` 原先只读 `q.knowledge_node_title`，键名不一致。FE-06 任务 A 把读取改成 `q.knowledge_node_title ?? q.title ?? null`（兼容两种键名，旧报告不受影响），并加 `T6b` 单测锁住。前端 `displayTitle` 兜底保留（`title` 仍可能为 null，例如考点已被删除），此时显示 `考点 <id 前 8 位>`（`__ungrouped__` → `未归属考点`），**不伪造成中文考点名**。
4. **报告不含标准答案与解析**（`HIDDEN_FIELDS = ['answer','analysis']` 在组卷和读卷时都剔除），所以报告页没有「查看解析」，只有一行说明引导用户去缺陷单建单归因。

**`V3 验证建议` 只指路不迁移**：报告里的 `v3_candidates` 由后端按 `knowledge_node_id` 匹配当前 `status = 'V3'` 或 `'CLOSED'` 的缺陷单算出（不要求 `question_id` 非空）。前端点某条候选先 `fetchDefectDetail` 拿完整 `DefectTicket`，再 push 复用 `DefectVerifyPage`——该页会按 `VERIFY_STAGES.V3.types` 自动把验证方式限定为「限时模考」，不需要前端另写白名单。

**一个真机才暴露的遮挡 bug（已修）**：报告页首屏「本次正确率」卡与答题页题干都被导航栏压住。根因在 `CupertinoPageScaffold` 源码（`page_scaffold.dart:146-190`）：只有 `navigationBar.backgroundColor.alpha == 0xFF`（即 `shouldFullyObstruct` 为真）时它才给 child 加 `EdgeInsets.only(top: navBarHeight)`；半透明时只改 `MediaQuery.padding.top` 而不加 padding。两页原先都写了 `SafeArea(top: false)`，于是既不拿 padding 也不读 MediaQuery → 内容顶到 y=0。修法是两处导航栏背景改成不透明 `AppColors.groupedBackground`。

**超时链路**：`duration_limit_ms` 交给后端判定（`elapsedMs > duration_limit_ms + 60000` 才算超时，留 60s 宽限），前端另有自己的本地倒计时——`_deadline` 是**绝对时间**而非每次 tick 递减，避免 ticker 丢帧累积误差。剩余 ≤60s 时倒计时变红并闪烁，归零自动交卷（不弹二次确认），报告顶部显示橙色「超时交卷」徽标。

#### 复盘页（FE-06）

日 / 周 / 月复盘列表 + 六项 metrics 详情，把 BE-06 的五个端点接到界面：

| 文件 | 职责 |
|---|---|
| `lib/api/review_api.dart` | 7 个数据类（`ReviewCycle` / `ReviewMetrics` / `OpenDefects` / `VerifyPassRate` / `TargetProgress` / `ReopenHotspot` …）+ 周期类型枚举 `ReviewCycleType` + `ReviewApi` 五方法 |
| `lib/pages/review_page.dart` | 复盘列表：日/周/月 chip 切换 + 生成 ActionSheet + 409 引导查看已有 |
| `lib/pages/review_detail_page.dart` | 详情六块卡 + 底部「标记已读 / 删除复盘」操作区 |
| `lib/pages/home_page.dart` | 快捷入口「复盘」改为切到 Tab 4（唯一改动处） |
**四个和后端有关的取舍（都写在源码注释里）**：

1. **只有 `POST /review-cycles` 返回周期起止时刻**。`GET` 列表走的是裸 `SELECT *`（`server/repositories/review_cycles.mjs:listByUser`），行里只有 `id/user_id/cycle_type/period/metrics/completed/created_at/updated_at/version/deleted_at`，**没有** `period_start_at` / `period_end_at` / `time_zone`。所以 `ReviewCycle` 把这三个字段设为可空，列表页只用 `period` 字串展示。
2. **`period` 不传，让后端算当前周期**。前端只发 `{user_id, cycle_type}`，周期格式（`daily: YYYY-MM-DD` / `weekly: YYYY-Www` / `monthly: YYYY-MM`）与时区（`Asia/Shanghai` 日界）完全由 `server/review_period.mjs` 决定——否则前端要自己实现 ISO 周算法，两边容易漂移。
3. **同周期重复生成是 `409 ALREADY_EXISTS`，且 body 带 `existing_id`**。前端把这个 `existing_id` 当作「查看已有」的目标，而不是弹一个干巴巴的「已存在」：用户点「查看已有」直接进那份复盘的详情页。`resolution: 'delete_then_recreate'` 是后端给的提示，前端在对话框正文里写清了「先打开已有那份删除，再生成新的」。
4. **`PATCH` 只接受 `completed`，`DELETE` 也要 `version`**。`PATCH` 传其他键会 400 `IMMUTABLE_FIELD`，所以 `markCompleted` 的 body 只发 `{version, completed: true}`；`DELETE` 走 `readBaseVersion`，缺 `version` 直接 400——这两处都靠前端从详情页持有的 `_cycle.version` 补上。

**列表页刻意不做服务端 `cycle_type` 过滤**：一次拉全量（`limit: 100`）再本地按 chip 过滤。理由是两个体验点——①切 chip 不用等网络；②只有拿到全量才能区分「还没有任何复盘」和「「月复盘」下暂无记录」两种空态（任务 C6）。代价是数据量大了要改回分页，已记在遗留项里（当前个人题库量级不成问题）。

**六块 metrics 卡全部纯 Widget 手绘**，不引图表库：未关闭缺陷用七态堆叠条 + 图例（颜色复用 `defect_badges.dart:statusColor`），错因层级/重开热点用横条，验证通过率用两根竖柱，目标进度用 8px 进度条。`mock_stability` 为 null 时显示「本周期无模考」，不是画一条 0 的柱子。

**一个真机才暴露的按钮 bug（已修，影响面不止本页）**：`lib/widgets/common.dart` 的 `EmptyState` 里 `CupertinoButton` 只给了 `color: AppColors.accent`，没给 `foregroundColor`。Flutter 的 plain 按钮样式在传了 `color` 之后，文字仍然取主题 `primaryColor`（= 同一个 accent），于是**蓝底蓝字**——截图里空态按钮看起来是个空蓝块（`D:\DSH\flutter\packages\flutter\lib\src\cupertino\button.dart:501-505` 的 `textStyle.copyWith(color: effectiveForegroundColor)`，`:474` 的 `backgroundColor` 才用 `widget.color`）。修法是显式 `foregroundColor: CupertinoColors.white`。这个组件被 FE-01 起的多个页面共用，属于顺带修掉的存量 bug。

**动效**：周期类型切换用 `AnimatedContainer(250ms, easeInOut)`；六块卡片用 `_StaggeredFadeIn`（每块延迟 `45 * index` ms 后 `260ms` 淡入）；`disableAnimations` 为 true 时直接显示终态，不做延迟与淡入。

#### 运行日志导出（用户侧排障）

App 给外部测试用户后拿不到 adb logcat，所以自带一份「可导出、已脱敏」的运行日志。入口在**设置页 → 日志 → 导出运行日志**（FE-UI 重构前是首页导航栏右上角的文档图标，现在两个调试入口都收进设置页）。

| 文件 | 职责 |
|---|---|
| `lib/logging/app_logger.dart` | 单例 `AppLogger`（debug/info/warn/error）+ 500 条环形缓冲 + **写缓冲区之前**的脱敏 |
| `lib/logging/log_file_writer.dart` | 按天滚动 `app-YYYY-MM-DD.log`、保留 3 天、总量超 5MB 删最旧（当天文件永不删） |
| `lib/logging/log_export.dart` | 内存缓冲 + 近 3 天文件 + 设备信息头 → 单个 `.txt`，返回 `LogExportResult` |
| `lib/logging/nav_observer.dart` | `LoggingNavigatorObserver` 记录 `[NAV] push X ← Y`，替代逐处改 push |
| `lib/config/app_info.dart` | `kAppName` / `kAppVersion`（与 pubspec 手工同步，不引 `package_info_plus`） |

**脱敏是在 `AppLogger._write()` 里做的，而不是在导出时**——顺序是「先 `sanitizeLogText()`，再构造 `LogEntry`」，所以内存缓冲里也不存在原文（任务 C4）。四条规则：`Bearer <token>` → `Bearer ***`；裸 `tk_xxx` → `***`；UUID → 前 4 位 + `****`（`11111111-1111-4111-8111-111111111111` → `1111****`）；URL query 里的 `token=/access_token=/api_key=/password=` → `***`（任务书没点名，但 URL 要落盘，顺手堵上）。

**埋点位置**：`main.dart` 的 `FlutterError.onError`（保留原 handler，所以 debug 仍打印）+ `PlatformDispatcher.instance.onError`；`api_client.dart` 的 `_send()` 一处覆盖全部端点——请求前 `[API] GET /path`、2xx `[API] GET /path 200 OK 342ms`、非 2xx `... 500 ERROR 1200ms code=... body=...`（body 截 200 字符，避免题干进日志）、网络/超时 `... 网络失败 95ms：...`。`diagnose()` 的结果也记一条 `[DIAG]`。

**新增依赖只有 `share_plus`**（实际解析到 13.3.1）：`SharePlus.instance.share(ShareParams(files: [XFile(path)]))` 调系统分享面板。注意 `path_provider` 只是它的传递依赖，**代码里不直接 import**，日志目录用 `Directory.systemTemp`（Android 上即应用私有 cache）。

日志文件位置（Android）：`/data/data/<pkg>/code_cache/tillroad/logs/`，导出文件在同级 `export/`，分享时由 share_plus 复制到 `cache/share_plus/`。

#### 底部 Tab 收敛与「我的 / 设置」（FE-UI 重构）

底部导航从 **5 个 Tab 收敛到 3 个**（首页 / 缺陷单 / 我的）。验证、模考、复盘三个页面 **文件全部保留**，只是不再是并列分区，而是从「我的」页或首页快捷入口按需 `appRoute()` push 的二级页。

| 文件 | 职责 |
|---|---|
| `lib/main.dart` | `RootTabs`：3 个 `BottomNavigationBarItem`，`_switchTab` 上界跟着数量走（`index > 2` 直接 return） |
| `lib/pages/profile_page.dart` | 「我的」：账户卡片（`maskUuid` 脱敏 ID + 切换 Token / 退出）+ 数据概览四格 + 功能列表四入口 |
| `lib/pages/settings_page.dart` | 设置：连接与诊断 / 日志 / 账户 / 危险操作 / 关于 五个 `CupertinoListSection` |
| `lib/pages/home_page.dart` | 右上角 trailing 从「诊断 + 日志」两个图标改为单个 `CupertinoIcons.gear` → push 设置页 |

**为什么全部改 push 而不再切 Tab**：只剩 3 个 Tab 时「验证 / 模考 / 复盘」没有对应索引（旧代码写死 verify=2 / mock=3 / review=4）。继续用切 Tab 语义，一旦 Tab 数量变化，这些写死的索引会**静默指到别的页面**——现在索引 2 已经是「我的」，点「今日待验证」会把用户送到错误的分区。改 `appRoute()` push 后，导航意图用**类型**表达（`VerifyPage()`），不依赖任何数字。

**数据概览四格的口径**：总数与已关闭来自 `GET /users/:userId/defect-stats`（`total` / `by_status.CLOSED`）；**验证完成率 = CLOSED / total**——状态机规定只有 V3 pass 才能进 CLOSED，所以这个比值就是严格意义上的「验证走完比例」；「进行中 N」来自 `verification-summary.total`。「学习天数」后端没有该统计口径，直接显示 `—`（不编数字）。

**逐项降级，不整页报错**：两路接口各自 `try/catch`，失败只让对应格子变成 `—`。理由与首页一致：Neon 免费版空闲会挂起，唤醒要 20–40s；若一个请求超时就整页变错误页，用户连「设置」「切换 Token」都点不了——而这恰恰是排查离线时的第一反应。账户卡片与功能列表完全不依赖网络，无条件可用。

**设置页的两个危险操作**（均 `isDestructiveAction: true`、取消在前、标题用 `AppColors.overdue` 红色）：

| 操作 | 实际动作 |
|---|---|
| 清除本地缓存 | `AppLogger.instance.clearAll()` + 删 `${Directory.systemTemp}/tillroad/` + 清 `shared_preferences` 中除 `api_token` 外的键；**保留登录态、不跳页** |
| 清除所有数据 | 上述 + `prefs.clear()` + `saveApiToken('')`（清掉进程内副本）→ 经 `onSessionCleared` 或 rootNavigator `pushAndRemoveUntil` 回 Token 输入页 |

**「退出」为什么用 push 而不是 pushAndRemoveUntil**：本页只是 Tab 的根页，把 `RootTabs` 从根 Navigator 上剥掉之后就再也回不来（本页无权重建 `ApiTokenGate`）。push 到 Token 页、保存后 `pop` 回本页，与「换一个凭证继续用」的预期一致。真正的整栈替换只发生在「清除所有数据」，那时确实需要重新走一遍启动门。

**账户卡片的 ID 为什么是脱敏的**：后端已经把 `/users/:userId` 路径参数按 Bearer Token 改写成对应 user，客户端本来就拿不到也不应展示真实 userId，且无 `/me` 接口。所以直接用 `maskUuid(kDemoUserId)`（复用 `lib/logging/app_logger.dart`）显示 `1111****`，下方 12px 灰字「本机演示身份 · 真实身份由 token 决定」，**不新增任何 API 调用**。

### 本地优先（`tillroad_app/lib/local/`）

> 设计文档：`docs/local-first-design.md`（第 8 章 R1 实现记录，第 9 章 R2 实现记录，第 10 章 R4a 实现记录）。**R1 只建地基**（App 行为零变化）；**R2 起四页先读本地、云端降级为后台刷新与写入通道**；**R4a 起写操作也本地化**（断网乐观更新 + 写队列，联网自动补推）。
**选型：`sqflite` 而非 Drift。** 单纯比依赖数：`sqflite` 只引入 1 个直接依赖（`path` 是它的路径依赖），Drift 要 5 个（`drift` / `drift_dev` / `build_runner` / `sqlite3_flutter_libs` / `drift_flutter`）再加一个代码生成步骤。本项目的查询只有约 15 条简单 SQL，手写映射与现有 `lib/api/*.dart` 风格一致（那里也是手写 snake_case 映射，不用 `json_serializable`），引 ORM 换不来收益。

| 文件 | 行数 | 职责 | 引入 |
|---|---|---|---|
| `lib/config/local_config.dart` | 25 | `kLocalFirstEnabled`（**R2 起为 `true`**，见下）+ `kLocalDbFileName` | R1 |
| `lib/local/local_schema.dart` | 317 | `kLocalSchemaVersion = 1` + 10 个 `CREATE TABLE` + 22 个索引（字符串常量，测试靠 `kLocalTableNames` / `kLocalIndexNames` 断言） | R1 |
| `lib/local/local_db.dart` | 146 | `LocalDb` 单例：惰性打开、并发只开一次、`close()`、`inspect()` 查 `sqlite_master` | R1 |
| `lib/local/dao/dao_base.dart` | 129 | `SyncState` / `PendingStatus` / `Col` / `LocalQuery` + `nowIso()` / `toLocalValue()` | R1 |
| `lib/local/dao/sync_table_dao.dart` | 180 | 基类 CRUD：`insert` / `insertAll` / `getByPk` / `getByServerId` / `list` / `update` / `delete` / `deleteSynced` / `deleteSyncedWhere` / `count` / `countUnsynced`（全部收 `DatabaseExecutor`，可传 `Transaction`） | R1 / R2 |
| `lib/local/dao/table_daos.dart` | 320 | 8 个表子类 + `LocalDaos` 聚合（含 `pending` / `meta`）；R2 新增 `countOpenByLayer` / `listVerifiableWithEnteredAt` | R1 / R2 |
| `lib/local/dao/local_meta_dao.dart` | 105 | `local_meta` 读写 + `MetaKey`（`token_fingerprint` / `last_sync_at` / `sync.<resource>.<field>`） | R1 |
| `lib/local/dao/pending_operations_dao.dart` | 234 | 写队列：`enqueue` / `listPending` / `markDone` / `markFailed` / `incrementRetry` / `markConflict` / `markDead`（R4a 起由推送引擎调用） | R1 |
| `lib/local/local.dart` | 110 | barrel，页面层只需一个 import | R1 / R2 / R4a |
| `lib/local/sha256.dart` | 143 | 纯 Dart SHA-256，**不引 `crypto` 包**；只用来算 `token_fingerprint` | R2 |
| `lib/local/verify_window.dart` | 215 | `VERIFY_WINDOWS` / `DUE_SOON_DAYS` / `computeUrgency` 的 Dart 移植，与 `server/verify_window.mjs` 同公式 | R2 |
| `lib/local/first_fill.dart` | 599 | `ensureInitialData()` 首次全量填充 + `LocalCache` 行映射回写 + `kLocalDataRevision` 通知 | R2 |
| `lib/local/local_queries.dart` | 330 | 六个本地读函数（缺陷单 / 验证任务 / 摘要 / 统计 / 当前考试档案），输出结构与云端 API 逐字对齐 | R2 |
| `lib/local/local_refresh.dart` | 270 | 「本地已有 → 全量分页对账」的后台刷新，带并发合流（四页同刷只打一次网络） | R2 |
| `lib/local/local_state_machine.dart` | 386 | `core/index.mjs` 纯函数的 Dart 移植：状态迁移表 / 禁用语 / 验证方式白名单 / 三道门禁，非法抛 `LocalValidationException` | R4a |
| `lib/local/write_queue.dart` | 604 | 五类写操作的「本地校验 → 乐观写库 → 入队」；`WriteQueueStatus` 提供同步状态与冲突查询 | R4a |
| `lib/local/push_engine.dart` | 652 | 队列补推 + 错误分级（409 conflict / 400·404 dead / 网络可重试退避）+ `PushScheduler` 四处触发 | R4a |
| `test/local_db_test.dart` | 665 | R1 的 27 个用例（E1–E5） | R1 |
| `test/verify_window_test.dart` | 267 | R2 的 29 个用例（边界 / 取整 / 非法入参 / wire 格式） | R2 |
| `test/local_state_machine_test.dart` | 251 | R4a 的 24 个用例，与 `core/index.test.mjs` 逐条对齐 | R4a |
| `test/write_queue_test.dart` | 335 | R4a 的 11 个用例：base_version 来源、门禁、冲突消解、SQL 插值回归 | R4a |
| `test/verify_window_test.dart` | 267 | R2 的 29 个用例（边界 / 取整 / 非法入参 / wire 格式） | R2 |
**10 张表**：`local_meta` / `exam_profiles` / `subjects` / `knowledge_nodes` / `defect_tickets` / `actions` / `verifications` / `mock_exams` / `review_cycles` / `pending_operations`。设计里的 `questions_cache`（T7）本轮**不建**（拍板第 6 条）；T11 `sync_state` 并入 `local_meta` 的 key/value（省一张表 + 一套 DAO）。

**`defect_tickets` 本地不落 4 类列**：`actions` jsonb（与 `actions` 表重复的快照，双写会不一致）、`verification_state` jsonb（实测恒 `pending`，前端早已改读 `verifications` 数组）、`knowledge_node_title` / `subject_name`（服务端 LEFT JOIN 出来的展示字段）、`deleted_at`（本地是投影，软删行拉取时直接不落库）。

**`kLocalFirstEnabled` 开关的作用**：R1 阶段为 `false`，**R2 起为 `true`**——首页 / 缺陷单 / 验证 / 我的四页先读本地库，云端降级为后台刷新与写入通道。改回 `false` 即整体回退到「每次打开都直连云端」的旧行为（四页里都保留了 `if (!kLocalFirstEnabled) { await _loadFromCloud(); return; }` 这一行分支）。`main()` 里仍会 `await LocalDb.database` 确认库能打开（失败只记日志 + 把开关强制置 `false`，不拖垮启动）。选 **可变顶层变量而非 `const`** 就是为了支持这种运行时降级（与既有 `kUseMock` 同一个做法）。

**R2 的三段式读取**（四页统一）：①读本地 DAO → `setState` 立即渲染；②`unawaited(refreshLocalFromCloud())` 后台拉全量 → 事务回写 → `kLocalDataRevision.value++`；③页面监听到 revision 变化后重读本地并刷新 UI。刷新失败只 `warn`，**不清本地数据、不改 UI**。

**「本地为空」与「还没同步下来」严格区分**：四页都先判 `hasData || await isFirstFillComplete()`（后者读 `local_meta` 的 `sync.first_fill.completed`）。首次填充未完成时显示骨架 + 一行「正在连接服务器，首次同步中…」，而不是误报「你还没有缺陷单」。

**本地派生量与云端同口径**：urgency 用同一套 7/14/21 窗口公式本地复算（验证页的筛选因此从「走后端」改为本地过滤，不再产生网络往返）；缺陷分布 / 验证摘要 / 缺陷单展示名全部在本地 JOIN 或聚合出与云端**形状完全相同**的结果，页面只有一条渲染路径。

**数据库文件位置**：`getDatabasesPath()/tillroad_local.db`。Android 上即 `/data/data/com.tillroad.tillroad_app/databases/tillroad_local.db`（与其他 sqflite 应用一致，root 设备或 `adb shell run-as` 可见）。

**Windows 不支持**：`sqflite` 的桌面实现要额外的 `sqflite_common_ffi` + `sqlite3_flutter_libs`，本轮按拍板第 5 条不做，桌面端 `kLocalFirstEnabled` 保持 `false`、继续直连云端。测试能跑是因为 `sqflite_common_ffi` 只进了 `dev_dependencies`（`test/local_db_test.dart` 里通过 `LocalDb.debugFactoryOverride` 注入）。
**分页终止只能看 `items.length < limit`**：后端 `defect-tickets` 响应里没有 `total`，`mock-exams` / `review-cycles` 的 `total` 就是 `items.length`（假 total）。所以首次填充与后台刷新都用 `items.length < 200` 判断结束，且 **200 必须与服务端 `pageParams` 的上限一致**——写成 300 会被服务端夹回 50，每页都「不满」而立刻终止，数据静默缺失。
**不声明 FOREIGN KEY**：本地是「云端投影 + 待推送队列」，父子行到达顺序由同步批次决定，硬外键会让「先到子行、父行还没拉下来」的中间态直接写失败。引用完整性靠 R3 的「先父后子」拉取顺序 + 查询不用外键假设 + 队列的 `dead` 状态兜底。
**R4a 的写路径本地化**（五个写页面）：①本地状态机先校验（非法直接报错、不入队）；②乐观更新本地行（`sync_state = 2 dirty`），UI 立即反馈；③写一条 `pending_operations` 队列行；④联网后由 `PushEngine.pushPending()` 串行补推。推送错误分级：**409 → conflict**（列表角标变橙、详情页出橙色横幅「该单已被修改，请刷新后重试」，点刷新 = 丢弃本地修改 + 以云端为准）、**400 / 404 → dead**（本地规则与云端漂了或目标没了，不重试）、**网络 / 5xx → 可重试**（退避 `2^retry × 2s`，上限 5 分钟，超过 5 次转 dead）。触发时机四处：App 启动、写操作后、下拉刷新、回前台。

**一个容易踩的契约差异**：`PATCH /defect-tickets/:id/actions/:actionId` 的乐观锁作用在 **actions 表自己的 version** 上，不是缺陷单的 version；`PATCH /defect-tickets/:id/begin-verification` 的入参状态是 **ANALYZED**（云端内部自己做 ANALYZED→ACTION_DONE→V1 两跳），不是 core 纯函数里的 `ACTION_DONE`。这两处本地实现都刻意与 `core/index.mjs` 不同口径，以云端端点为准（详见设计文档 §10.7）。

---

## 部署到 Railway

后端可部署到 Railway，数据库继续使用 Neon PostgreSQL。Railway 会自动注入 `PORT`，无需手动填写，也不要启用 Railway PostgreSQL 插件。

### Railway 操作步骤

1. 在 Railway 创建 Project，选择 **Deploy from GitHub Repo**，连接本仓库。
2. Service 的启动命令使用仓库已有的 `npm start`（即 `node server/index.mjs`）。
3. 在 Service → Variables 填入下表；保存后等待 Railway 自动构建并部署。
4. 部署完成后使用 `https://tillroads-production.up.railway.app` 作为 App 的 API 地址。

| 变量 | 值 | 说明 |
|---|---|---|
| `PGHOST` | `ep-rapid-lake-azv5xiqd-pooler.c-3.ap-southeast-1.aws.neon.tech` | Neon 主机 |
| `PGUSER` | `neondb_owner` | Neon 用户 |
| `PGPASSWORD` | 在 Railway 面板粘贴 Neon 密码 | 不写入仓库或日志 |
| `PGDATABASE` | `neondb` | Neon 数据库 |
| `PGSSLMODE` | `require` | 必须启用 TLS |
| `TOKENS` | `tk_test_001:<user-1-uuid>,tk_test_002:<user-2-uuid>` | 固定邀请 Token 与 userId 映射 |
| `PORT` | Railway 自动注入 | 不手动设置 |

当前联调映射为：`tk_test_001` → `11111111-1111-4111-8111-111111111111`，`tk_test_002` → `cbd8eb64-73d9-44c3-9898-aa2e701e8d84`。Token 只通过 `Authorization: Bearer <token>` 发送，后端不会记录 Token。`/health` 和 CORS `OPTIONS` 预检公开，其余请求在配置 `TOKENS` 后必须鉴权。移动端没有浏览器 `Origin`，因此 MVP 保留 `Access-Control-Allow-Origin: *` 与 `Access-Control-Allow-Credentials: false`。

### 验证与发布 APK

```bash
curl -i https://tillroads-production.up.railway.app/health
curl -i -H "Authorization: Bearer tk_test_001" https://tillroads-production.up.railway.app/users/11111111-1111-4111-8111-111111111111/exam-profiles
curl -i https://tillroads-production.up.railway.app/users/11111111-1111-4111-8111-111111111111/exam-profiles
flutter build apk --release --dart-define=API_BASE_URL=https://tillroads-production.up.railway.app --dart-define=API_TOKEN=tk_test_001
```

不提供 `API_TOKEN` 时，App 首次启动会显示 Token 输入页，并使用 `shared_preferences` 保存在本机；编译期 Token 优先于本地保存值。APK 输出路径为 `tillroad_app/build/app/outputs/flutter-apk/app-release.apk`。部署完成后应确认 `/health` 返回 200、无 Token 返回 401、正确 Token 返回自己的数据，另一个 Token 可以返回其用户的空列表。

### ⚠️ Release APK 的联网权限与连接诊断

**`android/app/src/main/AndroidManifest.xml` 必须声明 `android.permission.INTERNET`。**
Flutter 模板只在 `src/debug/` 和 `src/profile/` 的 manifest 里加这个权限（供热重载用），`src/main/` 里没有 ——
于是 **debug 包能联网、release 包不能**。缺失时 Android 会把 DNS 解析直接判失败，报：

```
ClientException with SocketException: Failed host lookup: 'xxx' 
(OS Error: No address associated with hostname, errno = 7)
```

排查时先看合并后的清单，而不是源文件：

```powershell
Select-String -Path tillroad_app\build\app\intermediates\merged_manifest\release\processReleaseMainManifest\AndroidManifest.xml -Pattern 'uses-permission'
# 必须有 <uses-permission android:name="android.permission.INTERNET" />
```

**内建诊断入口**：首页导航栏右上角的 Wi-Fi 图标（`lib/widgets/diagnose_dialog.dart`）会打一次 `GET /health`，
把失败分档为「配置错误 / DNS 解析失败 / HTTPS 握手失败 / 请求超时 / HTTP 异常 / 网络不可达 / 通过」，
并显示实际请求 URL、状态码与原始错误。release 包没法抓 logcat 时，这个弹窗截图就能定位问题层。

**base URL 会做清洗**（`lib/config/api_config.dart` 的 `normalizeBaseUrl`）：去首尾空白、去半/全角引号、
去尾部所有斜杠、校验协议与 host。URL 拼接用 `buildApiUri`（`lib/api/api_client.dart`）折叠重复斜杠，
但**保留** base 自带路径（如 `https://h/api` → `https://h/api/users`），所以将来把后端挂到子路径也不会静默走错。


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
- ✅ **FE-03**：缺陷单列表 + 详情页：`defects_mock.dart` 8 条覆盖八态 + `defect_badges`/`defect_card`/`verification_progress` 三组共用组件 + 状态筛选条（进行中含 REOPENED）+ 详情页六栏/处理动作/三次验证进度/手画状态时间线/底部状态化操作区；`flutter analyze` 0 error，`flutter test` 5/5，Android 17 模拟器真机截图（列表页 + 详情页 + 时间线）
- ✅ **FE-03 联调**（App → HTTP → PG → 界面）：后端新增 CORS（原生 `node:http`，OPTIONS → 204，连 4xx/5xx 也带头）与 `scripts/` 四个运维脚本（migrate / verify / seed / dev-start），**未动任何业务逻辑**；前端新增 `http` 依赖（本轮唯一新依赖）+ `api_client` / `defect_api` / `api_config`，两页改为加载/成功/错误三态；Android 模拟器连 Neon 云库真跑：列表 8 条真实数据、详情 V1/V2/V3 全通过、停后端起后端后重试恢复——**错误态与重试链路均已截图验证**
- ✅ **FE-03 写操作联调**（建单 → 归因 → 标记动作 → 进入验证 → 提交验证）：后端两处查询小修（LEFT JOIN 考点/科目名、`status` 逗号分隔多值）；前端新增建单页 / 归因页 / 提交验证页 + `widgets/form_field.dart` 共用表单件，`defect_api.dart` 补齐 5 个写方法与 3 个读方法；乐观锁 `version` 全程携带、409 提示刷新、禁用语 400 内联红字、`ai_cannot_close` 403 文案；Android 17 模拟器 + Neon 真跑通「DRAFT 建单 → ANALYZED → 动作勾完 → `begin-verification` 两跳进 V1 → 提交 V1 pass 进 V2」，四处截图留证
- ✅ **FE-04**：验证任务页接真实 API + 后端建单 actions 同事务：仓储 `create` 改为「先插 `defect_tickets` 行、再逐条插 `actions` 表行」并返回带 `actions` 的 ticket（仍在同一 `withTransaction` 内，任一条失败整笔回滚），**堵上 `begin-verification` 门禁读不到动作的 `NO_ACTIONS` 缺口**；前端新增 `verification_api.dart`（`VerificationTask` / `VerificationSummary`）+ `verify_page.dart` 整页重写（三色摘要卡片可点击筛选、stage 筛选条走后端、每卡局部 loading 拉详情再 push）+ 首页「今日待验证」右侧改为真实三色计数（拿不到时回落 mock 条数并标「离线」）；2 条新 PG 集成用例（建单带 2 条动作 → 表 2 行 → 标记完成 → 进 V1）留 CI；Android 17 模拟器 + Neon 真跑 1/1/1 三色、点击筛选、进详情并提交 V1 pass，截图四张
- ✅ **FE-07**：首页看板完整联调：后端新增聚合端点 `GET /users/:userId/defect-stats`（status 八态计数 + error_layer 分组，**只算未关闭**，八态白名单预填 0 防契约漂移）；前端首页整份重写——`Future.wait` 三路并发 + 逐卡片骨架屏（`_SkeletonBlock`/`_Bone`/`_Pulse`）+ 逐卡片独立降级（每路各自 try/catch，一路失败不阻塞其余）+ `AnimatedSwitcher` 淡入 + `main()` 里 `GET /health` 预热；快捷入口四个 onTap 全接（建题 push 建单页 / 转缺陷单切 Tab / 模考与复盘弹提示）；`kApiTimeout` 10s→15s；Android 17 冷启动实测 **冷 ≈4.2s 到首帧完整内容**，骨架屏/加载完成/离线兜底三张截图，四入口逐个点验
- ✅ **FE-05**：限时模考页（组卷 → 答题 → 交卷 → 报告 → V3 引导）：前端新增 `api/mock_api.dart`（13 个数据类 + 5 方法）与三个新页 + `mock_page.dart` 整份重写为「我的模考」列表，首页「开始模考」快捷入口接上；答题页用**绝对截止时间**+`Timer.periodic(1s)` 避免 tick 累积误差，剩余 ≤60s 变红闪烁、归零自动交卷；报告页四块卡（总分/模块正确率横条/平均用时/稳定性与缺陷重复率）+ V3 候选区（点某条先拉缺陷详情再复用 `DefectVerifyPage`，V3 验证方式由后端白名单限定为「限时模考」）；修掉两个真机才暴露的导航栏遮挡 bug（`CupertinoPageScaffold` 仅在半透明时不给 child 加 padding）；Android 17 模拟器 + Neon 真跑通全链路（含 1 分钟限时的自动交卷），11 张截图留证
- ✅ **FE-06**：复盘页（日/周/月生成与查看 + 六项 metrics）：前端新增 `api/review_api.dart`（7 个数据类 + `ReviewCycleType` 枚举 + 5 方法）与两个新页 + `review_page.dart` 从空状态重写为列表，首页「复盘」快捷入口改为切 Tab 4；列表页一次拉全量再本地按 chip 过滤（切 chip 不等网络 + 能区分两种空态），生成走 `CupertinoActionSheet` 且不传 `period` 让后端算当前周期，同周期重复生成把 `409 ALREADY_EXISTS` 的 `existing_id` 接成「查看已有」直达；详情页六块卡全部纯 Widget 手绘（七态堆叠条 / 横条 / 双竖柱 / 8px 进度条），底部「标记已读 → 删除复盘」状态化操作区；**顺手修掉 BE-05 遗留的报告 `title` 恒 null**（`reportGenerator` 改读 `q.knowledge_node_title ?? q.title`，新增 `T6b` 单测）与 `EmptyState` 蓝底蓝字按钮；Android 17 模拟器 + Neon 真跑通「生成 → 列表 → 详情 → 标记已读 → 删除 → 空态」全链路及 409 场景，10 张截图留证
- ⏳ **下一批**：FE-02 建题/导入页 → FE-11 审核七态 UI → BE-07 缺陷分布看板 / BE-08 同步服务 → 补 Flutter 工具链后移植 Dart / 接入 NestJS（FE-06 完成后前端 MVP 页面已全部到位：FE-01/03/04/05/06/07）
- ✅ **FE 网络修复**：release APK 连不上 Railway（`Failed host lookup / errno 7`）→ 根因是 `src/main/AndroidManifest.xml` 缺 `INTERNET` 权限（模板只在 debug/profile 里声明）；一并做 base URL 清洗（`normalizeBaseUrl`，剥引号/尾斜杠/校协议）+ 安全拼接（`buildApiUri`，不用 `Uri.resolve` 以保留 base 子路径）+ 首页导航栏「连接诊断」入口（`diagnose()` 分七档）；release APK 51,884,906 B，真机验证缺陷分布拿到真实数据、诊断弹窗显示「通过 / 1449ms / 200」；截图 `fe-net-home.png`、`fe-net-diagnose.png`
- ✅ **运行日志导出**：外部测试用户拿不到 adb logcat，所以 App 自带「可导出、已脱敏」日志：`lib/logging/app_logger.dart`（500 条环形缓冲 + **写缓冲区之前**脱敏）+ `log_file_writer.dart`（按天滚动 / 保留 3 天 / 总量超 5MB 删最旧）+ `log_export.dart`（内存 + 近 3 天文件 + 设备头 → 单个 `.txt`）+ `nav_observer.dart`；首页导航栏文档图标 → `CupertinoActionSheet`（导出 / 清空 / 取消）→ 确认弹窗 → `share_plus` 系统分享面板；`main.dart` 接 `FlutterError.onError` + `PlatformDispatcher.onError`，`api_client._send()` 一处覆盖全部端点；唯一新增依赖 `share_plus`；真机验证联网成功日志、断网 error 日志（`SocketException ... errno = 7`）与导出文件（无 `tk_test_`、无完整 UUID）；截图 `fe-log-entry.png`、`fe-log-share.png`
- ✅ **FE-UI 重构**：底部 Tab 从 5 个收敛到 **3 个**（首页 / 缺陷单 / 我的），验证·模考·复盘三页**文件全部保留**、降为 `appRoute()` push 的二级页；新建 `lib/pages/profile_page.dart`（账户卡片 `maskUuid` 脱敏 ID + 数据概览四格 + 功能四入口）与 `lib/pages/settings_page.dart`（连接与诊断 / 日志 / 账户 / 危险操作 / 关于 五分区）；首页 trailing 由「诊断 + 日志」两图标改为单个齿轮 → 设置页；所有旧 `_switchTab(2/3/4)` 写死索引改为按类型 push（否则索引 2 现在是「我的」，点「今日待验证」会静默跳到错误分区）；数据层 / `api_client.dart` / 后端**零改动、零新依赖**；`flutter analyze` 30 info / **0 error / 0 warning**，`flutter test` **15/15**；Android 17 真机 7 张截图（含断网降级态），数据概览 9 / 1 / 11% / 进行中 3 与生产接口返回完全吻合
- ✅ **本地优先 R1**：建成本地 SQLite 库地基（10 表 + 22 索引 + 5 个 DAO 文件 + `kLocalFirstEnabled` 开关），`kLocalFirstEnabled` 默认 `false`、App 行为零变化；`sqflite` + `path` 进运行时依赖，`sqflite_common_ffi` 仅作 dev；`flutter test` **42/42**、`flutter analyze` 0 error / 32 info；Android 真机 `tillroad_local.db` 192512 B、`user_version=1`、10 表 22 索引全部实测
- ✅ **本地优先 R2**：四页（首页 / 缺陷单 / 验证 / 我的）改为「先读本地 → 后台刷新 → 事务回写」，`kLocalFirstEnabled` 翻为 `true`；新增 `verify_window.dart`（后端 7/14/21 公式 Dart 移植）+ `first_fill.dart`（首次全量填充，父→子，`items.length < 200` 判定分页）+ `local_queries.dart`（本地聚合出与云端同形状的数据）+ `local_refresh.dart`（后台对账，四页并发合流）；修掉两个真机才暴露的真 bug：①子表回写复用整表 `deleteSynced` 把别的缺陷单的 actions/verifications 删光（改 `deleteSyncedWhere` 按 `defect_ticket_local_id` 限定）②首次填充中首屏误报「还没有设置考试目标」（补 `_syncPending` + 「正在连接服务器，首次同步中…」）；`flutter test` **71/71**，Android 本地行数与云端逐项一致（9 / 6 / 11），冷启动到首帧完整内容 **约 4s**（改造前需等 Neon 10–30s）
- ✅ **本地优先 R4a**：写操作也本地化——新增 `local_state_machine.dart`（`core/index.mjs` 纯函数 Dart 移植，24 条用例逐条对齐）+ `write_queue.dart`（五类写操作「本地校验 → 乐观写库 → 入队」）+ `push_engine.dart`（队列补推、409 → conflict / 400·404 → dead / 网络 → 退避重试、四处触发：启动·写后·下拉·回前台）；五个写页面改为本地优先（`kLocalFirstEnabled=false` 时逻辑完全不变），列表卡片挂「待同步」角标，详情页冲突时出橙色横幅「该单已被修改，请刷新后重试」；本轮**跳过 R3**（后端无 `updated_since`）；真机抓到并修掉 **5 个**只有真机才能暴露的缺陷：①离线建单被前置网络请求挡住 ②启动时不补推导致队列永远推不出去 ③`begin-verification` 入参状态与 core 不同（云端要 `ANALYZED`）④标记动作的 base_version 该用**动作行自己的 version** 而非缺陷单的 ⑤Dart 字符串插值漏花括号致冲突消解静默失败；`flutter test` **106/106**、`flutter analyze` 0 error / 51 info；Android 真机 E1 离线建单→自动推送（无重复单）/ E2 断网链（标记两动作 + 进入验证 → 云端 `V1 version=3`）/ E4 冲突横幅与消解 / E5 门禁拦截 / E7 死信（400 与 404 均转 `status=4`），5 张截图留证
- ⏳ **仍待补的后端缺口**：①新增 `defect_events` 表以支持状态时间线完整历史（当前时间线只有「创建 + 当前状态」两个节点）；②CORS 的 `*` 生产前收窄为白名单；③登录体系（当前是固定 Bearer Token 映射，无注册/改密/多设备）；④前端建单后逐条 `POST /:id/actions` 的补丁**已可移除**（后端已改同事务），保留只为向后兼容；⑤Neon 冷启动时三路并发建 TLS 会偶发 `Connection closed before full header was received`（单路重试即恢复，可在 ApiClient 加一次自动重试）；⑥本地优先 R3 的增量对账尚未实现（后端需加 `updated_since` 或变更日志）；⑦R4a 的冲突只做「丢弃本地 + 以云端为准」，字段级自动仲裁与写队列的删除操作未做
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
