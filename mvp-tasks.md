# 题路 TillRoad · MVP 任务拆分（v0.3）

> 配套: 开发文档初稿.md + schema.sql。任务粒度在 schema 冻结后稳定。
> v0.3 修订（评审后）：对齐 schema.sql v0.3-schema1 的验证轮次(round)与 DRAFT 语义；修正 BE-00 CI 迁移路径；详见 `REVIEW-NOTES.md`。
> 分组: FE(Flutter 前端) / BE(后端 Node/NestJS+PG) / AI(用户 BYOK 模型集成) / QA(测试)
> 依赖符号: → 表示“依赖于”。优先级 P0(必须)/P1(重要)/P2(可后置)。

## 依赖总览（关键链路）
```
schema.sql(BE-00)  →  BE 全部
BE-01 目标配置      →  FE-01
BE-02 题目导入管线  →  FE-02 / AI-01
BE-03 缺陷单+状态机 →  FE-03 / FE-04
BE-04 三次验证      →  FE-04
BE-05 模考分析      →  FE-05
BE-06 复盘统计      →  FE-06
AI-01 归因/题型     →  FE-03(建议填充)
AI-05 BYOK 密钥     →  FE-10(设置页) / BE 加密存储
BE-10 题库AI生成    →  BE-02, AI-05(依赖用户 BYOK 配置)
QA 全程 → 各 BE/FE 验收
```

## 后端 BE（NestJS + PostgreSQL）
| ID | 任务 | 依赖 | 优先级 | 验收要点（引用） |
|---|---|---|---|---|
| BE-00 | 建表与迁移：执行 schema.sql（含枚举/触发器/函数/验证SQL）；`user_model_credentials` 按 BYOK 信封加密字段建（provider 枚举锁死、status 四态、consecutive_failures/cooldown_until）；`ai_generation_jobs` 按「任务态与凭证态分离」建（status 不含凭证态 + credential_status + client_task_id）；落 `migrations/0001_init_up.sql`(源 schema.sql) 与 `0001_init_down.sql`(回滚)；`defect_tickets.verification_round` + `verifications.round` 使重开后可重新走 V1/V2/V3 且保留历史；客户端 `local_ai_task_queue`/`local_credential_cache`（Drift+sqflite，见 flutter/，为 FE-09 待建产物） | — | P0 | **CI 验收前置（不通过不进 BE-01）**：`psql -v ON_ERROR_STOP=1 -f migrations/0001_init_up.sql` 打印 `SCHEMA_VERIFY_OK`；二次执行幂等通过（v0.3 全部 CREATE 幂等）；`normalize_question_text` 冒烟测试通过；表存在+枚举正确+触发器生效+乐观锁字段；DRAFT 建单未归因可落库、转 ANALYZED 时强制归因与禁用语；客户端表不含任何密钥字段；迁移可上可下 |
| BE-01 | 考试目标与约束 CRUD（exam_profiles/subjects/knowledge_nodes/capability_layers） | BE-00 | P0 | AC-EXAM-01~04；枚举不含 K12 |
| BE-02 | 题目导入管线：OCR→抽取→切题→`content_hash`去重→Asset 分离→写入 questions | BE-00 | P0 | AC-Q-01/02；体积上限与排队（见 15.3-3） |
| BE-03 | 缺陷单创建/详情/列表 + 状态机 API（含禁用语拦截、优先级计算） | BE-00,BE-01 | P0 | AC-DT-01~03；触发器拒绝非法迁移/禁用语 |
| BE-04 | 三次验证提交 API（verifications），状态迁移与重开 | BE-03 | P0 | AC-VER-01~05；唯一(stage,round)约束——重开(REOPENED→ANALYZED)后 verification_round+1，新 round 可重新提交且保留历史验证证据 |
| BE-05 | 限时模考 + 报告生成（module_accuracy/用时/稳定性/重复错率） | BE-00 | P0 | AC-MOCK-01~03 |
| BE-06 | 日/周/月复盘统计接口（open_defects/layer_dist/verify_pass_rate） | BE-03,BE-04 | P1 | AC-REV-01~03；对齐 GET /review-cycles |
| BE-07 | 主观题要点库 CRUD（subjective_rubric_points，维度表+要点列表） | BE-00 | P1 | 15.3-2 决策；供 AI 比对 |
| BE-08 | 同步服务：增量拉取/推送 + 乐观锁冲突 409 + 软删除下发；**AI 任务不在设备缓存明文密钥**，离线挂起(pending_online)，联网后由后端用用户 BYOK 密钥执行；联网后先同步非 AI 数据、再逐条执行挂起 AI 任务（单条失败隔离，不雪崩） | BE-00 | P1 | AC-DATA-02；严格按 `offline-sync-spec.md`（先非AI后AI、逐条隔离、cooldown/revoked 跳过） |
| BE-09 | 通知与计划生成（验证窗口临期提醒，≤2条/日） | BE-03,BE-04 | P1 | AC-PLAN-01/02；通知节制 |
| BE-10 | 题库 AI 生成与审核队列：借鉴 PrepDojo「生成→结构化→验证→入库」管线，入库前加用户确认审核环节；写入 questions(source='ai_generated', generation_meta 含 model/prompt_version/review_status)；审核队列 UI 见 FE-11，动效见 `fe-11-audit-motion-spec.md`；任务实体用 `ai_generation_jobs`(schema)，离线挂起见 `offline-sync-spec.md` | BE-02,AI-05 | P1 | 用户 BYOK 配置前置；审核队列 UI(FE-11)；source 作为可追溯标记；**POST /ai/questions:generate 的 count 须服务端校验 1–20，超出返回 400**（契约见 schema 附录 + byok-key-lifecycle 场景5） |

## 前端 FE（Flutter，移动端仅一端）
| ID | 任务 | 依赖 | 优先级 | 验收要点 |
|---|---|---|---|---|
| FE-01 | 目标配置向导页（类型/目标分/日期/每日时长/资料范围） | BE-01 | P0 | AC-EXAM-01~04；倒计时看板 |
| FE-02 | 建题/导入页（拍照 OCR + 手动 + 批量导入，进度与排队 UI） | BE-02 | P0 | AC-Q-01/02；大文件排队提示 |
| FE-03 | 缺陷单列表 + 详情（六栏/完整字段、禁用语拦截 UI、状态时间线） | BE-03 | P0 | AC-DT/ACT/VER；状态机不变量 |
| FE-04 | 验证任务页（V1/V2/V3 待办、提交证据、重开原因） | BE-04 | P0 | AC-VER-01~05 |
| FE-05 | 模考报告页（模块正确率/用时/稳定性/重复错率/漏点率） | BE-05 | P0 | AC-MOCK-01~03 |
| FE-06 | 复盘页（日/周/月，层级分布、未关缺陷、校准目标） | BE-06 | P1 | AC-REV-01~03 |
| FE-07 | 首页看板（目标倒计时/今日任务/缺陷分布概况/快捷入口） | BE-01~06 | P1 | 一句话掌握全局 |
| FE-08 | 主观题批改页（维度表+要点列表录入与比对展示，不确定性标注） | BE-07,AI-02 | P1 | AC-ESS-01~03 |
| FE-09 | 离线优先与本地队列（建题/转单/验证/复盘可离线，纯本地数据）；**AI 依赖任务离线挂起(local_ai_task_queue.status='pending_online'，不缓存明文密钥)，联网后由后端执行**；离线入口读取凭证态，cooldown/revoked/deprecated 直接跳过标记 skipped，不创建 pending_online | BE-08 | P1 | AC-DATA-02；严格按 `offline-sync-spec.md`（挂起字段/执行顺序/cooldown 跳过） |
| FE-10 | 设置页（目标/层级模板/通知/隐私/**BYOK 密钥录入、模型选择、撤销**） | AI-05 | P0 | 与 AI-05 联动；通知节制开关 |
| FE-11 | AI 生成题审核 UI（七态：generating / validation_failed / pending_review / approved / rejected / credential_invalid / cooldown），著作权提示常驻、来源模型+提示词版本、逐题/批量通过、非阻塞底部 sheet（medium detent） | BE-10 | P1 | 状态机见 `byok-key-lifecycle.md` v1.2；**动效严格按 `fe-11-audit-motion-spec.md`（iOS 原生：push 视差/spring 阻尼比两档/底部 sheet 缩放暗化/触觉同帧/Reduce Motion 降级），禁止 Material 共享轴** |

## 算法 / AI（AI 组，用户 BYOK 模型密钥，平台不预设供应商、不承担费用）
| ID | 任务 | 依赖 | 优先级 | 验收要点 |
|---|---|---|---|---|
| AI-01 | 归因辅助 + 题型/考点识别（用户 BYOK 调用，输出带 confidence，人工确认） | BE-03 | P0 | AC-AI-01/02；低置信不自动入库；**调用时使用用户密钥、平台日志不记录密钥明文；未配置 BYOK 时不可用，核心闭环不依赖 AI** |
| AI-02 | 申论要点比对/批改（以 subjective_rubric_points 为参照，标注主观性与不确定性，非官方标准；用户 BYOK 调用，日志不记密钥明文） | BE-07,FE-08 | P1 | AC-ESS-01~03；未配置 BYOK 时不可用 |
| AI-03 | 变式题生成（同类判定规则辅助+用户确认；标注疑似重复/超纲；用户 BYOK 调用，日志不记密钥明文） | BE-02 | P1 | AC-AI-02；幻觉降级；未配置 BYOK 时不可用 |
| AI-04 | 周报 + 计划生成（用户 BYOK 调用，数据脱敏、不出境、结果缓存降本，日志不记密钥明文） | BE-06 | P2 | AC-PLAN / 周报；未配置 BYOK 时不可用 |
| AI-05 | BYOK 密钥管理模块：BE 侧 **KMS 信封加密存储** + FE 侧设置页（录入/选模型/撤销）；平台日志不记录密钥明文；主用模型推荐 **DeepSeek V4.1 Flash**（谷期价格低）；未配置时 AI 全不可用；**provider 枚举锁死 deepseek/openai_compatible**（openai_compatible 必填 base_url）；撤销置 `revoked` 立即停调；轮换旧版置 `deprecated`、新版 `key_version+1`；连续 3 次失败进 `cooldown` 熔断 | BE-00 | P0 | 第15.3遗留①；对齐 `byok-key-lifecycle.md` v1.2 |

## 测试 QA
| ID | 任务 | 依赖 | 优先级 | 验收要点 |
|---|---|---|---|---|
| QA-01 | 状态机单测：全路径 + ACTION_DONE 不能跳 CLOSED + 重开计数 | BE-00 | P0 | 第12节状态机测试 |
| QA-02 | 三次验证规则测试：V1窗口边界、同类题判定、V3稳定阈值 | BE-04 | P0 | AC-VER / 第12节 |
| QA-03 | 禁用语测试：拦截“粗心/我懂了”等 | BE-03 | P0 | AC-DT-02 |
| QA-04 | 离线同步测试：离线建单→同步→并发改同单→409仲裁；**断言离线队列不落明文密钥（AI 任务 pending_online 挂起）**；cooldown 态下断言 AI 任务直接 skipped 不重试、不刷「失败待重试」红点。**可执行断言方法**：① 用 SQLite 浏览器/CLI 检查 `local_ai_task_queue.payload` 不含 `key`/`api_key`/`encrypted_key`/`dek`/`dek_ciphertext`/`kms_key_id` 字段；② 抓包（Proxyman/Charles）检查 `POST /ai-jobs` 请求体不含任何密钥字段（仅 `task_type`/`payload`/`client_task_id`）；③ 检查客户端日志输出不含密钥明文（grep `api_key`/`encrypted_key` 应为空）；④ 离线将凭证置 `revoked` 后断言新 AI 任务落 `skipped`+`skip_reason`，且保持 `pending_online` 不执行直到用户选择「稍后仲裁」或冲突解决 | BE-08,FE-09 | P1 | AC-DATA-02；严格按 `offline-sync-spec.md` |
| QA-05 | AI 安全测试：低置信不入库、超纲降级、主观必带不确定性、AI 不能关单 | AI-01~03 | P1 | 第12节 AI 输出安全 |
| QA-06 | 导入管线测试：抽取→切题→去重(content_hash)→资产分离；体积上限/排队 | BE-02 | P1 | 15.3-3 |

## 里程碑
- **MVP(8周)**: BE-00~05, FE-01~05/07/10, AI-01/05, QA-01~03 → 可跑通「目标→缺陷→三次验证→关闭」闭环（移动端）；BYOK 密钥管理就绪（AI 可用但可选）。
- **V1(+6周)**: BE-06~10, FE-06/08/09, AI-02~04, QA-04~06 → 模考分析/复盘/主观批改/同步完善/题库 AI 生成与审核。
- **V2(+8周)**: 跨端(PC/Web)、模板市场、导出增强。
