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

---

## 8. BE-01 已知缺口（随实现记录，非文档修订）

- **四张表无业务唯一约束**：`exam_profiles` / `subjects` / `knowledge_nodes` / `capability_layers` 在 `schema.sql` 上只有主键 + 非唯一索引，没有「同 exam_profile 下 subject.name 不重复」「同 parent 下 knowledge_node.title 不重复」等业务唯一约束。`schema.sql` 已冻结（BE-00 已归档，CI 绿），**MVP 阶段不夹带改 schema 加 UNIQUE**；改由**仓储层在同一事务内显式查重**（`SELECT … FOR UPDATE` / 查重）实现，并以集成测试覆盖并发竞态窗口。**见 BE-01 第 3 步**。若将来要 DB 级唯一，须独立 schema issue + 独立 PR。
- **闭环（BE-01 第 3 步）**：已按上述方案在 `server/repositories/` 实现同事务查重，不再依赖 DB 唯一约束：
  - `exam_profiles`：同 `user_id` 下 `target_label`，创建/改名时先 `lockParentRow(client,'users',userId)` 锁父行再查重；空标签不查重。
  - `subjects`：同 `exam_profile_id` 下 `name`，先锁 `exam_profiles` 父行；只在 patch 含 `name` 时才加锁+查重。
  - `knowledge_nodes`：同 `subject_id` + 同 `parent_id` 下 `title`，用 `parent_id IS NOT DISTINCT FROM $2`（NULL 安全）；移动节点时按「生效后的 `parent_id`」查重。
  - `capability_layers`：不查重（共享模板，名称允许重名），只走 `customizable` gate。
  - 冲突统一 `409 { error:'conflict', field, current, incoming, resolution:'user_choice' }`（与乐观锁的 `client_merge` 区分）。
  - **竞态窗口由集成测试覆盖**：`repositories.integration.test.mjs` 有 2 条并发用例（两个真提交的 client，第二条断言在第一条提交前未完成，证明 `FOR UPDATE` 真的阻塞）；这些用例在 CI 的 PG15 容器里跑，本机跳过。
- 本轮（BE-01 第 1 步）仅新增 `core/validators.mjs`（V1–V12 纯校验函数）与 `core/validators.test.mjs`，未引入 `pg`、未改 `package.json`、未动 `server/` 与冻结的 `schema.sql`；`npm test` 仅验证纯函数逻辑，本机无 PostgreSQL，未实跑 PG。

---

## 9. BE-02 前评估（待办，不夹带改代码）

- **`validateAIGenerateRequest` 返回形状是否统一为扁平形**：`core/index.mjs` 的 `validateAIGenerateRequest()` 返回 `{ ok:false, error:{ code, message } }`（嵌套形）；`core/validators.mjs`（BE-01 第 1 步新增）与 `server/repositories/base.mjs` 的 `mapPgError()` 等新代码统一用 `{ ok:false, code, message }` / 带 `.code` 的扁平形。HTTP 层目前用 `r.error?.code ?? r.code` 兼容两种形状。**待 BE-02（AI 生成接入）前决定**：是否把 `validateAIGenerateRequest` 也改成扁平形以消除分叉；若改，须同步 `server/routes/defect_tickets.mjs` 的调用处与 `core/index.test.mjs` 断言，并作为独立改动（不夹带在 BE-01 第 2/3/4 步）。本轮不动 `core/index.mjs`。

---

## 10. BE-01 第 4 步（路由层拆分 + AC-KM-01/02 事务）

完成状态（本轮新增/修改）：

- **新增 `core/templates.mjs` + `core/templates.test.mjs`**（纯数据，不 import `pg`、不 import `server/`）：`TEMPLATE_VERSION='tpl-1'`，5 个 `exam_type` 各一套默认科目（civil_service 6 / postgrad 4 / final_exam 3 / vocational 2 / adult_self_study 3），`getTemplateSubjects(examType)` 未知类型返回 `[]` 不报错。**踩坑**：`Object.freeze` 的模板对象直接索引会命中原型链（`TEMPLATES['constructor']` → `tpl.map is not a function`），已用 `hasOwnProperty` 守卫。
- **新增 `server/routes/`**（6 个文件 + 挂载器）：`_http.mjs`（唯一 HTTP 出口：`ok`/`fail`/`assertValid`/`readBaseVersion`/`httpError`/`readBody`/`pagination`）、`exam_profiles.mjs`、`subjects.mjs`、`knowledge_nodes.mjs`、`capability_layers.mjs`、`defect_tickets.mjs`、`index.mjs`（`dispatch()` 先给 `GET /health`，再按 `ROUTE_MODULES` 顺序问各 `match()`）。
- **`server/index.mjs` 瘦身 452 → 约 150 行**：只做 HTTP server + `pool`/`state` 注入 + 交给 `dispatch()` + 404/异常映射；四表端点已全部走 `server/repositories/` 真 PG。
- **`base_version` 强制**：`_http.readBaseVersion(body)` 只认 body 的 `version`（刻意不支持 `If-Match`），缺失或非正整数 → `400 { error:'INVALID_BASE_VERSION' }`。仅覆盖已接 PG 的四张表。
- **三处事务编排**：AC-KM-01（`POST /exam-profiles` → profile + 模板科目）、AC-KM-02（`POST /subjects/:id/customize-layers` → 副本模板 + 重指向）、级联软删（`DELETE /exam-profiles/:id` → profile + 两条批量 `UPDATE`），全部用 `withTransaction`，未用 `pool.query` 拼多条。
- **测试改造**：`server/index.test.mjs` 重写为 fake 层 29 条（不连 PG，验证路由分发 / 入参解析 / `base_version` 400 / 409 两种形状）；新增 `server/index.integration.test.mjs` 10 条（真 PG，`RUN_PG_INTEGRATION=1` 才跑）。`repositories.integration.test.mjs` 的 `before()` 同步改为 `withTransaction` 包 `schema.sql`（失败整笔回滚，不留半个 schema）。
- **`capability_layers.archive` 受 gate 拦截 —— 刻意加严，非遗漏**：`customizable=false` 的共享模板连软删也拒绝（`400 CUSTOMIZABLE_LOCKED`）。理由：软删后 `list` 查不到、但别人的 `subject` 仍指向它，比「不能改」更强的保护是必要的。决策 6 明确保留该行为。
- **缺陷单等内存端点未强制 `base_version`**：决策 8 的强制范围仅限第 3 步已接 PG 的四张表；缺陷单仍在内存 Map，BE-03 重写到 PG 时一并统一（现在改会让 9 条状态机测试无谓失效，且还得改第二遍）。
- **验证**：`npm test` → `tests 133 / pass 91 / fail 0 / skipped 42`（42 = 4 smoke + 28 仓储集成 + 10 路由集成，本机全跳过）；本机无 PostgreSQL，**PG 侧的真跑全部留给 CI**。
- **仍未统一的具体事项**：`validateAIGenerateRequest` 的嵌套返回形（见 §9）。

---

## 11. BE-01 第 3 步 CI 失败修复（8 fail → 4 类根因）

CI `node-tests` 首跑：`106 tests / 98 pass / 8 fail / 0 skipped`。逐类定位与修复：

- **A（5 条 capability_layers）jsonb 参数被当成 PG 数组**：报错 `invalid input syntax for type json` / `Expected ":", but found ","`（22P02）。根因**不是**"手动 stringify 后又处理一次"（仓储层从未调用 `JSON.stringify`，`grep` 已证），而是 `pg/lib/utils.js` 的 `prepareValue()` 先判 `Array.isArray(val)`：JS 数组 → PG **数组**字面量 `{"{\"order\":1}"}`，JSON 解析必失败；JS 对象才会走 `JSON.stringify`；JS 字符串原样下发。**必须自己序列化数组**。修：`server/repositories/_common.mjs` 新增 `JSONB_COLUMNS`（覆盖 schema 全部 8 张表 15 个 jsonb 列）/`isJsonbColumn`/`toJsonbParam`，并在 `insertRow` 与 `updateWithVersion` 对 jsonb 列统一处理（字符串不二次序列化，null/undefined 原样）。新增 `server/repositories/_common.test.mjs` 7 条 fake 单测锁死行为。
- **B（1 条 exam_profiles.update）时间戳断言错**：`inRollback` 把 create 与 update 放同一事务，PG 的 `now()` 在事务内恒定 → `updated_at` 必然等于 `created_at`。不是乐观锁失效，是断言写错。修：改断言为 `version === created.version + 1` + 字段变化 + `updated_at >= created_at` 非严格单调。
- **C（1 条 getTree）排序依赖随机 uuid**：两根节点同事务创建 → `created_at` 相同 → 退化为 `id`（`gen_random_uuid()` 随机）。修：断言改为「集合正确 + 排序键单调（`created_at` 不降，相等时 `id` 升序）」，并用 id 建 Map 定位节点而非下标。理由：手动 `UPDATE created_at` 要额外写权限与清理，且会掩盖"排序键是否正确"这个真正要验的点。
- **D（1 条 knowledge_nodes.update）实现缺口**：原查重只在 `patch` 含 `title` 时执行，"只移动不改名"会漏检。修：`update` 的查重条件改为 `renames || movesParent`，用"生效后的 `parent_id` + 生效后的 `title`"在同 `subject_id` 下查重（排除自身）；移动路径上方已 `lockParentRow(subjects)`，查重块内不重复加锁。新增 2 条集成测试："移动撞新父下同名 → 409"（并补反向对照"移到无同名父下成功"）、"跨科目移动 → 400 `parent_subject_mismatch`"。
- **第 5 项（before 包事务）**：BE-01 第 4 步（T7）已完成，本轮跳过，`before()` 现状为 `withTransaction(pool, client => client.query(SCHEMA_SQL))`。
- **验证**：`npm test` → `tests 141 / pass 98 / fail 0 / skipped 43`。明细：98 pass = core/index 14 + templates 4 + validators 15 + server/index(fake) 29 + pool 9 + base 20 + `_common` 7（新增）；43 skip = pg-smoke 4 + 仓储集成 29（原 28，D 新增 1 条）+ 路由集成 10。本机无 PostgreSQL，**8 条原失败集成用例只有 CI 能转红为绿**。
- **未变的约束**：未改 `schema.sql` / `core/index.mjs` / `core/validators.mjs` / `server/db/pool.mjs` / `server/repositories/base.mjs`（A 的修复定位在 `_common.mjs`，未触 `buildUpdateSet`）。

---

## 12. BE-01 第 4 步 CI 失败修复（1 fail：40P01 死锁 + SQLSTATE 被降成 400）

推送后 CI：`141 tests / 140 pass / 1 fail / 0 skipped`。上轮 8 条全绿，**剩下的这 1 条属于第 4 步**（`server/index.integration.test.mjs`，本轮修复未触碰该文件）。

### 两个问题（按严重度排序，第二个更隐蔽）

1. **测试基础设施：三个 PG 集成文件并行跑同一个库**
   - 现象：`级联软删：DELETE /exam-profiles/:id ...` 在**建单**一步返回 400 `{"error":"40P01"}`，耗时 1006.9ms（≈ PG 默认 `deadlock_timeout` 1s）。
   - 机制：`node --test` 默认按核数并行跑测试**文件**（本机 16 核）。仓储层「并发竞态: B 在 A 持锁期间阻塞」故意让一个事务持锁 200ms，而路由层建单走 `lockParentRow(users FOR UPDATE)` —— 两个文件跨连接抢同一行，PG 判定死锁并牺牲一方。宿主机核数决定是否复现，属于典型 flaky。
   - 修：`package.json` 的 `test` / `test:server` / `test:integration` 全部加 `--test-concurrency=1`（串行）。单测仍可用 `npm run test:core` 并行。
2. **`httpError` 把 PG SQLSTATE 当成客户端错误**（真正的代码缺陷，非测试问题）
   - 现象：响应体直接是 `{"error":"40P01"}` 且 status=400 —— 底层数据库码泄漏给客户端，且把服务端并发故障伪装成用户输入错。
   - 机制：`server/routes/_http.mjs` 的 `httpError` 第二段是 `if (e.code) return 400 {error:e.code}`，而 pg 把 SQLSTATE 放在 `err.code`。
   - 影响：同类的 `40001 serialization_failure`、`08xxx` 连接错误同样会被当 400；客户端会误以为该改参数，而实际应该重试。
   - 修：`httpError` 新增前置判定 `isPgSqlState(code)` = `/^[0-9A-Z]{5}$/`，命中则一律 `500 {error:'internal'}`（不泄漏 SQLSTATE）；应用层业务码（`INVALID_VERIFICATION_STAGE` 等长串）不受影响；`mapPgError` 映射过的错误因带 `statusCode`+`body` 仍走第一分支（404/409/400）。

### 验证

- `npm test` → `tests 142 / pass 99 / fail 0 / skipped 43`（新增 1 条 `httpError：PG SQLSTATE 一律 500`）。
- 该新测试覆盖：`40P01` → 500；`40001` → 500；`08006` → 500；带 `sqlState:'23503'` 且有 `statusCode:404` 的已映射错误仍 404；`INVALID_VERIFICATION_STAGE` 仍 400。
- **仍未能本机验证死锁是否真消失**（本机无 PG），只能由 CI 的 `RUN_PG_INTEGRATION=1` 验证；但串行化消除了跨文件锁竞争的成因。

### 教训

- 「先分清是哪个文件的失败」比直接看报错更重要：`logs` 里 `server/index.integration.test.mjs` 与 `server/repositories/*` 是两批改动，混在一起排查会误改已修好的代码。
- 测试依赖机器核数 = flaky。共用同一数据库的集成测试必须显式串行。
- 错误码分层：「5 位大写 SQLSTATE」是**基础设施层**，「小写/下划线业务码」是**应用层**，不能共用同一个映射分支。

---

## 13. BE-01 第 4 步收尾自查（三件）与补缺口

按用户要求先做三件自查再动手。

### 1. CI 状态

- 代码已推送：`git ls-remote origin HEAD` = `c9a8704a27281f804bec1c36bef6a5b076698723`，与本地 HEAD 一致。
- **CI 结论无法由本机代查**：GitHub API 返回 `403 rate limit exceeded`，网页 `fetch failed`。上轮的 40P01 修复已入库，但「是否全绿」需要用户确认。

### 2. base_version 强制覆盖（grep `server/routes/`）

| 端点 | 方法 | 强制 |
|---|---|---|
| `/exam-profiles/:id` | PATCH、DELETE | ✅ |
| `/subjects/:id` | PATCH、DELETE | ✅ |
| `/knowledge-nodes/:id` | PATCH、PUT、DELETE | ✅ |
| `/capability-layers/:id` | PATCH、DELETE | ✅ |
| `/defect-tickets/:id` 及其 analyze | PATCH | ❌ 刻意不强制（内存 Map，BE-03 统一） |

### 3. 三处事务边界（逐一核实，非仅看代码存在）

| 场景 | 位置 | 结论 |
|---|---|---|
| AC-KM-01 建 profile + 批量 subjects | `exam_profiles.mjs:106` | ✅ 整段在 `withTransaction` 内 |
| AC-KM-02 customize-layers | `subjects.mjs:116` | ✅ 建副本 + 重指向同事务 |
| 级联软删 | `exam_profiles.mjs:219` | ✅ 三步批量 UPDATE 同事务 |
| **PATCH /exam-profiles/:id** | `exam_profiles.mjs:207` | ❌ **发现缺口**（详见下） |

### 找出的真实缺口：PATCH /exam-profiles/:id 未包事务

- 原实现 `return ok(await rep.update(pool, id, patch, baseVersion));` —— 直接传 `pool`。
- 后果：`exam_profiles.update` 在 patch 含 `target_label` 时会先 `lockParentRow(users)` 再 `findLabelConflict`。脱离事务时 `FOR UPDATE` 的锁在**语句自动提交后立刻释放**，查重与写入落在两个快照里，两个并发改名会**双双通过查重**，同一 user 下出现重复 `target_label`。
- 同库 `capability_layers.mjs:89` 的 PATCH 是包事务的，两处不一致说明这是遗漏而非设计。
- 修：`withTransaction(pool, (client) => rep.update(client, id, patch, baseVersion))`。
- 新增集成测试：`PATCH /exam-profiles：同一 user 下两个 profile 并发改成同一 target_label -> 恰好一个成功一个 409`（`Promise.all` 双发，断言状态码集合为 `[200,409]` 且 409 带 `resolution:'user_choice'`、`field:'target_label'`）。若不包事务，此测试会得到 `[200,200]`。
- 验证：`npm test` → `tests 143 / pass 99 / fail 0 / skipped 44`（44 = 4 smoke + 29 仓储 + 11 路由集成）。

---

## 14. BE-02（题目导入管线 + questions/assets 仓储）

完成状态：

- **新增运行时依赖 `pdfjs-dist@6.5.438`**（`package.json` 已显式声明，`package-lock.json` 锁定，CI 用 `npm ci`）。这是继 `pg` 之后第二个运行时依赖。
  - **必须用 `pdfjs-dist/legacy/build/pdf.mjs` 导入**：包的 `main` 指向 `build/pdf.mjs`、无 `exports` map、无 `type` 字段，裸 import 在 Node ESM 下会走现代构建（依赖 DOM），只有 legacy 构建在 Node 下可用（实测 61ms 导入成功）。
  - `destroy()` 在 **loadingTask** 上，不在 document 上（`doc.destroy is not a function`）。代码里用 `try { await task.destroy(); } catch {}` 兜住。
  - stderr 会打 3 条无害告警（`Cannot load "@napi-rs/canvas"`、`Cannot polyfill 'DOMMatrix'`、`Cannot polyfill 'Path2D'`）—— 只抽文本不渲染，可忽略，**不要把它们当成测试失败**。
  - PDF 断行必须靠 `getTextContent()` 每个 item 上的 `hasEOL`，否则整页会被拼成一行，行首题号判断全部失效。
- **新增 `server/import/`**（6 个模块 + 3 个测试）：`splitter.mjs`（纯函数零依赖，四类分隔符规则切题）、`extract.mjs`（mime 分派 + 体积/页数上限）、`xlsx.mjs`（手写最小 xlsx 读取，仅 `node:zlib`）、`dedupe.mjs`（按 `content_hash` 一次 `= ANY($1)` 查重）、`separate.mjs`（第四阶段：图片占位识别，MVP 不落库）、`splitter.test.mjs`（8 条）、`separate.test.mjs`（8 条）、`import.integration.test.mjs`（7 条）。
- **新增 `server/repositories/questions.mjs` / `assets.mjs`**（与四表同形：首参 `client`、乐观锁、软删）。`questions` 在 `create` 前按 `content_hash` 查重（命中 → `409 DUPLICATE_QUESTION`，body 含 `current` 行）；`update` 只要 patch 触及 `stem`/`options`/`formula_text` 就重算 hash 并排除自身查重。`assets` 有 `version` 列但**刻意不走乐观锁**（归档只需 `deleted_at`）。
- **新增 `server/routes/questions_import.mjs`**（`POST /questions/import` + 别名 `/questions-import`），已挂入 `ROUTE_MODULES` 末尾。整段导入包在 `withTransaction` 内；逐题 `create` 遇到 `DUPLICATE_QUESTION` 转为 `duplicates`（标 `raced:true`）继续，其它错误整批回滚。
- **新增 `tests/fixtures/questions/`**：`sample-01-markdown.md`（12 题）、`sample-02-plain.txt`（10 题）、`sample-03-pdf-extracted.txt`（12 题，模拟 PDF 抽取后的碎换行）、`make-fixtures.mjs`（手写 PDF 1.4 生成器）+ `text-simple.pdf`（3 题，ASCII）、`scanned-no-text.pdf`（无文本层，用于 422 断言）。三份文本样本切题 `accuracy = 1`。

### 三个设计取舍（都已在 README 写明）

1. **同步导入 + 体积硬上限**（单文件 10MB / PDF 100 页 / 图片 20 张），超限 `413 PAYLOAD_TOO_LARGE`。`schema.sql` 无通用导入任务表，复用 `ai_generation_jobs` 语义不符，新增表又违反 schema 冻结 —— 故 `import_jobs` 放 V1 独立 schema issue。上限比开发文档的 50MB/200 页更严，因为同步请求没有任务表兜长任务。
2. **只做规则切题，不上 AI**。分隔符四类：`1.` / `1、`、`（1）`、`一、`、`第1题`。已知局限：题干内部的编号列表会被误判成新题起点 —— 这条已写成 `splitter.test.mjs` 的基线测试（若将来修复，该测试会先红，强制更新 README 与测试）。
3. **端点只收 JSON + base64，不实现 multipart**。Node 原生无 multipart 解析器，引 `busboy`/`formidable` 会打破「运行时依赖只保留 `pg` + `pdfjs-dist`」；导入是低频操作，base64 的 +33% 体积在 10MB 内可接受。multipart 与 `import_jobs` 一起放 V1。

### 本轮修正的两个实测问题

- **样本声明题数与实际不符**：首轮实测 sample-01 只切出 11 题（声明 12）、sample-02 只切出 9 题（声明 10）。原因是样本本身漏题，不是 splitter 缺陷 —— 已补齐样本。教训：**先跑探针核对真实题数，再把数字写死进断言**。
- **手写 PDF 不能放中文**：base-14 Helvetica 只有 WinAnsi 字形集，没有中日韩字形。`text-simple.pdf` 改成 3 道纯 ASCII 题；中文场景一律用文本文件模拟「PDF 抽取结果」（即 `sample-03-pdf-extracted.txt`）。

### 验证

- `npm test` → `tests 166 / pass 115 / fail 0 / skipped 51`。
  - 通过：`core/index` 14 + `core/templates` 4 + `core/validators` 15 + `server/index`(fake) 30 + `server/db/pool` 9 + `server/repositories/base` 20 + `_common` 7 + `server/import/splitter` 8 + `server/import/separate` 8 = 115。
  - 跳过（本机无 PG）：smoke 4 + 仓储集成 29 + 路由集成 11 + 导入集成 7 = 51。
- `node --check` 全部 12 个新模块通过。
- `git status --short`：`M package.json` / `M package-lock.json` / `M README.md` / `M REVIEW-NOTES.md` / `M server/routes/index.mjs` / `M server/index.integration.test.mjs` / `M server/routes/exam_profiles.mjs` / `?? server/import/` / `?? server/repositories/questions.mjs` / `?? server/repositories/assets.mjs` / `?? server/routes/questions_import.mjs` / `?? tests/`。**未改 `schema.sql`、`core/index.mjs`、`core/validators.mjs`、`server/db/pool.mjs`、`server/repositories/base.mjs`、四表仓储。**

### V1 待补

- 图片 OCR（`422 UNSUPPORTED_IMAGE` 的替代实现）。
- 题干图片的实际分离（`separate.mjs` 本轮只识别占位并计入 `stats.image_placeholders`，`asset_refs` 恒为空）。
- `import_jobs` 异步任务表 + multipart 上传。
- AI 切题（替换规则切题的已知局限）。

