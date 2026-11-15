# 题路 TillRoad · 文档评审与修订记录（进入开发阶段前）

> 评审日期：2026-11-14 ｜ 评审对象：工作文件夹全部文档/DDL ｜ 结论：**可以进入 App 开发阶段，但不宜照原文档直接开工**
> 本文件是审查结论与「评审→修订」对照表，供后续 BE-00 / FE / QA 派工与回归时查阅。

---

## 1. 审查总结论

**可以进入 App 开发阶段。** 依据：

- 产品边界清晰且自洽：仅成人考试、不碰 K12/社交/押题；以「目标配置→能力层级→缺陷单→三次验证关闭→周期复盘」五环闭环替代刷题量；AI 全 BYOK、核心闭环不依赖 AI。
- `题路TillRoad-开发文档初稿.md` 含 15 节完整 PRD/技术设计（画像/数据模型/功能需求 AC-*/页面 IA/AI 设计/多考试模板/非功能/技术架构/API 契约/测试/MVP 范围/成功指标/假设与已决策）。
- `schema.sql` 可落库：含 14 枚举、18 表、DDL 触发器、去重哈希 `normalize_question_text`、乐观锁、接口契约附录、末尾自检 DO 块（打印 `SCHEMA_VERIFY_OK`）。
- `byok-key-lifecycle.md` / `offline-sync-spec.md` / `fe-11-audit-motion-spec.md` 三处高风险决策已拍板并交叉引用。
- `mvp-tasks.md` 有 BE/FE/AI/QA 全量任务、依赖链与 BE-00 CI 门禁。

**但不宜照原文档直接开工**：4 项 P0 硬伤全部落在 BE-00（一张表 / 一份迁移脚本），会在建表/二次执行/建单时直接失败或丢数据，必须先修；另有若干 P1 一致性问题会造成派错页、版本矛盾、安全约束缺口。

---

## 2. 环境实测（决定首个里程碑的形态）

| 工具 | 结果 |
|---|---|
| node | `C:\nvm4w\nodejs\node.exe` v24.19.0 ✅ |
| npm | `C:\nvm4w\nodejs\npm.ps1` ✅ |
| git | `D:\Program Files\Git\cmd\git.exe` ✅ |
| python | WindowsApps stub ✅ |
| **Flutter / Dart** | **NOT FOUND** ❌ |
| **psql / PostgreSQL** | **NOT FOUND** ❌ |
| **Docker** | **NOT FOUND** ❌ |
| **pnpm** | **NOT FOUND** ❌ |

结论：原技术栈（Flutter 移动端 + PostgreSQL + NestJS）**本机无法编译、无法跑迁移自检**；本机唯一可立即验证的是 Node 24 逻辑层。

据此与用户确认方向（三选一）：用户选 **A「修 P0 + 落地核心闭环」**——修订文档 + 用现有 Node 24、零第三方依赖，把与端无关的核心规则层（状态机 / 禁用语 / 三次验证 / 去重哈希 / API 骨架）做成可运行可测试代码，后续可复用到 Dart / NestJS。

---

## 3. P0 硬伤与修复（全部已落地）

| # | 硬伤 | 后果 | 修复 |
|---|---|---|---|
| P0-1 | `schema.sql` 二次执行不幂等：18 个 `CREATE TABLE`、多数 `CREATE INDEX` 无 `IF NOT EXISTS`；`trg_defect_transition` / `trg_defect_phrase` / `trg_umc_revoked` 三个 `CREATE TRIGGER` 无 `DROP IF EXISTS` | 与文件注释「可重复执行」及 BE-00 验收「二次执行幂等通过」自相矛盾，第二次跑必报 `already exists` | 所有 `CREATE TABLE` / `CREATE INDEX` 加 `IF NOT EXISTS`；三个静态 `CREATE TRIGGER` 前各加 `DROP TRIGGER IF EXISTS`；唯一索引改 `DROP INDEX IF EXISTS` + `CREATE`（兼容从 v0.2 两列索引升级且自身幂等）。动态 `trg_%_upd` 在 DO 块 `format` 内本就含 `DROP TRIGGER IF EXISTS`，无需改 |
| P0-2 | `CREATE UNIQUE INDEX idx_ver_dt_stage ON verifications(defect_ticket_id, stage)`（每阶段仅一条）| 状态机允许 `REOPENED→ANALYZED→…→V1` 多轮循环、`reopen_count` 累加、主文档要求验证时间线/重开记录；重开后无法再插 V1/V2，UPSERT 又丢历史证据 | 引入轮次维度：`defect_tickets.verification_round int NOT NULL DEFAULT 1`、`verifications.round int NOT NULL DEFAULT 1`；唯一索引改 `(defect_ticket_id, stage, round)`；`REOPENED→ANALYZED` 时触发器 `NEW.verification_round := OLD.verification_round + 1`；补 `ALTER TABLE ... ADD COLUMN IF NOT EXISTS` 兼容旧库；接口契约与末尾自检（6.2/6.3）同步校验 round 列与索引 `indexdef ILIKE '%round%'` |
| P0-3 | `defect_tickets.error_layer` / `error_cause` 为 `NOT NULL`，且 `trg_defect_phrase` 在 `INSERT OR UPDATE` 即跑禁用语正则 | 与 §4.3「DRAFT 建单未归因、仅记录错题」及 AC-DT-03「未选层级不得进入 ANALYZED」冲突，DRAFT 根本落不了库 | 两列去 `NOT NULL`（可空）；`check_defect_forbidden_phrase()` 加 `IF NEW.status='DRAFT' THEN RETURN NEW; END IF;`，并在 `NEW.status='ANALYZED'` 时强制 `error_layer/error_cause` 非空（`RAISE EXCEPTION 'MISSING_ERROR_LAYER_OR_CAUSE'`），禁用语仍拦；DB 触发器与 Node 规则层 `assertAnalyzable()` 对齐；API 契约改为两阶段建单（POST 可返 DRAFT / 带完整归因返 ANALYZED；`:analyze` 补齐归因）|
| P0-4 | `mvp-tasks.md` BE-00 CI 命令写 `psql ... -f docs/migrations/0001_init_up.sql` | 实际文件在 `migrations/0001_init_up.sql`（无 `docs/` 前缀），CI 找不到文件 | 路径改为 `migrations/0001_init_up.sql`；同时把 BE-04 验收「唯一(stage)约束」改为「唯一(stage,round)约束」 |

> 注：本机无 psql/PostgreSQL，`SCHEMA_VERIFY_OK` **无法实跑**，P0-1/2/3 仅做静态核验（`grep '^CREATE ...'` 确认 45 行 CREATE 全部幂等或前置 DROP）。BE-00 CI 门禁需在具备 PG15+ 的环境补跑。

---

## 4. P1 一致性问题与修复（全部已落地）

| # | 问题 | 修复 |
|---|---|---|
| P1-① | **FE 编号漂移**：`byok-key-lifecycle.md` §5/§6 与开发文档 15.3-③ 仍写「FE-02 审核原型 / 七态原型」，但 FE-02 = 建题/导入页，审核七态 UI 实为 **FE-11**（动效规范 v1.1 已改名说明）。照原文派工会做错页 | 全部涉及审核七态的「FE-02」更正为「FE-11」并加注「原 FE-02 为建题/导入页，勿混」；涉及 `byok-key-lifecycle.md`（升 v1.2）、`题路TillRoad-开发文档初稿.md`（15.3 闭合依据、风险段、文末路线）。保留 mvp-tasks.md / fe-11-audit-motion-spec.md 中合法的「FE-02=建题/导入页」「改名说明」 |
| P1-② | 开发文档页首标 v0.2、文末标 v0.5，版本号矛盾 | 页首统一为 `v0.5（基于决策更新 + 评审修订）`，文末保持 v0.5 |
| P1-③ | §9 允许 DEK 明文缓存 5min，但场景 4 要求 `revoked` 立即停调，未写「撤销时清除该用户 DEK 缓存」 | 开发文档 §9、`byok-key-lifecycle.md` §5.1 均补「`status='revoked'` 时立即清除该用户 DEK 缓存（LRU 中按 user_id 失效）」，否则缓存窗口内仍可用旧 DEK 解密 |
| P1-④ | `offline-sync-spec.md` / BE-00 多次引用客户端表 `flutter/local_ai_task_queue.dart`，但该目录/文件尚不存在（FE-09 待建产物） | `offline-sync-spec.md`（升 v1.2）、`mvp-tasks.md` BE-00 明确标注为「FE-09 待建产物，本仓尚未创建」，避免评审/派工误以为已交付 |

附带一致性修正 1：`schema.sql` 附录 `POST /defect-tickets` 契约原写 `201 {status:"ANALYZED"}`（单阶段），与 P0-3 的 DRAFT 两阶段语义漂移 → 改为两阶段契约；开发文档 §11 同步补两阶段校验说明。

附带一致性修正 2（交付前静态核验发现，避免「规则层与契约零漂移」前提被破坏）：`analyze` 补归因端点与 `/verifications` 路径在「文档 vs server 骨架」间存在方法/错误码/路径三重漂移——PRD §11 与 schema.sql 附录为 `POST /defect-tickets/{id}:analyze` + `400 {error:"missing_error_layer_or_cause"}` + `POST /verifications`，而初版 server 写成 `PATCH /:id/analyze` + 自造错误码 `missing_analysis` + 仅有嵌套路径 `/defect-tickets/:id/verifications`。以文档为权威收敛：
- `analyze` 规范方法定为 `POST`（URL 用斜杠式 `/analyze`，与 server 路由分段一致；冒号式仅见注释叙述）；`PATCH` 保留为兼容别名，不破坏已有调用。
- 缺归因错误码统一 `missing_error_layer_or_cause`（对齐 schema.sql 触发器 `MISSING_ERROR_LAYER_OR_CAUSE`），废弃 `missing_analysis`。
- `POST /verifications`（带 `defect_ticket_id`）补为规范路径，内部委托给嵌套路径；`POST /defect-tickets/:id/verifications` 保留为等价别名。
- 新增回归测试「规范契约：POST /analyze + POST /verifications 可用，PATCH /analyze 为兼容别名」，全量 `node --test` 30/30 通过（14 core + 16 server）。
- 文档同步：开发文档 §11 / schema.sql 附录 / README §5 统一路径、方法与错误码；schema.sql 附录另标注 `POST /verifications` 为规范路径、Node 骨架返回 201 为目标 200 的过渡。
---

## 5. 修订后文件版本对照

| 文件 | 修订前 | 修订后 |
|---|---|---|
| `schema.sql` | v0.2-schema1 | **v0.3-schema1**（P0-1/2/3 + 接口契约 + 自检） |
| `mvp-tasks.md` | v0.2 | **v0.3**（P0-2/P0-4 对齐 + P1-④） |
| `题路TillRoad-开发文档初稿.md` | 页首 v0.2 / 文末 v0.5 | **v0.5 统一**（版本号 + P1-①③ + §11 两阶段） |
| `byok-key-lifecycle.md` | v1.1 | **v1.2**（FE-11 编号 + DEK 撤销清缓存） |
| `offline-sync-spec.md` | v1.1 | **v1.2**（标注 flutter/ 为待建产物） |
| `fe-11-audit-motion-spec.md` | v1.1 | 未改（内容正确，仅作为 FE-11 编号依据） |
| `migrations/0001_init_up.sql` | `\ir ../schema.sql` | 未改（单一事实来源 = schema.sql） |
| `migrations/0001_init_down.sql` | DROP 全表/函数/类型 | 未改（幂等 down，与 up 对称） |

---

## 6. 首个可验证里程碑（方向 A 已交付的代码）

零第三方依赖、端无关，仅 `import node:crypto`：

- `core/index.mjs` — 核心规则层：状态机 `TRANSITIONS` + `assertTransition`（`ILLEGAL_DEFECT_TRANSITION`）、禁用语 `FORBIDDEN_PHRASES` + `assertAnalyzable`（`MISSING_ERROR_LAYER` / `MISSING_ERROR_CAUSE` / `FORBIDDEN_PHRASE_IN_ERROR_CAUSE`）、三次验证 `applyVerification`（fail→REOPENED+reopen_count+1、连续重开≥3 提示抽验，V1→V2→V3→CLOSED）、`beginVerification` / `reanalyze`（轮次 +1，对齐 P0-2）、`isSimilarQuestion`（同 knowledge_node_id+error_layer+题型且未作答）、`normalizeQuestionText`（全角/顿号归一+去空白+sha256）、`computePriority`、`validateAIGenerateRequest`（count 1–20 / provider 锁死 / openai_compatible 必填 https base_url / SSRF 拦截）。
- `core/index.test.mjs` — 14 个 `node:test` 用例；`server/index.test.mjs` — 16 个集成测试（`node:test` + 内置 fetch，真实监听 0 端口，每例独立 `createApp`）。全量 `node --test core/*.test.mjs server/*.test.mjs` 实测 **30 pass / 0 fail**（交付前复跑）。
- `server/` — HTTP API 骨架（队友 api-dev 实现，Node 原生 http + 内存 Map 存储，零第三方依赖）：导出 `createApp()` / `createServer` 工厂，支持 `node server/index.mjs` 直接启动（PORT 或 3000）；10 组端点 + 乐观锁 409 + 统一错误映射；验证记录带 round、AI job 自持 provider/model 快照、DRAFT 两阶段建单。见 `README.md §5`。
- `package.json` — `type: module`，`engines: node>=20`，scripts `test / test:core / test:server / start`。

> 为何这样切：本机无 Flutter、无 PostgreSQL，把「与端无关的核心闭环规则」抽成纯 JS 层，既能在当前环境立即可验证（首个里程碑），又与 `schema.sql` 的触发器/约束/去重/状态机严格对齐、契约零漂移，后续可直接移植到 Dart（FE）或 NestJS（BE）。

---

## 7. 后续建议顺序

1. **BE-00**：在具备 PG15+ 的环境执行 `psql -v ON_ERROR_STOP=1 -f migrations/0001_init_up.sql`，确认打印 `SCHEMA_VERIFY_OK`、二次执行幂等、`normalize_question_text` 冒烟、6.2/6.3 轮次自检通过。（本机缺 psql，未实跑）
2. **BE-01 → BE-03 / BE-04**：目标配置 → 缺陷单状态机 → 三次验证，按修订后的两阶段建单（POST /analyze）+ (stage,round) 轮次约束落地；把内存 Map 替换为 PG 仓储，规则层复用 `core/`。
3. **FE-09 / BE-08**：按 `offline-sync-spec.md` v1.2 落地 `flutter/local_ai_task_queue.dart`（当前仓尚不存在）。
4. **FE-11**：按 `fe-11-audit-motion-spec.md` 画七态原型（注意是 FE-11，不是 FE-02）。
5. 补 Flutter SDK + PG/Docker 工具链后，把 `core/` 规则移植到 Dart / 接入 NestJS，跑全栈集成与 QA-01~06。
