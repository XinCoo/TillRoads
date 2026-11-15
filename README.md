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
├── core/                      # 端无关核心规则层（零第三方依赖，纯 JS）
│   ├── index.mjs              #   状态机 / 禁用语 / 三次验证 / 去重哈希 / 优先级 / BYOK 校验
│   └── index.test.mjs         #   14 个 node:test 用例
├── server/                    # HTTP API 骨架（Node 原生 http，内存存储，可替换为 NestJS+PG）
│   ├── index.mjs              #   路由 + 服务（import core/）
│   └── index.test.mjs         #   集成测试
├── migrations/                # PG 迁移入口
├── schema.sql                 # 数据库单一事实来源
├── *.md                       # 设计 / 决策 / 评审文档
├── package.json               # scripts: test / test:core / test:server / start
└── REVIEW-NOTES.md / README.md
```

> 设计取舍：本机无 Flutter SDK、无 PostgreSQL/Docker，故把「与端无关的核心闭环规则」抽成纯 JS 层，当前环境即可验证，且与 `schema.sql` 的触发器/约束/去重/状态机严格对齐、契约零漂移；后续可直接移植到 Dart（FE）或 NestJS（BE）。

---

## 3. 快速开始

环境要求：**Node.js ≥ 20**（本机实测 v24.19.0）。零第三方依赖，无需 `npm install`。

```bash
# 跑全部测试（core 规则层 + server 集成）
npm test

# 只跑核心规则层 / 只跑 API 集成
npm run test:core
npm run test:server

# 启动 HTTP API（默认 http://127.0.0.1:3000，可用 PORT 覆盖）
npm start
```

数据库（需 PG15+，本机未安装，故 CI 门禁需在具备 PG 的环境补跑）：

```bash
psql -v ON_ERROR_STOP=1 -f migrations/0001_init_up.sql   # 打印 SCHEMA_VERIFY_OK 即通过
psql -v ON_ERROR_STOP=1 -f migrations/0001_init_down.sql # 回滚
```

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

---

## 5. HTTP API（server/index.mjs）

| 方法 & 路径 | 说明 |
|---|---|
| `GET /health` | 健康检查 |
| `POST /exam-profiles` | 目标配置 |
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
>
> server 使用内存存储，仅作契约骨架；接 NestJS + PostgreSQL 时把数据访问层替换为真实仓储即可，规则层复用 `core/`。

---

## 6. 当前里程碑与后续

- ✅ 文档评审 + 4 项 P0 / 4 项 P1 修订（详见 [REVIEW-NOTES.md](<REVIEW-NOTES.md>)）
- ✅ `core/` 端无关核心规则层 + 14 个单元测试
- ✅ `server/` HTTP API 骨架 + 集成测试
- ⏳ BE-00：在 PG15+ 环境实跑迁移自检（本机无 psql，仅静态核验）
- ⏳ BE-01 → BE-03 / BE-04 → FE-09 / BE-08 → FE-11 → 补 Flutter/PG 工具链后移植 Dart / 接入 NestJS

详细顺序见 [REVIEW-NOTES.md §7](<REVIEW-NOTES.md>) 与 [mvp-tasks.md](<mvp-tasks.md>)。
