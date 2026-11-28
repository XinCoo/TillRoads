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
├── .github/workflows/schema-ci.yml  # schema 幂等/可逆 + Node 单测 + PG 集成 + Flutter analyze/test
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

- **CI**：由 GitHub Actions 的 PG15 service 容器真跑（`psql -v ON_ERROR_STOP=1 -f migrations/0001_init_up.sql`）。workflow 现有三个 job：`schema`（幂等/可逆）、`node-tests`（`npm ci && npm test`，用 `grep -q 'skipped 0'` 防「全 skip 也算绿」）、`flutter-tests`（`flutter analyze --no-fatal-infos` + `flutter test`，**钉住 Flutter 3.50.0**）；触发路径含 `tillroad_app/**`。
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
| `POST /questions/import` | **BE-02 / m30197** 题库导入（JSON + base64；四阶段：抽取→切题→去重→入库）→ `200 {imported, duplicates, errors, stats, subject_matched, node_created}`。`subject_mode: from_file` 时按每题 `subject` 匹配科目（精确→包含，**不自动建科目**）、按 `node` 逐级匹配考点（缺级**自动创建**）；`uniform` 时忽略文件字段走请求里的 `subject_id` |
| `POST /questions-import` | 上一行的路径别名 |
| `POST /questions` | **FE-02** 手动建题 → `201`（`source` 固定 `manual`，归属只认 token；选项归一成 `[{key,text}]`；同题干同 owner → `409 DUPLICATE_QUESTION`） |
| `GET /questions/:id` | **FE-02** 取单题详情（含 `answer` / `analysis` / `version`）；别人的私有题 → `404` |
| `PATCH /questions/:id` | **FE-02** 编辑（`base_version` 必填；改题干自动重算 hash 并重新查重；空 patch → `400 empty_patch`） |
| `DELETE /questions/:id` | **FE-02** 软删（`base_version` 必填） |
| `PATCH /questions/batch` | **m30197** 批量改归属：body `{ids[], subject_id?, knowledge_node_id?}`（`knowledge_node_id: null` = 清空考点）；只改自己的题，公共/他人题静默跳过 → `200 {updated, requested, skipped}`；两个字段都不给 → `400 NOTHING_TO_UPDATE` |
| `GET /import-batches` | **m31124** 导入批次列表（`?limit=&offset=`，按 `created_at DESC`）→ `200 {items:[{id, filename, question_count, created_at}], total, limit, offset}`。`user_id` 从 token 取，不接受 query 传 |
| `DELETE /questions/batch` | **m31124** 整批软删：body `{batch_id}` → `200 {deleted, requested, skipped, batch_id}`（`requested` = 删前该批还剩多少道，**必须在删除前统计**）。同一端点仍接受 `{ids[]}` 走原按 id 批量删；两者都不给 → `400 EMPTY_IDS`，`batch_id` 非字符串/空串 → `400 INVALID_BATCH_ID` |
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

### 题库可见性与多用户隔离（m17431：`owner_user_id`）

`questions` 表原先是全局的：`content_hash` 全局查重，且组卷抽题不区分人。结果是「题库变成第一个人的题库」，A 导入的题 B 也能看到、也能被 B 的模考抽到。

**本轮的最小迁移**（`migrations/0002_questions_owner.sql`，幂等；不改 `schema.sql`、不改 0001）：

```sql
ALTER TABLE questions
  ADD COLUMN IF NOT EXISTS owner_user_id uuid REFERENCES users(id);

CREATE INDEX IF NOT EXISTS idx_q_owner
  ON questions(owner_user_id)
  WHERE owner_user_id IS NOT NULL;
```

回滚脚本 `migrations/0002_questions_owner_down.sql`（`DROP INDEX IF EXISTS` + `DROP COLUMN IF EXISTS`）。

**口径（三个地方必须一致）**：

| 场景 | 口径 |
|---|---|
| 查重（单题 `questions.create`） | `content_hash = $1 AND owner_user_id = $2`（用户题）/ `owner_user_id IS NULL`（公共题） |
| 查重（批量 `import/dedupe.mjs`） | `content_hash = ANY($1::text[]) AND owner_user_id = $2` |
| 组卷抽题（`mock_exams.create`） | `(owner_user_id IS NULL OR owner_user_id = $1)` —— 公共题 + 自己的题，别人的抽不到 |
| 题库列表（`GET /questions`） | 同上，只返回「公共题 + 自己的题」 |

**归属只认 token**：`questions_import` 路由从 `ctx.authUserId` 取 userId 传给仓储，**不信任请求体里的 `user_id`**；`questions` 仓储的 `UPDATE_COLUMNS` 排除了 `owner_user_id`，客户端 PATCH 改不了归属。

**新增只读端点 `GET /questions`**（后端原先**没有**题库列表端点）：`?subject_id=&knowledge_node_id=&limit=&offset=`，返回 `{items, total, limit, offset}`；items **不含 `answer` / `analysis`**（列表页不泄露答案）。另有别名 `GET /subjects/:id/questions`。默认排序 `created_at DESC, id DESC`（刚导入的排最前）。

**前端入口**（「我的 → 题库管理」）：`lib/pages/question_bank_page.dart`（列表，按科目分组）与 `lib/pages/question_import_page.dart`（选文件 → 选科目 → 选考点（可选）→ 上传 → 结果），新增依赖 `file_picker ^13.4.1`。

### 题目选择器（m21779：`GET /questions` 的 `q` / `knowledge_node_id`）

提交验证时「关联题目」原来是手输 UUID（`如：f47ac10b-…`），现实中没人能背出 UUID，等于该字段从未被用过。本轮把它换成选择器。

**后端只加两个查询参数**（不改返回结构、`items` 仍不含 `answer` / `analysis`）：

| 参数 | 语义 | 实现 |
|---|---|---|
| `q` | 题干关键字 | `stem ILIKE $n ESCAPE '\'`，参数是 `%关键字%` |
| `knowledge_node_id` | 考点过滤 | `knowledge_node_id = $n` |

三个容易踩的点：

1. **`%` `_` `\` 必须转义**（`escapeLikePattern()`）：不转义时搜「100%」会变成「任意字符串」、搜「a_b」会匹配「axb」。配 `ESCAPE '\'` 显式声明，不依赖默认行为。
2. **空白关键字当没传**：`rawQ.trim().length > 0 ? rawQ.trim() : null`，否则 `ILIKE '%%'` 会多一次全表扫描。
3. **顺手修了一个既有 bug**：`knowledgeNodeId` 原来从 query 读出来却**没传给仓储**，考点过滤实际一直失效。

**前端 `lib/pages/question_picker_page.dart`**（新建）：

| 能力 | 做法 |
|---|---|
| 搜索 | `CupertinoSearchTextField` + `Timer(300ms)` 防抖，不用 rxdart |
| 分页 | 首屏 `limit=50`，`ScrollController` 剩余 < 400px 触发下一页；**`_hasMore` 只看服务器返回的原始条数**（` >= 50`），不看前端过滤后的条数，否则一过滤就误判没更多 |
| 去重 | 翻页期间若有新题入库，同一条会出现在两页 → 追加时按 `id` 去重 |
| 筛选 | 来源（全部/我导入的/公共题，本地 `isMine`）/ 题型（本地 `type`）/ 导入时间（本地 `created_at`；**`createdAt == null` 不匹配任何时间段**，避免时间不明的旧题混进「最近 7 天」） |
| 空态 | 「没有匹配的题目，换个关键词试试」+「清空搜索与筛选」 |
| 进度 | 搜索/翻页时列表顶部 3px 色条（`ColoredBox`，**不能用 `LinearProgressIndicator`——那是 Material**） |

返回 `PickedQuestion{id, stem}`；右上「不关联」直接 `pop()`（无返回值 = 清空）。`defect_verify_page.dart` 的字段由 `FormTextField` 换成 `_QuestionSelector`：未选显示「选择题目（可选）」，已选显示题干前 30 字（`shortStem`）+「更换」「不关联」。提交仍走原 `_questionId.text`，提交路径没动。

**集成测试**（`m21780：GET /questions 支持 q 与 knowledge_node_id 过滤`）有一条通用教训：**别写绝对条数断言**。该文件前 5 个用例已把 `sample-01-markdown.md` 的 12 道题导入同一科目，其中就有含「马克思主义」的题，断言「q 应该 3 条」实测 4 条；正确写法是先取基线、再断言「等于基线里含关键字的条数」。同理断言「没有泄漏」时要把公共资源排除在比较集合外，并加基数断言防止空集合假通过。

### 分发前四个阻塞项修复与考试配置（m18680）

| 问题 | 真因（实测） | 修法 |
|---|---|---|
| 「判重 50 但云端一条没有」 | **不是 dedupe bug**：50 题首次导入在 Neon 上耗时 **20.3s**，超过前端全局 15s 超时 → 客户端报失败、用户重试 → 第二次因已入库而判重 50；且用户当时用 A 的 token 看 B 导入的题，本来就看不到 | ①`questions_import` 加 4 处 `[IMPORT]` 日志（切题数 / 查重命中 / 每 10 题进度 / 完成汇总，不改事务语义）②导入页单独用 `ApiClient(timeout: 60s)`，全局 `kApiTimeout` 仍 15s③`GET /questions` 默认 `created_at DESC`，刚导入的排最前 |
| 「清除所有数据」只清本地 | 名字与行为不符：云端一行未动，重装/换设备后数据全回来 | 后端新增 `DELETE /users/:userId/data`（九类按子→父软删，**公共题 `owner_user_id IS NULL` 保留**）；前端拆成「清除本地缓存」与「删除我的所有数据」两个入口，后者要手打「确认删除」四字，云端失败时**不清本地**并如实报告 |
| 首页「今日待验证」残留 mock 卡 | `TaskListCard(tasks: _tasks.isEmpty ? _snapshot.tasks : _tasks)` 在本地为空时回落 3 条 mock（`dt-v1-001` 等非法 id），点击请求 500 | 三态分离：mock 模式 / 真实列表 / 同步中转圈 / 真空态；列表不再回落 mock；`_onTapTask` 先校验 UUID，非法 id 不请求 |
| 文件选择器选不到 `.md` | `kSupportedExtensions` 缺 `markdown`，且 `FileType.custom` 在部分系统上过滤过严 | 扩展名补 `markdown`（与后端 `extract.mjs` 的 `EXT_KINDS` 一致）+ 「选不到文件？用「所有文件」打开」兜底（`FileType.any` 后自校验扩展名） |

**考试配置四页面**（「我的 → 考试配置」）：`exam_config_page.dart`（目标列表）→ `exam_profile_create_page.dart`（新建目标，**`civil_service` 自动预置 6 个科目**）→ `subject_config_page.dart`（科目增删）→ `knowledge_node_page.dart`（考点树，支持父子与频率/权重）。写操作裸用 `ApiClient().post/patch/delete`，`DELETE` 的 `version` 走 **body**（`readBaseVersion(body)` 不读 query）；首页「还没有设置考试目标」的「去设置」按钮与导入页空档案文案均指向该页。
### 建题 / 编辑 / 删除题目（FE-02）

题库终于不只是「只读的导入产物」——本轮把题目从「只能导入」变成「可以手写、可以改、可以删」。

**范围（用户拍板）**：

| 决策 | 结论 | 原因 |
|---|---|---|
| 拍照 OCR | **本轮不做** | 后端没有 provider / 密钥基建（`server/import/extract.mjs` 对图片直接 422 `UNSUPPORTED_IMAGE`）。真 OCR 需先做 BYOK 服务端密钥管理（encrypted_key / DEK / KMS）+ vision adapter + 图像存储 + 置信度阈值。拍照入口本轮完全不出现 |
| 后端写端点 | **新增**（不改 schema） | 仓储层 `create` / `update` / `archive` 早就写好了，缺的只是路由层三个端点 + 归属校验 |
| 导入进度 | **客户端进度 + 预检提示** | 不建 `import_jobs` 表；后端是一次性同步接口，没有 job id 可查，所以进度只能在客户端分段显示 |

**后端新增三个端点**（`server/routes/questions.mjs`）：

| 方法 & 路径 | 说明 |
|---|---|
| `POST /questions` | 手动建题 → `201`。`source` 固定 `manual`、`owner_user_id` **只认 token**（不收请求体里的 `user_id`）；`content_hash` 由服务端算；选项三种写法都归一成 `[{key,text}]` |
| `GET /questions/:id` | 取单题详情（**含** `answer` / `analysis` / `version`，与列表口径不同）；别人的私有题 → `404`（刻意不用 403，避免枚举 id） |
| `PATCH /questions/:id` | 编辑（`base_version` 必填）；题干/选项变动时**自动重算 hash** 并按 owner 分域重新查重；空 patch → `400 empty_patch` |
| `DELETE /questions/:id` | 软删（`base_version` 必填）；删后同 hash 可重建 |

错误码：`MISSING_QUESTION_STEM` / `MISSING_QUESTION_TYPE` / `INVALID_QUESTION_TYPE` / `INVALID_DIFFICULTY` / `INVALID_OPTIONS` / `INVALID_TAGS` / `empty_patch`；查重冲突 `409 DUPLICATE_QUESTION`（body 带 `current.id`）；版本冲突 `409 conflict`（body 带 `current` / `resolution: 'client_merge'`）。

**前端新增** `lib/pages/question_edit_page.dart`（建题与编辑**共用一页**）：

- 字段：题型（9 种 chip）、题干、选项（逐条编辑，标号 A/B/C 由前端给出）、答案、解析、公式（LaTeX）、难度、标签、是否主观题、所属科目、关联考点。
- 为什么选项不塞进一个 TextField：后端 `questions.options` 是 jsonb、统一 `[{key,text}]`；若导入路径发字符串数组、手写路径发对象数组，同一道题两种形状，答案解析要写两套。
- 错误映射：`DUPLICATE_QUESTION` → 题干下方红字「题库里已有同样的题干」；`conflict` → 顶部条「这道题在你编辑期间被改过（版本冲突）。请关闭本页重新打开」。

**题库页接入口**（`lib/pages/question_bank_page.dart`）：

| 位置 | 行为 |
|---|---|
| 右上角 | 「建题」+「导入」两个按钮 |
| 点卡片 | 先 `GET /questions/:id` 拉详情（列表口径 `BankQuestion` 不带 `answer` / `version`）→ 进编辑页 |
| 卡片右上「⋯」 | 「编辑」/「删除」动作表；删除前先拉详情拿 `version`，避免拿旧 version 被判 409 |
| 删除别人/公共题 | 后端回 `404` → 前端如实说「只能删除自己建的题。公共题和别人的题不能删。」 |

**导入页三态进度**（`lib/pages/question_import_page.dart`）：

| 阶段 | 文案 | 含义 |
|---|---|---|
| `encoding` | 正在读取并编码文件… | 本地读字节 + base64 编码 |
| `processing` | 服务端正在解析与入库… | 后端抽取 → 切题 → 判重 → 入库 |
| 完成 | 结果页 | 新增 / 判重 / 失败三档 |

另有**大文件预检**：选完文件若 > 2MB，立即提示「导入会明显变慢（base64 上传体积约多三成），建议先按题号拆成几份再导」，不等上传完才看到 413；以及**超时文案**：超时不再说「失败请重试」，而是「服务端可能已经写入了部分或全部题目，请先到题库页确认」——这是 m18680 那个「判重 50 但云端没有」误解的收尾。

### 练习模式 R1（抽题 → 答题 → 客户端判分 → 错题去归因）

练习不限时、不生成报告，是「模考」之外的轻量入口：抽一批题、当场作答、错了直接转成缺陷单。

**迁移**（`migrations/0003_practice.sql` + `0003_practice_down.sql`，**不改 `schema.sql`**）：`practice_sessions`（id / user_id / subject_id / knowledge_node_id / source / total / correct / wrong / created_at / deleted_at）+ `practice_answers`（session_id `ON DELETE CASCADE` / question_id / user_answer / is_correct / duration_ms）；索引 `idx_ps_user(user_id, created_at DESC)`、`idx_pa_session(session_id)`。

**四个后端端点**（`server/routes/practice.mjs` + `server/repositories/practice_sessions.mjs`）：

| 方法 & 路径 | 说明 |
|---|---|
| `GET /questions/practice` | 随机抽题。`source` = `mine`（只抽自己的）/ `public`（只抽公共题）/ `all`；`count` 默认 10、上限 50。**题量不足不报错**，返回 200 且 `available` 给出真实可抽数量 |
| `POST /practice-sessions` | 提交练习。body 含 `answers[{question_id, user_answer, is_correct, duration_ms}]`；返回 `session_id / total / correct / wrong / unjudged / accuracy` |
| `GET /practice-sessions` | 练习历史（只返回 token 映射的 userId 自己的） |
| `GET /practice-sessions/:id` | 单次详情（每题题干 / 你的答案 / 正确答案 / 对错）；**别人的会话 → 404**（不返回 403，避免枚举 id） |

**答案安全底线（在仓储层保证，不靠路由层过滤）**：抽题 SQL 里答案列写成 `CASE WHEN owner_user_id = $n THEN answer ELSE NULL END`，所以**公共题的 answer 与 analysis 永远是 `null`**；客户端拿到 `has_answer=false` 就显示「该题不提供答案，请自评」，让用户自己点「我答对了 / 我答错了」。

**前端四页**：

| 页面 | 内容 |
|---|---|
| `practice_config_page.dart` | 选科目 / 考点（可选）/ 来源 / 题量（10·20·30·50）。题量不足时弹「该范围只有 N 道题，是否按 N 道开始？」 |
| `practice_answering_page.dart` | 顶部「第 X/Y 题」，底部「上一题 / 下一题 / 提交练习」。不限时；有标准答案自动判分，公共题走自评块 |
| `practice_result_page.dart` | 正确率大字 + 四格（答对 / 答错 / 未判定 / 总题数）；错题卡带「去归因」→ 建单页并预填错因「练习中未掌握」与题目 id；对题默认折叠 |
| `practice_history_page.dart` | 「我的 → 练习记录」：列表（时间 / 题数 / 正确率）+ 详情（逐题对错）+「重做这次练习」 |

**入口**：首页快捷入口新增「开始练习」；题库页导航栏新增「练习」；「我的」功能列表新增「练习记录」。

### 练习模式 R2（掌握度标记 + 未掌握进缺陷单）

R1 的「对题只折叠展示」不够用：用户一周下来反馈「对题想标记掌握状态」。R2 在**不新建任何同步机制**的前提下补上掌握度，并把「没掌握」自动接进缺陷单闭环。

**迁移**（`migrations/0004_question_mastery.sql` + `0004_question_mastery_down.sql`，**不改 `schema.sql`**）：`question_mastery`（id / `user_id` FK users / `question_id` FK questions / `mastered` boolean NOT NULL / `updated_at` / `UNIQUE(user_id, question_id)`）+ 索引 `idx_qm_user`、`idx_qm_question`。

> **三态语义**：表里**没有这一行** = 从没标记过（未标记），与 `mastered = false`（明确标为未掌握）**不是一回事**。所以 `mastered` 字段在 API 里是可空布尔（`true` / `false` / `null`），筛选时 `mastered=false` 只回显真正标过「未掌握」的题。

**后端端点**：

| 方法 & 路径 | 说明 |
|---|---|
| `PATCH /questions/:id/mastery` | body `{mastered}` → upsert（`ON CONFLICT (user_id, question_id) DO UPDATE`）。**只能标记自己的题**：公共题 / 别人的题 → `403 FORBIDDEN_MASTERY`；未带 Token → 401；`mastered` 非布尔 → 400 `INVALID_MASTERY` |
| `GET /questions?mastered=true\|false` | 按掌握状态过滤（走 `EXISTS` 子句，避免 JOIN 产生重复行） |

**前端两处**：

- **结果页对题**：展开「答对的题」后，每道**自己的**题右侧有「已掌握 / 未掌握」两个按钮（公共题不显示 —— 后端会 403）。点「已掌握」→ 立即变绿「✓ 已掌握」；点「未掌握」→ 先弹确认「将创建一条缺陷单，并标记该题未掌握」→ 确认后 PATCH 标记 + 自动建一条缺陷单（`question_id` = 当前题，`error_layer` 取六层里最接近的「识别」，`error_cause` 预填「练习中未掌握，需复习」）→ 按钮变橙「待复习」。顶部还有「全部标记已掌握」批量按钮。
- **题库页**：列表顶部新增「全部 / 已掌握 / 未掌握」筛选 chip（走后端过滤）；每张卡片右上角显示掌握度徽标（已掌握绿 / 未掌握橙，未标记不显示）。

### 练习模式 R3（已掌握题移除 + 恢复 + 题库管理页）

R2 的掌握度标记只能「标」，不能「不看」——用户一周下来反馈「题库里已掌握的题我不想再看到」。R3 补上移除与恢复。

**Q1「移除」是软删还是隐藏？→ 软删（`deleted_at`）+ 管理页可恢复。** 软删让模考组卷也抽不到（组卷 SQL 恒带 `deleted_at IS NULL`），隐藏只影响列表，两者语义不同。
**Q2 公共题能不能被移除？→ 不能，只能隐藏。** 公共题不属于任何用户，删它等于删别人的东西；所以删公共题返回 `403 FORBIDDEN_DELETE`，另开「只对我隐藏」。
**Q3 已掌握但未移除的题，模考组卷还抽不抽？→ 抽。** 掌握度是主观标记，模考需要覆盖真实范围。

**迁移**（`migrations/0005_question_hidden.sql` + `0005_question_hidden_down.sql`，**不改 `schema.sql`**）：`question_hidden`（id / `user_id` FK users / `question_id` FK questions / `hidden_at` / `UNIQUE(user_id, question_id)`）+ 索引 `idx_qh_user`、`idx_qh_question`。与 `question_mastery` 分工独立：标记已掌握不隐藏，隐藏不改掌握度。

**后端端点**：

| 方法 & 路径 | 说明 |
|---|---|
| `DELETE /questions/:id` | 软删自己的题（`base_version` 必填）。公共题 → `403 FORBIDDEN_DELETE`；别人的私有题 → 404（避免枚举 id） |
| `PATCH /questions/:id/restore` | 恢复软删的题。**刻意不要求 `base_version`** —— 恢复不冲突，带基线号反而让人困惑；题本来就没被移除 → 400 `not_deleted` |
| `DELETE /questions/batch` | body `{ids[]}` → `{deleted, requested, skipped}`。**公共题 / 别人的题被静默跳过**（SQL 的 `owner_user_id` 条件），前端必须把 `skipped` 告诉用户 |
| `PATCH /questions/batch/restore` | body `{ids[]}` → `{restored, requested, skipped}` |
| `PATCH /questions/:id/hide` | body `{hidden}` → upsert 到 `question_hidden`。公共题与自己的题都能隐藏 |
| `GET /questions/deleted` | 列**自己**的软删题（`owner_user_id = 当前用户`），可恢复 |

**路由匹配顺序（有坑）**：`PATCH /questions/batch/restore` 必须**排在** `PATCH /questions/:id/restore` 之前判定，否则 `seg[2] === 'restore'` 会把 `'batch'` 当 uuid 查 → PG `22P02` → 被 `httpError` 吞成 `{error:'internal'}`。

**隐藏的生效面**：隐藏过滤写在 `questions.listVisible` 与 `practice_sessions.pickQuestions` **两处**（练习抽题有自己的 SQL，不走 `listVisible`）。所以被隐藏的公共题既不在题库列表里，也不会被练习抽到。

**前端**：`tillroad_app/lib/pages/question_manage_page.dart`（约 700 行）——「我的 → 题库管理」进入，四个筛选（全部 / 已掌握 / 未掌握 / 已删除），多选后批量移除 / 批量恢复，单题也能单独移除 / 恢复。批量操作的结果**如实展示 `skipped`**（「其中 N 道没移除（公共题或别人的题不属于你）」）。原题库列表页（导入 / 建题 / 练习入口）在管理页右上角「浏览」。

### 导入批次（m31124：`batch_id` + 批次筛选 + 整批删除）

用户反馈「导入多次后题库很乱，不知道哪些题是哪次导的，删错题要逐题勾」。本轮给每次导入一个批次号，并支持按批次筛选 + 一键删整批。

**迁移 `migrations/0007_import_batch.sql`（+down）**（任务书要求 `0006`，但 `0006` 已被 `0006_exam_custom_defect_questions.sql` 占用）：

| 变更 | 说明 |
|---|---|
| `questions` 加 `batch_id uuid` / `import_filename text` / `imported_at timestamptz` | 三列均可空 —— 手动建题、历史数据、seed 都没有批次。**刻意不建 `batch_id` 外键**：批次是账本、题是数据，生命周期不该强绑 |
| `CREATE INDEX idx_q_batch ON questions(batch_id) WHERE batch_id IS NOT NULL` | 部分索引，主路径（按批次查题）直接走索引不必 JOIN |
| `CREATE TABLE import_batches` | `id / user_id FK / filename / question_count int / created_at` + `idx_ib_user_time(user_id, created_at DESC)`；存 `question_count` 是为了下拉不用每页 `count(*)` |

**双写时序**：批次行必须先 INSERT（`question_count=0` 占位）→ 题目逐条带 `batch_id` 写入 → 全部插完后 `UPDATE question_count = imported.length`。三件事在**同一个 `withTransaction`** 里，失败整笔回滚，不会留下空批次。回填失败只 `console.warn` 不回滚（题已入库才是主要结果）。

**`GET /questions` 的 `batch_id` 查询参数**：`listVisible` 里 `if (batchId) where.push('batch_id = $n')` —— `batch_id IS NULL` 的题天然不命中任何具体批次，正好满足「手动建的题只在「全部批次」下出现」。

**`DELETE /questions/batch` 的分流**：同一个端点认两种 body。有 `batch_id` 时走整批（`countByBatch` 先数、`archiveByBatch` 后删 —— **顺序不能反**，删完再数恒为 0）；没有才走原来的 `{ids[]}`。两者都没有 → `400 EMPTY_IDS`。

**前端**：`tillroad_app/lib/pages/question_manage_page.dart` 在筛选行下面加一行「批次下拉 + 删除整批」；`tillroad_app/lib/api/question_api.dart` 新增 `ImportBatch` 模型（`label` getter 拼「文件名（N 题）· 相对时间」）、`fetchImportBatches()`、`deleteQuestionsByBatch()`。批次行只在「全部 / 已掌握 / 未掌握」三档显示 —— 已删除档走 `/questions/deleted`、已隐藏档走本机快照，两者都不带批次语义。批次列表拉失败只 `debugPrint`，不让它拖垮题目列表。

**口径提醒**：`import_batches.question_count` 是「那次导入真正入库的题数」（历史值），不是「现在还剩多少道」；确认弹窗与结果提示都以 `DELETE` 返回的 `requested` / `deleted` 为准。

### 题库多条件组合筛选（m31635：科目 + 题型 + 掌握状态 + 批次）

上一轮的批次筛选只能「切一个条件」，而用户实际是在「行测里、选择题、我还没掌握的、这批导进来的」四个维度上同时收窄。本轮把筛选器从单选改成**多维度叠加（AND）**。

**`GET /questions` 的查询参数（全部可选，AND 关系）**：

| 参数 | 说明 |
|---|---|
| `subject_id` | 科目（已有参数，本轮确认接通） |
| `knowledge_node_id` | 考点（已有参数） |
| `type` | **新增**，题型，多值用逗号分隔如 `choice,multi`。后端按 `QUESTION_TYPES` 过滤非法值后去重，SQL 用 `type = ANY($n::text[])`（数组参数一次比较，不做字符串拼接） |
| `mastery` | **新增**，三态 `mastered` / `unmastered` / `unmarked`。非法值静默忽略（不让脏参数把整页打成错误页） |
| `batch_id` | 导入批次（m31124 已有） |

**三态掌握度的 SQL 差别（关键）**：`mastered` / `unmastered` 用 `EXISTS (… AND qm.mastered = true/false)`；`unmarked` 必须用 **`NOT EXISTS (…)` 整个子查询取反** —— 写成 `NOT EXISTS (… AND mastered = false)` 会把「已掌握」也算成「未标记」（因为已掌握的行存在但 `mastered` 不为 false）。`question_mastery` 的三态由「行存在与否」承载：没有行 = 未标记。

**兼容旧参数**：`mastered=true|false` 仍然有效，`masteryState` 优先（它多一个 `unmarked`，旧参数表达不了）。参数全空时行为与改造前完全一致。

**前端**（`tillroad_app/lib/pages/question_manage_page.dart`）：

- 五个档位（全部 / 已掌握 / 未掌握 / 已删除 / 已隐藏）保留为「掌握状态」维度，仍走 `_filter`；科目 / 题型 / 批次是三个独立维度，任一变化都重新请求后端（**不在客户端做二次过滤**，否则分页会错）。
- 筛选行下方新增一行 `_buildDimensionRow()`：科目下拉（复用 `_loadBatchSubjects()` 的数据源，首次点开时懒加载并缓存）、题型下拉（多选，带勾选标记，来源是 `kQuestionTypeLabels` 本地枚举，不额外发请求）。
- 再下方 `_buildActiveFilterTags()` 显示「当前筛选：科目=行测 · 题型=选择题 · 未掌握 · 批次=国考50题」，每个标签点一下就清掉对应维度，另有「清除全部」。
- 有叠加条件且结果为空时，空状态文案改为「该筛选条件下没有题目」+「清除所有筛选」（而不是原来的「去题库」）—— 用户此刻最可能想放宽条件，而不是跳到另一个页面。
- 筛选状态只存在页面 State 里（**不持久化**）：退回再进来会重置，避免「上次筛的东西」在下次打开时静默生效。切到「已删除 / 已隐藏」档时会把科目 / 题型 / 批次一起清掉（这两档的数据源不带这些参数）。

**校验**：新增 `server/routes/question_filter.integration.test.mjs`（8 个用例：无筛选基线 / type 单选与多选 / mastery 三态 / type+mastery / 三维 / 四维全参数 / 旧参数兼容 / owner 隔离），PGlite 真库 **8/8**；`npm test` **419 tests / 215 pass / 0 fail / 204 skipped**；`flutter analyze --no-fatal-infos` **0 error / 0 warning / 98 info**；`flutter test` **108/108**（按任务书未截图、未跑 adb）。
### 用户信息与修改用户名（m28943：`GET /me` / `PATCH /me`）

「我的」页要显示真实昵称与 ID，而旧实现把 `kDemoUserId` 硬编码在前端（`1111****`），换 Token 后仍是同一个假 ID。现在用户信息由后端提供，昵称可在「我的」页就地修改。

**端点**：

| 方法 & 路径 | 说明 |
|---|---|
| `GET /me` | 返回 `{id, nickname, display_name, masked_id}`。昵称优先，没有昵称时 `display_name` 回落 `用户_<id 末 4 位>` |
| `PATCH /me` | body `{nickname}` → 返回与 `GET /me` 同形。缺字段 → 400 `MISSING_NICKNAME`；校验失败 → 400 `INVALID_NICKNAME`（透传中文原因）；用户已软删 → 404 |

**为什么不是 `/users/me`**：`server/index.mjs` 会把 `/users/<第 2 段>` 无条件改写成 `authUserId`，`me` 会被当成 uuid → 必然 404。所以这两个端点在根路径上。

**为什么不需要 `base_version`**：昵称是单值覆盖语义（「我叫什么」），不存在字段级冲突；两端同时改名时后到覆盖先到符合预期。`version` 仍由 `users` 表的 `set_updated()` 触发器自增。

**校验规则**（`core/validators.mjs` 的 V15 `validateNickname`，前后端逐条对齐）：只允许中文（基本区 U+4E00–U+9FA5）、英文、数字；trim 后长度 2–20（按 code point 计）；不允许空格（含全角空格）、下划线、标点、emoji。DB 的 `users.nickname` 是 `text` 无长度约束，所以上限只能在应用层做。

**多端同步的口径**：`users.nickname` 是唯一真源，**前端不写任何本地昵称缓存**。任何一端改名后：①本机保存后直接用后端返回值覆盖 `_user`；②其他端在下拉刷新 / 切 Token / 冷启动时重拉 `/me` 即得新值。因为昵称不在本地 SQLite 里，所以 `profile_page._refresh()` 在「本地优先」分支里**单独**补了一次 `_loadUser()` —— 否则「另一端改了名，这台下拉刷新」看不到变化，就不是真·多端同步。

**前端**（`tillroad_app/lib/pages/profile_page.dart`）：用户名右侧一个铅笔图标（不新增独立入口），点击弹 `_RenameNicknameDialog`；本地先按同一套规则校验并内联报错（不通过就不关弹窗、不发请求），通过后才调 `PATCH /me`。失败必须弹「修改失败」说明原因（`INVALID_NICKNAME` 直显后端 message），**不得静默失败**。成功后高亮闪烁 600ms + 顶部 toast「用户名已更新」。弹窗用独立 `StatefulWidget` 持有 `TextEditingController` 以便 dispose —— 放在页面 State 里会踩「controller used after being disposed」（退场动画还会再跑一帧）。

> 分发到多个账号时常见困惑：切换 Token 后如果昵称和 ID 都没变，先看 `shared_prefs` 里的 `flutter.api_token` 与 `flutter.current_user_id` 是不是都换了。只换了前者、后者没换，说明 `saveApiToken()` 没把内存标志置位（本轮修的 bug），表现就是「点了没反应」。

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

- `tillroad_app/lib/` 74 个 dart 文件：`main.dart` / `theme/` 1 / `config/` 3（`api_config`、`app_info`、`local_config`）/ `mock/` 2（`home_mock`、`defects_mock`）/ `api/` 7 / `logging/` 4 / `local/` 16（其中 `local/dao/` 5）/ `pages/` 29 / `widgets/` 11。
- 运行时依赖 `cupertino_icons` + `http` + `shared_preferences` + `share_plus` + `sqflite` + `path` + `file_picker`（后两个是本地优先 R1 引入、`file_picker` 是题库导入入口引入，见下节）；dev 依赖 `flutter_lints` + `flutter_launcher_icons` + `sqflite_common_ffi`（**仅测试用**，不进产物）。**无状态管理库、无路由库、无图表库、无 ORM、无 build_runner**。
- ⚠️ `file_picker` 版本必须是 **^13.4.1**（不是 8.x）：8.x 依赖 `win32 ^5`，与 `share_plus 13.x`（`win32 ^6`）冲突，pub 解析不出来。13.x 的 API 也变了——`FilePicker.pickFiles(...)` 是**静态方法**直接返回 `List<PlatformFile>`（没有 `.platform`、没有 `FilePickerResult`），文件大小用 `await file.length()` 取、内容用 `await file.readAsBytes()` 取（没有 `size`/`bytes` 字段）。
- 兼容平台：`android` / `ios` / `windows`（Windows 仅为本机开发期验证用，交付目标是移动端；**Windows 上不启用本地库**，见下节）。
- 已知 `flutter analyze` 输出：**0 error / 0 warning / 86 info**（R1 前是 30 info；R1 +2、R2 +5、R4a +14、R4b +3、题库导入 +3、m18680 +11、§41 修完 13 条 warning 后为 55、题目选择器 +1、FE-02 +18、练习 R1 +10、练习 R3 +2）。全部 info 都是同一条 `deprecated_member_use`（`package:flutter/cupertino.dart` 在 3.47+ 提示改用 `package:cupertino_ui/cupertino_ui.dart`）。刻意不改——改它需要引入第二个运行时依赖，与「纯 Cupertino」的约束冲突。
- **判断 analyze 结果时不要写死行的格式**：本机是 `warning - …`，CI 的机器可读格式是 `warning • …`。写死分隔符会漏判（这坑踩过，见 REVIEW-NOTES §41）。CI 的判据用 `grep -Eq '^[[:space:]]*(error|warning)[[:space:]]'`。

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

> 设计文档：`docs/local-first-design.md`（第 8 章 R1 实现记录，第 9 章 R2 实现记录，第 10 章 R4a 实现记录，第 11 章 R4b 实现记录）。**R1 只建地基**（App 行为零变化）；**R2 起四页先读本地、云端降级为后台刷新与写入通道**；**R4a 起写操作也本地化**（断网乐观更新 + 写队列，联网自动补推）；**R4b 修掉 R4a 的三个集成缺口**（写路径不再被一个开关连坐、详情页按 id 查、首页读本地真实任务）。
**选型：`sqflite` 而非 Drift。** 单纯比依赖数：`sqflite` 只引入 1 个直接依赖（`path` 是它的路径依赖），Drift 要 5 个（`drift` / `drift_dev` / `build_runner` / `sqlite3_flutter_libs` / `drift_flutter`）再加一个代码生成步骤。本项目的查询只有约 15 条简单 SQL，手写映射与现有 `lib/api/*.dart` 风格一致（那里也是手写 snake_case 映射，不用 `json_serializable`），引 ORM 换不来收益。

| 文件 | 行数 | 职责 | 引入 |
|---|---|---|---|
| `lib/config/local_config.dart` | 40 | `kLocalFirstEnabled`（**R2 起为 `true`**，读路径开关）+ **`kLocalDbReady`（R4b 起，写路径判据）** + `kLocalDbUnavailableReason` + `kLocalDbFileName` | R1 / R4b |
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

**数据库文件位置**：`getDatabasesPath()/tillroad_local.db`。Android 上即 `/data/data/com.tillroad.app/databases/tillroad_local.db`（与其他 sqflite 应用一致，root 设备或 `adb shell run-as` 可见；包名在 v1.1.0 已从 `com.tillroad.tillroad_app` 改为 `com.tillroad.app`）。

**Windows 不支持**：`sqflite` 的桌面实现要额外的 `sqflite_common_ffi` + `sqlite3_flutter_libs`，本轮按拍板第 5 条不做，桌面端 `kLocalFirstEnabled` 保持 `false`、继续直连云端。测试能跑是因为 `sqflite_common_ffi` 只进了 `dev_dependencies`（`test/local_db_test.dart` 里通过 `LocalDb.debugFactoryOverride` 注入）。
**分页终止只能看 `items.length < limit`**：后端 `defect-tickets` 响应里没有 `total`，`mock-exams` / `review-cycles` 的 `total` 就是 `items.length`（假 total）。所以首次填充与后台刷新都用 `items.length < 200` 判断结束，且 **200 必须与服务端 `pageParams` 的上限一致**——写成 300 会被服务端夹回 50，每页都「不满」而立刻终止，数据静默缺失。
**不声明 FOREIGN KEY**：本地是「云端投影 + 待推送队列」，父子行到达顺序由同步批次决定，硬外键会让「先到子行、父行还没拉下来」的中间态直接写失败。引用完整性靠 R3 的「先父后子」拉取顺序 + 查询不用外键假设 + 队列的 `dead` 状态兜底。
**R4a 的写路径本地化**（五个写页面）：①本地状态机先校验（非法直接报错、不入队）；②乐观更新本地行（`sync_state = 2 dirty`），UI 立即反馈；③写一条 `pending_operations` 队列行；④联网后由 `PushEngine.pushPending()` 串行补推。推送错误分级：**409 → conflict**（列表角标变橙、详情页出橙色横幅「该单已被修改，请刷新后重试」，点刷新 = 丢弃本地修改 + 以云端为准）、**400 / 404 → dead**（本地规则与云端漂了或目标没了，不重试）、**网络 / 5xx → 可重试**（退避 `2^retry × 2s`，上限 5 分钟，超过 5 次转 dead）。触发时机四处：App 启动、写操作后、下拉刷新、回前台。

**一个容易踩的契约差异**：`PATCH /defect-tickets/:id/actions/:actionId` 的乐观锁作用在 **actions 表自己的 version** 上，不是缺陷单的 version；`PATCH /defect-tickets/:id/begin-verification` 的入参状态是 **ANALYZED**（云端内部自己做 ANALYZED→ACTION_DONE→V1 两跳），不是 core 纯函数里的 `ACTION_DONE`。这两处本地实现都刻意与 `core/index.mjs` 不同口径，以云端端点为准（详见设计文档 §10.7）。

**R4b：写路径与读路径的开关拆开**：R4a 只有一个 `kLocalFirstEnabled`，本地库初始化失败一次就把它置 false，于是**整个 App（包括写操作）静默退回直连云端**——用户看到「提交成功」，其实请求打到了云端，断网时直接失败且没有任何提示。R4b 拆成两个：**`kLocalDbReady`**（本地库能不能用 → 写操作的判据）与 **`kLocalFirstEnabled`**（要不要走本地优先读路径 → 读路径的判据，保留便于一行回退）。五个写页面的分支判据全部改成 `kLocalDbReady`。

**R4b：详情页按 id 查**：`loadDefectTicketById(userId, id)` 用 `local_id = ? OR server_id = ?` 命中，取代原先「拉全量再在内存里按 `t.id == id` 匹配」——后者在离线新建（id 是本地 UUID）、推送回填（id 变云端 UUID）、旧快照三种情况下都匹配不上，导致详情页在本地读不到、列表与详情状态不一致。

**R4b：首页「今日待验证」读本地真实任务**：R4a 之前首页这张卡始终渲染 mock 常量 `kHomeSnapshot.tasks`（只有三色计数是真的）。R4b 改为读 `loadVerificationTasks()` 的本地结果，空时才回落 mock；点卡片直接进该单的详情页。

**R4b：启动一致性校验**：`checkLocalStatusConsistency()` 对比本地与云端的 `defect_tickets` status 分布，不一致就记 warn 并触发一次全量对账。埋点：`[QUEUE] 入队 xxx op_id=N` / `[PUSH] xxx 成功，本地 status=… version=…` / `[LOCAL] 读取缺陷单 N 条`——三行日志能把「写入 → 队列 → 推送 → 本地刷新」整条链自证出来（详见设计文档 §11）。

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

分发前的四个测试 token 映射为：`tltest001` → `11111111-1111-4111-8111-111111111111`，`tltest002` → `cbd8eb64-73d9-44c3-9898-aa2e701e8d84`，`tltest003` → `939705ec-7dd1-4b2e-bba4-e18e57175b08`，`tltest004` → `50bf600c-b648-4722-9378-160d6711acdf`。**旧的 `tk_test_001` / `tk_test_002` 已失效**（分发前重置），拿旧 token 请求会得到 401。Token 只通过 `Authorization: Bearer <token>` 发送，后端不会记录 Token。`/health` 和 CORS `OPTIONS` 预检公开，其余请求在配置 `TOKENS` 后必须鉴权。移动端没有浏览器 `Origin`，因此 MVP 保留 `Access-Control-Allow-Origin: *` 与 `Access-Control-Allow-Credentials: false`。

### 验证与发布 APK

```bash
curl -i https://tillroads-production.up.railway.app/health
curl -i -H "Authorization: Bearer tltest001" https://tillroads-production.up.railway.app/users/11111111-1111-4111-8111-111111111111/exam-profiles
curl -i https://tillroads-production.up.railway.app/users/11111111-1111-4111-8111-111111111111/exam-profiles
flutter build apk --release --dart-define=API_BASE_URL=https://tillroads-production.up.railway.app --dart-define=API_TOKEN=tltest001
```

不提供 `API_TOKEN` 时，App 首次启动会显示 Token 输入页，并使用 `shared_preferences` 保存在本机。**本地保存值优先于编译期 Token**（用户手动切换后必须立即生效，否则就是 A3 要修的「点了没反应」）；只有本机从未保存过时才回落编译期值。APK 输出路径为 `tillroad_app/build/app/outputs/flutter-apk/app-release.apk`。部署完成后应确认 `/health` 返回 200、无 Token 返回 401、正确 Token 返回自己的数据，另一个 Token 可以返回其用户的空列表。
### 打包分发（release 签名）

`android/app/build.gradle.kts` 的 release 签名是**条件式**的：

- 存在 `tillroad_app/android/key.properties` → 用其中指定的 keystore 签名；
- 不存在 → 回落到 debug 密钥（只够本机 `flutter run --release` 自测，**不可对外分发**）。

两个文件 `key.properties` 与 keystore（`**/*.jks`）都已在 `android/.gitignore` 排除，不会入库。生成正式 keystore：

```powershell
# 在仓库根执行；口令自己记住，别写进任何提交物
pwsh -File tillroad_app/scripts/make-keystore.ps1 -StorePassword "你的口令" -KeyPassword "你的口令"
```

脚本会在 `tillroad_app/android/` 下生成 `tillroad-release.jks` 与 `key.properties`（PKCS12 格式、RSA 2048、有效期 10000 天）。等价的裸 keytool 命令：

```powershell
keytool -genkeypair -keystore tillroad_app/android/tillroad-release.jks -storetype PKCS12 `
  -keyalg RSA -keysize 2048 -validity 10000 -alias tillroad `
  -storepass "你的口令" -keypass "你的口令" -dname "CN=TillRoad, OU=Mobile, O=TillRoad, L=Shanghai, S=Shanghai, C=CN"
```

然后构建并校验签名：

```powershell
flutter build apk --release --dart-define=API_BASE_URL=https://tillroads-production.up.railway.app --dart-define=API_TOKEN=tltest001
apksigner verify --print-certs tillroad_app/build/app/outputs/flutter-apk/app-release.apk
# 应看到 certificate DN: CN=TillRoad, ...
```

**务必离线备份 keystore 与 key.properties**：Android 的覆盖升级要求签名一致，丢了就再也无法给已装用户发升级包，只能换 `applicationId` 重新上架。

签名是自签名证书，足够侧载 / 内测分发；若要上架 Google Play，需要用同一套 keystore 或改走 Play App Signing。

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


### 分发前检查清单

> 面向「把 APK 发给几个测试同学」这个场景。每一步都做完再发包。

- [ ] **Neon `users` 表里有 4 个用户**，UUID 与 Railway `TOKENS` 一一对应：
      `tltest001` → `11111111-1111-4111-8111-111111111111`；
      `tltest002` → `cbd8eb64-73d9-44c3-9898-aa2e701e8d84`；
      `tltest003` → `939705ec-7dd1-4b2e-bba4-e18e57175b08`；
      `tltest004` → `50bf600c-b648-4722-9378-160d6711acdf`。
      新建用户用 `node --env-file=.env --dns-result-order=ipv4first scripts/seed-users.mjs`（按 nickname 幂等，重跑安全）。
- [ ] **Railway Variables 的 `TOKENS` 已改为四个新 token**（逗号分隔的 `token:user_uuid` 列表），旧的 `tk_test_001` / `tk_test_002` 已删除。
- [ ] **Railway 已点 Redeploy / Restart** —— 只保存变量不重启，服务不会加载新 `TOKENS`（这是最容易漏的一步）。
- [ ] **curl 验证**：
      ```bash
      curl -i https://tillroads-production.up.railway.app/health                                  # 200
      curl -i -H "Authorization: Bearer tltest001" https://tillroads-production.up.railway.app/users/11111111-1111-4111-8111-111111111111/exam-profiles   # 200 + 自己的数据
      curl -i -H "Authorization: Bearer tk_test_001" https://tillroads-production.up.railway.app/users/11111111-1111-4111-8111-111111111111/exam-profiles # 401（旧 token 已失效）
      ```
- [ ] **版本号已改**：`tillroad_app/pubspec.yaml` 的 `version: 1.1.0+2`，且 `lib/config/app_info.dart` 的 `kAppVersion` 同步为 `'1.1.0+2'`（两者必须逐字一致）。
- [ ] **包名已改**：`com.tillroad.tillroad_app` → `com.tillroad.app`（`android/app/build.gradle.kts` 的 namespace 与 applicationId、`MainActivity.kt` 的 package 声明与目录）。
      ⚠️ **旧版 App 无法覆盖安装**（包名变了就是另一个 App），测试同学必须**先卸载旧版再装新版**，否则会看到两个「题路」。
- [ ] **构建**：
      ```powershell
      cd tillroad_app
      flutter clean
      flutter pub get
      flutter build apk --release --dart-define=API_BASE_URL=https://tillroads-production.up.railway.app
      # 不带 --dart-define=API_TOKEN：让每位用户在 App 首次启动时自己输入 token，
      # 这样同一个 APK 可以发给所有人，互不串号。
      ```
      APK 路径：`tillroad_app/build/app/outputs/flutter-apk/app-release.apk`。
      ⚠️ 用了 `key.properties` / 正式 keystore 才能对外分发；没有则回落到 debug 签名（仅本机自测）。
- [ ] **上传 GitHub Release**（或直接传 APK 给测试同学），附上「首次启动要输入 token」的说明。
- [ ] **分配 token 给每位测试用户**（一人一个，别共用）：
      | token | 对应 Neon 用户 | 备注 |
      | --- | --- | --- |
      | `tltest001` | 联调演示用户（`1111****`） | 主测试号 |
      | `tltest002` | `cbd8****` | 第二位测试者 |
      | `tltest003` | 测试用户C（`9397****`） | 第三位测试者 |
      | `tltest004` | 测试用户D（`50bf****`） | 第四位测试者 |
      每人独立账号 → 各自的缺陷单、题库、练习记录互不可见。
- [ ] **提醒测试者**：旧 token 已失效、旧 APK 不能再用；换 token 要在 App 的「我的 → 设置 → 切换 Token」里改。

> 备注：本机 pg 直连 Neon pooler 可能报 `ECONNRESET`（冷启动/网络路径问题）。遇到时改用 Neon 的 WebSocket 通道：
> `npm install --no-save @neondatabase/serverless`，用 `new Pool({..., ws: true})` 建连接即可（`server/db/pool.mjs` 不用改）。

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
- ✅ **本地优先 R4b**：修掉 R4a 的三个集成缺口。①**根因不是「写队列没接」**（五页早就有分支），而是 `kLocalFirstEnabled` 是个一票否决开关——本地库初始化失败一次就置 false，**整个 App（含写操作）静默退回直连云端**，用户看到「提交成功」其实请求打到了云端；R4b 拆出 **`kLocalDbReady`**（写路径判据）与 `kLocalFirstEnabled`（读路径判据）②详情页改用 `loadDefectTicketById`（`local_id = ? OR server_id = ?`）取代「拉全量再内存匹配」，修掉离线新建/推送回填/旧快照三种 id 对不上导致的「列表与详情不一致」③首页「今日待验证」改读本地真实任务（此前只渲染 mock）④写操作反馈措辞区分「已保存（联网后自动同步）」与「已提交」⑤新增启动一致性校验（本地 vs 云端 status 分布不一致 → warn + 全量对账）与三类埋点（`[QUEUE]` / `[PUSH]` / `[LOCAL]`）；`flutter test` **106/106**、`flutter analyze` 0 error / 54 info；Android 真机 E1 断网首页读本地 4 条 / E2 断网详情页本地命中 / E3 断网提交 V3 pass 入队（本地 CLOSED，队列 +1）/ E4 联网推送成功（`[PUSH] 提交验证成功，本地 status=CLOSED version=2`，队列清空）/ E7 adb 核对队列，7 张截图留证
- ✅ **题库导入入口 + owner_user_id 多用户隔离（m17431）**：后端新增 `questions.owner_user_id`（独立幂等迁移 `migrations/0002_questions_owner.sql` + down 脚本，不改 `schema.sql`/0001）+ 查重按 owner 分域（单题/批量/更新三处）+ 组卷抽题限「公共题 + 自己的题」+ 新增只读端点 `GET /questions`（原先后端**没有**题库列表端点，items 不含 answer/analysis）+ 导入路由只认 token 映射的 userId（不信任请求体）；前端新增「我的 → 题库管理」入口 + `question_bank_page.dart`（按科目分组、默认最新在前）+ `question_import_page.dart`（file_picker 选文件 md/txt/csv/pdf/xlsx → 选科目 → 选考点可选 → base64 上传 → 结果页 imported/duplicates/errors + 413/422/415/400 分档人话提示）+ `question_api.dart`；唯一新依赖 `file_picker`（必须 ^13.4.1，8.x 与 `share_plus 13.x` 的 `win32` 版本冲突）；Neon 真库验证：A 导入 12 → B 导入同文件 12（**不判重**）→ A 再导入 0 新增/12 判重 → B 组卷抽题 **A 私有题 0 命中** → `GET /questions` A 私有题**泄漏给 B = 0**；Android 17 真机走通「我的 → 题库管理 → 导入 → 选文件 → 选科目 → 上传 → 新增 12 → 列表显示「我导入的」→ 再导入同文件判重 12」，7 张截图留证
（`fe-import-50.png` / `fe-import-dupes.png` / `fe-exam-config.png` / `fe-exam-create.png` / `fe-subject-config.png` / `fe-knowledge-tree.png` / `fe-settings-danger.png` / `fe-delete-confirm.png`）
- ✅ **四项阻塞项复核 + CI 接入 Flutter（m21159）**：先读源码盘点，四项（判重 / 重置语义与待验证残留 / 文件选择器 / 考试配置）**均已修**，本轮未再改业务代码。真正补的两件：①**真后端判重双向验证**（`imported 3 → 0`、`duplicates 0 → 3`，后端 `[IMPORT]` 四段日志同步印证，验完软删 3 道测试题不留垃圾）；②**CI 新增 `flutter-tests` job**（`subosito/flutter-action@v2` 钉 `3.50.0` → `pub get` → `analyze --no-fatal-infos` 并用 `grep -Eq '^[[:space:]]*(error|warning)[[:space:]]'` 硬拦 → `flutter test`），两个 `paths` 补 `tillroad_app/**`；YAML 用 `yaml` 包解析断言结构（3 job / steps 9·4·6）而非肉眼。新增截图 `fe-reset-home-empty.png`（全新空用户的首页三空态：无考试目标、待验证 0、缺陷 0）；`flutter analyze` 55 issues / **0 error / 0 warning**、`flutter test` **106/106**
- ✅ **CI 首次真跑修复（m21384）**：`flutter-tests` 真跑后暴露两类问题，**后端全部失败都是测试自身 bug、不是产品 bug**：①`questions.integration.test.mjs` 的 `after()` 只按 owner 删题，漏掉第 4 个用例插在 B 科目下的 2 道公共题 → `DELETE FROM subjects` 报 `23503 questions_subject_id_fkey`（修为「或位于这两个用户的科目下」）；②可见性用例拿 A 的全部题与 B 的全部题取交集，把公共题误判为泄漏（`2 !== 0`）→ 改为只比 **A 的私有题**并附基数断言；③修好前两个才浮出的第三个：`after()` 从未删 `mock_exams`，第 4 个用例建的模考记录引用 `exam_profiles` → `23503 mock_exams_exam_profile_id_fkey`（在删 `exam_profiles` 前补删）。另修 **13 条 Flutter warning**（`unnecessary_cast` ×2、`unused_import` ×4、`unused_shown_name` ×3、`unnecessary_non_null_assertion` ×4），并把 CI 的 grep 判据从写死 ` - ` 改为只认开头级别词、用 `PIPESTATUS[0]` 捕获 analyze 真退出码。验证用 PGlite（真实 Postgres WASM）**直接跑真实测试文件**（只替换一行 import）→ **5/5 通过**，正是这层揭出了第三个 FK bug；CI 判据用真 bash 跑 6 份日志（干净 PASS / `warning -` BLOCK / `warning •` BLOCK / 仅 info PASS / `error` BLOCK / 仅汇总行 PASS）。最终 `flutter analyze` 55 issues 0 error 0 warning、`flutter test` 106/106、`npm test` 321 tests / 194 pass / 0 fail / 127 skipped
- ✅ **题目选择器 + `GET /questions` 加 `q` / `knowledge_node_id`（m21779）**：提交验证页的「关联题目 ID」原本是手输 UUID（`如：f47ac10b-…`），**没人能背出 UUID，所以该字段自 FE-04 上线起实际上从未被填过**。本轮换成真正的选择器：后端 `GET /questions` 加两个查询参数（`stem ILIKE $n ESCAPE '\'` / `knowledge_node_id = $n`，返回结构不变、items 仍不含 answer/analysis），LIKE 元字符 `\` `%` `_` 用 `escapeLikePattern()` 转义（不转义时搜「100%」变通配符），空白关键字当没传；**顺手修了一个既有 bug**：`knowledgeNodeId` 原本从 query 读出来却未传给仓储，考点过滤一直失效。前端新建 `question_picker_page.dart`（740 行）：`CupertinoSearchTextField` + `Timer(300ms)` 防抖（不引 rxdart）、首屏 `limit=50` 滚动到底自动翻页（`_hasMore` 只看服务器原始条数、追加时按 id 去重）、三组本地筛选（来源/题型/导入时间）、空态与加载态（顶部 3px `ColoredBox` 色条，**不能用 Material 的 `LinearProgressIndicator`**）；返回 `PickedQuestion{id, stem}`，验证页显示题干前 30 字 + 「更换」「不关联」，**提交路径一行未改**。集成测试新用例 6 组断言，**把绝对条数断言改成相对基线**（前 5 个用例已导入含「马克思主义」的题，绝对断言会漂）。真机：V1 单 → 提交验证 → 选择器 → 搜 `35` → 选中回填 → 提交成功，**云端实证 `status=V2 version=4` 且 `V1 r1 pass q=fa68a44e-…`**；「我导入的」筛选与空态验证通过；**中文关键字未能真机输入**（`adb shell input text` 对非 ASCII 直接 NPE，ADBKeyboard 在 API 37 上广播不落 `InputConnection`），中文 `q` 仅在 API 层验证（`?q=马克思主义` → 1 条），UI 层用 ASCII 关键字验证全链路。4 张截图留证；`flutter analyze` 56 issues **0 error / 0 warning**、`flutter test` **106/106**、`npm test` **322 tests / 194 pass / 0 fail / 128 skipped**、PGlite 真库 6/6
- ✅ **建题 / 编辑 / 删除题目（FE-02）**：题库从「只读的导入产物」变成「可手写、可改、可删」。后端新增 `POST /questions`（手动建题，`source` 固定 `manual`、归属只认 token、选项三种写法归一成 `[{key,text}]`）、`GET /questions/:id`（含 answer/analysis/version，别人的私有题回 404）、`PATCH /questions/:id`（改题干自动重算 hash 并重新查重）、`DELETE /questions/:id`（软删）；**仓储层的 create/update/archive 早就写好了，本轮只补路由与归属校验，不改 schema**。前端新建 `question_edit_page.dart`（建题与编辑共用一页，9 种题型 chip + 逐条选项编辑 + 难度/标签/主观题开关 + 科目/考点选择）、`question_api.dart` 补四个写方法与 `QuestionDetail` 模型、题库页接「建题」按钮 + 点卡片进编辑 + 「⋯」动作表（编辑/删除，删除前先拉详情拿 version）。导入页加**三态进度**（本地编码 / 服务端处理 / 完成）、**大文件预检**（>2MB 提示拆分）、**超时文案**（提醒先去题库页确认，别盲目重试）。**本轮不做拍照 OCR**（后端无 provider/密钥基建，真 OCR 需先做 BYOK 服务端密钥管理 + vision adapter + 图像存储 + 置信度阈值），**不建 import_jobs 表**（后端是一次性同步接口，没有 job id 可查）。后端 6 条新集成用例（PGlite 真库 **12/12** 通过），`flutter analyze` 0 error / 74 info、`flutter test` **106/106**、`npm test` **328 tests / 194 pass / 0 fail / 134 skipped**
- ✅ **练习模式 R1（抽题 → 答题 → 客户端判分 → 错题去归因）**：新增独立迁移 `migrations/0003_practice.sql`(+down，**不改 `schema.sql`**，Neon 真库已执行 1860ms)——`practice_sessions` / `practice_answers` 两表 + `idx_ps_user(user_id, created_at DESC)` / `idx_pa_session(session_id)`；后端新增 `server/routes/practice.mjs` 与 `server/repositories/practice_sessions.mjs`（**练习模块必须排在 questions 模块之前**，否则 `GET /questions/practice` 会被当成 `GET /questions/:id` 读 id='practice'）：`GET /questions/practice`（source=mine/public/all，`count` 默认 10 上限 50，**题量不足不报错**而是返回 `available`）、`POST /practice-sessions`（返回 total/correct/wrong/unjudged/accuracy）、`GET /practice-sessions`（只返回 token 映射的 userId 自己的）、`GET /practice-sessions/:id`（**别人的会话 → 404**，不用 403 避免枚举 id）。**答案安全底线做在仓储层**：抽题 SQL 答案列写成 `CASE WHEN owner_user_id = $n THEN answer ELSE NULL END`，公共题的 answer/analysis 永远为 null，客户端据此显示「该题不提供答案，请自评」+ 对/错两按钮。前端新建 `api/practice_api.dart` 与四个页面（`practice_config_page` / `practice_answering_page` / `practice_result_page` / `practice_history_page`）；入口接三处（首页快捷入口「开始练习」、题库页导航栏「练习」、「我的 → 练习记录」）；错题「去归因」→ 建单页并预填错因「练习中未掌握」+ question_id（`DefectCreatePage` 新增三个可选参数，`DefectApi.createDefectTicket` 与 `WriteQueue.enqueueCreateDefect` 均补传 `question_id`）。修掉一个真机/真库才暴露的后端 bug：`pickQuestions` 一开始就 `params = [userId]`，public 分支 where 不引用 userId → count 查询多带一个参数 → PG 报 `bind message supplies 1 parameters, but prepared statement requires 0` → 被 `httpError` 吞成 500；改为按需追加参数 + 动态编号占位符。PGlite 真库 **8/8** 通过，`flutter analyze` 0 error / 84 info、`flutter test` **106/106**、`npm test` **336 tests / 194 pass / 0 fail / 142 skipped**
- ✅ **练习模式 R2（掌握度标记 + 未掌握进缺陷单）**：新增独立迁移 `migrations/0004_question_mastery.sql`(+down，**不改 `schema.sql`**，Neon 真库已执行 1802ms)——`question_mastery` 表（`user_id` / `question_id` / `mastered` boolean NOT NULL / `UNIQUE(user_id, question_id)`）+ 索引 `idx_qm_user` / `idx_qm_question`；**三态语义**：表里没这一行 = 未标记（与 `mastered=false` 不同），所以 API 的 `mastered` 是可空布尔。后端新增 `server/repositories/question_mastery.mjs`（`upsertMastery` 用 `ON CONFLICT DO UPDATE`；过滤用 `EXISTS` 子句而非 JOIN，避免重复行）与 `PATCH /questions/:id/mastery`（upsert；**只能标记自己的题**，公共题/别人的题 → `403 FORBIDDEN_MASTERY`，无 Token 401，`mastered` 非布尔 400 `INVALID_MASTERY`）、`GET /questions?mastered=true|false`（过滤走后端）；前端结果页对题加「已掌握 / 未掌握」按钮（**仅自己的题显示**）+ 顶部「全部标记已掌握」批量按钮，标「未掌握」时弹确认后**自动建一条缺陷单**（`question_id`=当前题、`error_layer=识别`、`error_cause=练习中未掌握，需复习`）；题库页新增「全部 / 已掌握 / 未掌握」筛选 chip + 卡片右上角徽标（已掌握绿 / 未掌握橙，未标记不显示）。修掉一个真机才暴露的 bug：批量「全部标记已掌握」的过滤条件写成 `_mastery[id] != true`，会把已标「未掌握」的题改回 true → 改为只处理 `_mastery[id] == null` 的题（真机复验 DB `masteredTrue=11 masteredFalse=2`，未掌握两题未被覆盖）；本机 pg 直连 Neon 连续 `ECONNRESET` → 改走 Neon serverless 的 WebSocket 通道。PGlite 真库新测试 **6/6** 通过（回归 questions 12/12、practice 8/8），`flutter analyze` 0 error / 84 info、`flutter test` **106/106**、`npm test` **342 tests / 194 pass / 0 fail / 148 skipped**，Android 17 真机 D1/D2/D3 全过 + 7 张截图
- ✅ **练习模式 R3（已掌握题移除 + 恢复 + 题库管理页）**：新增独立迁移 `migrations/0005_question_hidden.sql`(+down，**不改 `schema.sql`**，Neon 真库已执行 2041ms)——`question_hidden` 表（`user_id` / `question_id` / `hidden_at` / `UNIQUE(user_id, question_id)`）+ 索引 `idx_qh_user` / `idx_qh_question`。**三个拍板**：Q1 移除 = **软删**（连模考组卷都抽不到）而不是隐藏；Q2 公共题**不能软删**（→ `403 FORBIDDEN_DELETE`），只能「只对我隐藏」；Q3 已掌握但未移除的题**模考照抽**（掌握度是主观标记，模考要覆盖真实范围）。后端新增 `server/repositories/question_hidden.mjs`（`hideQuestion` / `unhideQuestion` / `hiddenFilterClause`，过滤用 `NOT EXISTS` 子句）+ `server/repositories/questions.mjs` 的 `restore` / `archiveBatch` / `restoreBatch` / `listDeleted` / `getByIdIncludingDeleted`；端点 `DELETE /questions/:id`（软删）、`PATCH /questions/:id/restore`（**刻意不要 base_version**）、`DELETE /questions/batch`、`PATCH /questions/batch/restore`（回 `{deleted|restored, requested, skipped}`，公共题/别人的题静默跳过）、`PATCH /questions/:id/hide`、`GET /questions/deleted`。前端新建 `lib/pages/question_manage_page.dart`（约 700 行）：「我的 → 题库管理」入口改指新页（原题库列表页降为管理页右上角「浏览」），四个筛选（全部/已掌握/未掌握/已删除）+ 多选批量移除/恢复 + 单题移除/恢复，批量结果**如实展示 skipped**。修掉三个真 bug：①`restoreQuestion` 用 `qRepo.getById`（`requireRow` 只看未软删行）→ 恢复永远 404，新增 `getByIdIncludingDeleted`；②`PATCH /questions/batch/restore` 被 `PATCH /questions/:id/restore` 分支抢走（`seg[2]==='restore'` 撞车）→ 把 `'batch'` 当 uuid 查 → PG `22P02` → 被 `httpError` 吞成 `{error:'internal'}`，**分支顺序上移**；③练习抽题的 `pickQuestions` 有自己的 SQL 不走 `listVisible` → 隐藏的公共题仍被抽到，补 `hiddenFilterClause`。PGlite 真库新测试 **6/6** 通过（回归 questions 12/12、mastery 6/6、practice 8/8，共 26/26），`flutter analyze` 0 error / 86 info、`flutter test` **106/106**、`npm test` **348 tests / 194 pass / 0 fail / 154 skipped**，Android 17 真机 D1/D2/D3 全过 + 3 张截图
- ✅ **分发前配置收尾（包名迁移 + 版本 1.1.0+2 + 脱敏正则覆盖新 token + 分发清单）**：Android 包名 `com.tillroad.tillroad_app` → `com.tillroad.app`（`build.gradle.kts` 的 namespace / applicationId 双改 + `MainActivity.kt` 移包并改 package 声明；`AndroidManifest.xml` 用相对名 `.MainActivity`，无需改）——**旧版无法覆盖安装，测试者必须先卸载旧版**。版本号 `1.0.0+1` → `1.1.0+2`（`pubspec.yaml` + `app_info.dart` 的 `kAppVersion` 逐字同步；`versionCode` / `versionName` 本就取自 pubspec；无 `locale.properties` 可清）。脱敏正则从只匹配 `tk_` 前缀改为交替组，同时覆盖 `tk_` 与 `tltest` 两种格式——**新 token `tltest001` 原先不会被脱敏**（等于把可用凭证写进导出的日志文件），新增 2 条单测（tltest 裸写 / Bearer / 新旧混合三条断言 + `task_x`、`risk_abc` 不误伤），`flutter test` **108/108**。新增 `scripts/seed-users.mjs`（按 nickname 幂等：已存在复用其 UUID、不存在则 `INSERT ... RETURNING`，末行直接打印可粘贴的 TOKENS 片段；本机实测两个用户已存在并打印出 UUID）。README 新增「分发前检查清单」10 项（Neon 四用户 UUID 对照表 / Railway TOKENS / **必须 Redeploy** / curl 三连验证 / 版本号 / 包名 / **不带 API_TOKEN** 的构建 / GitHub Release / 四个 token 的分配表），旧 token 引用全部替换。构建验证：`flutter analyze` 86 issues **0 error / 0 warning**、`flutter test` **108/108**、release APK **52.6MB**；`aapt2 dump badging` 复核 `com.tillroad.app versionCode=2 versionName=1.1.0`。⚠️ 本机无 `android/key.properties` → 该 APK 是 **debug 签名，不可对外分发**，须先按 README「打包分发」一节生成正式 keystore 再构建。
- ✅ **用户信息与修改用户名（m28943：`GET /me` / `PATCH /me`）**：新增两个根路径端点（**不能用 `/users/me`** —— `server/index.mjs` 会把 `/users/<第 2 段>` 无条件改写成 `authUserId`，`me` 会被当 uuid → 必然 404）。`GET /me` 回 `{id, nickname, display_name, masked_id}`；`PATCH /me` body `{nickname}` 回同形。校验单点在 `core/validators.mjs` 的 V15 `validateNickname`（中文基本区 + 英文 + 数字；trim 后 2–20 code point；不允许空格/下划线/标点/emoji），错误码 `INVALID_NICKNAME` / `MISSING_NICKNAME`；**不加 `base_version`**（昵称是单值覆盖语义，无字段级冲突，`version` 仍由 `set_updated()` 触发器自增）。前端 `profile_page.dart` 在用户名右侧加铅笔图标（不新增独立入口）→ 弹 `_RenameNicknameDialog`（本地先按同一套规则校验并内联报错，不通过则不关弹窗不发请求）→ 成功后 600ms 高亮 + toast；失败必须报错不得静默；**不写任何本地昵称缓存**（`users.nickname` 是唯一真源）。修掉两个真缺口：①`profile_page._refresh()` 的本地优先分支从不重拉 `/me` → 另一端改名后本机下拉刷新看不到变化（补 `await _loadUser()`）；②`saveApiToken()` 从未置 `_tokenOverriddenByUser` → 切换 Token 后**本次运行内所有请求仍带构建期的 `--dart-define=API_TOKEN`**，表现为「点了没反应、数据还是上个账号」，只有杀进程重启才生效。测试：V15 单测 16/16（含全角空格 trim 口径）、`users.integration.test.mjs` 6→13 用例（PGlite 真库 13/13）、`flutter test` 108/108、`flutter analyze` 0 error / 0 warning、`npm test` 403 tests / 215 pass / 0 fail / 188 skipped。真机（Android 17 + 本地 ws 后端连 Neon）：改名成功（`Tom2026`）、非法字符 `abc_def` 弹窗不关且内联红字、切 `tltest002` 昵称/ID/统计全部切换（`shared_prefs` 的 `current_user_id` 也换、本地库重填为 B 的 3 行）、再切回仍显示服务端已保存值、另用脚本模拟「另一端改名」后本机下拉刷新可见。截图 `iter-nickname-profile.png`、`iter-nickname-invalid.png`。附带修回 `pubspec.yaml` 的 sqlite3 下载地址（`ghproxy.net` 已不可达 → 删 `hooks` 段回落官方默认，并留注释记录临时镜像写法）
- ✅ **首页时间卡堆叠 + 隐藏公共题 UI + 版本 1.1.5+3（m29656）**：**B 首页时间卡重构** —— 新建 `lib/widgets/exam_card_stack.dart`（361 行，**B3 选 `PageView` 而非自定义手势**：跟手吸附与首/末页边界免费、且 `HorizontalDragGestureRecognizer` 只在超过 `kTouchSlop` 后胜出，与卡内的 Tap/LongPress 在手势竞技场天然互斥，正好满足 B6「三手势不许靠运气共存」）；堆叠最多 3 层（层差 12px、缩放 0.95 / 0.90、第 4 层起右上角 `+N` 徽标，徽标点击跳考试配置）；`_CardPageScrollPhysics` 把 `minFlingVelocity` 提到 300（阈值 18px / 300px·s⁻¹）；`exam_flip_card.dart` 翻转从 300ms `AnimationController` 改为 **`AnimationController.unbounded` + `SpringSimulation(SpringDescription.withDampingRatio(mass:1, stiffness:220, ratio:0.85))`**（unbounded 是必须的：ratio 0.85 会过冲到 ~1.02，有界控制器会把它截成硬停），周期约 424ms；新增 `kExamFlipCardHeight = 108` 固定卡高（与骨架块同值，加载完成不跳动）；长按 ≥500ms → `HapticFeedback.mediumImpact()` + 缩放 1.02 → push 编辑页；`flipResetToken` 令牌在切换卡片时把翻面复位（B4 翻转状态不跨卡片保留）；Reduce Motion 三处降级（关堆叠缩放、翻面直接换面、滑动改 `AnimatedSwitcher` 纯淡入淡出）。为此首页 `_profile` 单条改为 `List<Map<String,Object?>> _profiles` + `_cardIndex`（**保留 `_profile` getter，10 处调用点零改动**），本地查询新增 `loadExamProfiles`，`exam_api.dart` 新增 `updateExamProfile`（`PATCH /exam-profiles/:id` + 必带 `version`），`exam_profile_create_page.dart` 加 `initial` 参数复用为编辑页。**A 隐藏公共题 UI**（补齐 R3 半成品）：`_ManageFilter` 加第五档「已隐藏」、卡片右侧改「⋯」动作表（自己的题 编辑/删除；公共题 隐藏；已隐藏档 取消隐藏）、已隐藏档列表头加「隐藏只影响题库列表，模考仍会抽到这些题」。**因为后端没有 list-hidden 端点、`GET /questions` 默认就排除隐藏题、本轮又禁改 `server/`**，已隐藏列表只能用本地快照 `lib/local/hidden_questions_store.dart`（shared_preferences，`hidden_questions.<userId>`），已知限制（跨设备不可见 / 清缓存丢失 / 不与服务端对账）写在文件头。**C 版本号** `1.1.0+2` → **`1.1.5+3`**（pubspec 与 `app_info.dart` 的 `kAppVersion` 逐字同步）。校验：`flutter analyze --no-fatal-infos` **0 error / 0 warning / 97 info**、`flutter test` **108/108**（本轮按任务书**未截图、未跑 adb**）
- ✅ **题库导入科目自动匹配 + 考点自动创建 + 批量重新分配（m30197）**：**A1** 新增 `server/import/resolve_subject.mjs`（`resolveSubject` + 带 Map 缓存的 `createSubjectResolver`；候选 SQL 必须 `JOIN exam_profiles` 且 `ep.user_id = $1 AND ep.status = 'active'` —— `subjects` 表没有 `user_id` 列；匹配三档 `exact` → `contains`（文件写「行测」命中库里的「行测-资料分析」）→ `contained`，同档取名字最短者；**匹配失败返回 null，绝不自动建科目**）；**A2** 新增 `server/import/resolve_node.mjs`（`splitNodePath` 按 `/` 或全角 `／` 拆、最多 3 层、每层截 40 字；`findNode` 用 `parent_id IS NOT DISTINCT FROM $2` 才能命中根层；逐级缺则 `knRepo.create`，409 并发冲突时重查一次，其他异常 `console.warn` 后返回 null **不整批失败**；自动创建**只发生在导入**，手动建题不建考点）。**A3** 因为 md/txt/csv/pdf/xlsx 都是纯文本、`splitter.parseBlock` 拿不到 `subject`/`node`，新增 `server/import/json_import.mjs`（`parseQuestionJson` 兼容裸数组与 `{questions|items|data|list}`、题型中文映射、选项三种写法归一、单题坏只跳过该题不整份失败、`hasAnySubject` 供判定是否回落统一指定）+ `extract.mjs` 新增 `json` kind（`application/json` / `text/json` / `.json`）。导入管线按 `subject_mode` 分流：`from_file` 时逐题解析 subject/node，**resolution 必须在事务内**（它会写库建考点，抽到事务外会留下「题回滚了但考点还在」）；`uniform` 保持旧行为。★ 两个真 bug：①**文件写了 subject 但匹配不到**时仍解析 node，会把**别的科目的考点路径**建到兜底科目树下污染考点树 → 加逐题 `subjectResolved` flag（初值 true；匹配成功 true、失败 false），node 仅在 flag 为 true 时解析；②`matchedCount` / `unmatchedCount` 两个计数器在插入 flag 时被 edit 连带覆盖删除，导致 `matched_count` 恒 0 而 `matched_subjects` 正确 → 从 PGlite 探针一眼看出不一致才定位到。**A4** 响应新增 `subject_matched: {matched_count, unmatched_count, unmatched_subjects, matched_subjects:[{subject_id,name,count}]}` 与 `node_created: {created_count, created_paths}`，`errors` 改成解析问题列表，`stats` 加 `subject_mode` / `subject_from_file_available`。**C3** 新增 `PATCH /questions/batch`（路由分支**必须排在 `:id` 之前**，否则 `'batch'` 当 uuid → 22P02 → 被 `httpError` 吞成 500）+ 仓储 `updateAssignmentBatch`（只改 `owner_user_id`；`clearKnowledgeNode` 可置空考点但科目不能空；**只换科目且没给考点时一并把 `knowledge_node_id` 置 NULL**，否则出现「题在科目 A、考点挂科目 B 子树」的自相矛盾；不带 version，与 `updateTagsBatch` 同口径）。前端：`question_import_page.dart` 两模式切换（默认「从文件读取」，`uniform` 才强制选科目）+ 结果页「科目匹配结果」「自动创建的考点」两块；`question_manage_page.dart` 批量条加「移动到科目」「设置考点」（两步选择；`clearKnowledgeNode` 清空）。`docs/question-recognition-prompt.md` 第五节重写（JSON 直接上传、`subject_mode` 语义、匹配规则、新响应字段），输出格式示例补上 `subject`/`node` 两字段。校验：新增 fixture `tests/fixtures/questions/sample-04-ai-json.json`（3 行测 + 2 公基，含两级考点）、`import.integration.test.mjs` 12→17 用例、**PGlite 真库 17/17**、`npm test` **408 tests / 215 pass / 0 fail / 193 skipped**、`flutter analyze --no-fatal-infos` **0 error / 0 warning / 97 info**、`flutter test` **108/108**（本轮按任务书**未截图、未跑 adb**）
- ✅ **题库导入批次 + 批次筛选 + 整批删除（m31124）**：`migrations/0007_import_batch.sql`(+down，任务书要求 0006 但已被 `0006_exam_custom_defect_questions.sql` 占用) 给 `questions` 加 `batch_id uuid` / `import_filename text` / `imported_at timestamptz`（均可空，**刻意不建外键**：批次是账本、题是数据）+ 部分索引 `idx_q_batch` + 新建 `import_batches(id, user_id FK, filename, question_count, created_at)` 与 `idx_ib_user_time`；`scripts/migrate.mjs` 的 UP 追加、DOWN 前插，`server/db/test_schema.mjs` 的 MIGRATION_FILES 同步。**导入双写时序**：事务内先 `importBatchesRep.create`（question_count=0 占位）→ 逐题带 `batch_id`/`import_filename`/`imported_at` → 插完 `updateQuestionCount(imported.length)`（判重跳过的不算），三步同一 `withTransaction`，回填失败只 warn 不回滚。新增 `server/repositories/import_batches.mjs`（create / updateQuestionCount / listByUser / getById）与 `server/routes/import_batches.mjs`（`GET /import-batches`，user_id 只认 token，items 白名单四列）。`GET /questions` 加 `batch_id` 查询参数（`listVisible` 里 `batch_id = $n`，NULL 的题不命中任何具体批次 = 手动建题只在「全部批次」可见）。`DELETE /questions/batch` 分流：有 `batch_id` 走整批软删（**countByBatch 必须先于 archiveByBatch**，否则 requested 恒 0），否则走原 `{ids[]}`；参数校验 `INVALID_BATCH_ID`。仓储：`WRITABLE_COLUMNS` 加三列、`UPDATE_COLUMNS` 用 `BATCH_COLUMNS` 排除（编辑不许改档案）、`archiveByBatch` / `countByBatch` 过滤条件严格一致。前端：`question_api.dart` 加 `ImportBatch`（`label` 拼「文件名（N 题）· 相对时间」）/ `fetchImportBatches` / `deleteQuestionsByBatch`，`question_manage_page.dart` 在筛选行下加「批次下拉 + 删除整批」（只在全部/已掌握/未掌握三档显示，已删除走 `/questions/deleted`、已隐藏走本机快照，都不带批次语义），批次列表失败只 debugPrint 不拖垮题目列表。校验：`import.integration.test.mjs` 17→20 用例（导两次两批、删第一批不影响第二批、软删可恢复、重复删幂等、手动建题 batch_id 为 null、参数校验三条），**PGlite 真库 20/20**；`npm test` **411 tests / 215 pass / 0 fail / 196 skipped**；`flutter analyze --no-fatal-infos` **0 error / 0 warning / 98 info**；`flutter test` **108/108**（按任务书未截图、未跑 adb）
- ✅ **题库多条件组合筛选（m31635）**：把筛选器从「一次只能选一档」改成**多维度叠加（AND）**。后端 `GET /questions` 新增两个参数：`type`（逗号分隔多值，按 `QUESTION_TYPES` 过滤非法值后去重，SQL 用 `type = ANY($n::text[])` 数组比较而非字符串拼接）与 `mastery`（三态 `mastered` / `unmastered` / `unmarked`，非法值静默忽略）。★ 关键 SQL 差别：`unmarked` 必须用 **`NOT EXISTS (整个子查询)`**，写成 `NOT EXISTS(… AND mastered = false)` 会把「已掌握」也算成「未标记」——三态由 `question_mastery` 行存在与否承载。新增 `masteryStateFilterClause`（`server/repositories/question_mastery.mjs`），与旧 `masteryFilterClause` 共存、`masteryState` 优先（旧 `mastered=true|false` 仍生效，参数全空时行为不变）。同步 `server/_fake_repos.mjs` 的 `listVisible`（否则 fake 路径用例口径不同）。前端 `question_manage_page.dart`：五个档位保留为「掌握状态」维度，筛选行下新增 `_buildDimensionRow()`（科目下拉复用 `_loadBatchSubjects`、懒加载缓存；题型多选带勾选标记，来源 `kQuestionTypeLabels` 本地枚举不发请求）+ `_buildActiveFilterTags()`（「当前筛选：科目=行测 · 题型=选择题 · 未掌握 · 批次=国考50题」，每标签点掉一条 + 「清除全部」）；有叠加条件且空结果时空状态改「该筛选条件下没有题目」+「清除所有筛选」；筛选状态只存 State **不持久化**，切到已删除/已隐藏档时把科目/题型/批次一起清掉。校验：新增 `server/routes/question_filter.integration.test.mjs`（8 用例），**PGlite 真库 8/8**；`npm test` **419 tests / 215 pass / 0 fail / 204 skipped**；`flutter analyze --no-fatal-infos` **0 error / 0 warning / 98 info**；`flutter test` **108/108**（按任务书未截图、未跑 adb）
- ⏳ **仍待补的后端缺口**：①新增 `defect_events` 表以支持状态时间线完整历史（当前时间线只有「创建 + 当前状态」两个节点）；②CORS 的 `*` 生产前收窄为白名单；③登录体系（当前是固定 Bearer Token 映射，无注册/改密/多设备）；④前端建单后逐条 `POST /:id/actions` 的补丁**已可移除**（后端已改同事务），保留只为向后兼容；⑤Neon 冷启动时三路并发建 TLS 会偶发 `Connection closed before full header was received`（单路重试即恢复，可在 ApiClient 加一次自动重试）；⑥本地优先 R3 的增量对账尚未实现（后端需加 `updated_since` 或变更日志）；⑦R4a 的冲突只做「丢弃本地 + 以云端为准」，字段级自动仲裁与写队列的删除操作未做；⑧R4b 未做 dead 队列的 UI 管理入口（死信行只能在数据库里看），也未做删除操作的入队；⑨题库的 **AI 生成题入口**未做（手动建题与编辑删除本轮 FE-02 已做；题目本地缓存待 R5 拍板）；⑩「删除我的所有数据」只软删不物理删（数据仍在库里可恢复，合规的「彻底抹除」需物理删除与保留期策略）；⑪题目选择器的**考点筛选未做进 UI**（后端 `knowledge_node_id` 已可用且有集成测试，但页面没有该 chip）、**中文关键字未真机验证**（`adb shell input text` 对非 ASCII 直接 NPE）；⑫FE-02 未做**拍照 OCR**（需先补 BYOK 服务端密钥管理与 vision adapter）；⑬练习模式**删题已做（R3）**，但**按题目选择器组练习**、**练习记录删除入口**（`practice_sessions.deleted_at` 无端点）、**每题用时展示**（`duration_ms` 已在收但未显示）仍未做，且公共题自评的对错只存在练习记录里、不回流题库；⑭题库管理页的**物理抹除**未做（题只软删，可恢复）；⑮**「已隐藏」列表目前只能用本地快照**（后端只有 `PATCH /questions/:id/hide`，**没有 list-hidden 端点**，`GET /questions` 默认就排除隐藏题），后果是跨设备不可见、清缓存丢失、与服务端不对账 —— 正确修法是后端加 `GET /questions?hidden=true`（需改 `server/`，本轮硬约束禁止）；⑯`exam_type_custom` 没有写进本地 `exam_profiles` 表，从本地读出的卡片进编辑页时自定义类型名会回落成预设标签，需下拉走一次云端才有；⑰科目匹配是「按名字」的启发式（精确→包含），文件写简称（「公基」）而库里叫全称（「公共基础知识」）时不会命中，只能靠兜底科目 + 手动批量移动；跨多个 active 考试目标时同名科目取「名字最短」那个，不确定归属时也会归兜底；⑱`import_batches` 是**只增不删**的账本（本轮没有清理/归档机制），长期使用后下拉会越来越长 —— 需要时再加「只显示最近 N 条」或过期清理，另 `batch_id` 刻意无外键，删题不会动批次行；⑲导入批次的筛选不作用于「已删除」与「已隐藏」两档（前者走 `/questions/deleted`、后者走本机快照，接口都不带批次语义），要按批次恢复题只能先切回「全部批次」再逐题看

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
