# 离线同步与 AI 任务挂起规格（FE-09 / BE-08，对齐 `byok-key-lifecycle.md` 场景 6）

> 版本: v1.2 | 配套: `byok-key-lifecycle.md` 场景6、`schema.sql` v0.3-schema1(ai_generation_jobs / user_model_credentials)、`mvp-tasks.md` v0.3 FE-09 / BE-08 / QA-04、`flutter/local_ai_task_queue.dart`(FE-09 待建客户端表, 本仓尚未创建)
> v1.2 变更: 明确 `flutter/local_ai_task_queue.dart` 为 FE-09 待建产物(当前仓不存在, 评审时标注)。v1.1 变更: 补 skipped 落点(决策1)、客户端凭证缓存安全边界(决策1.1)、上送接口契约(决策2.1)、单批上限20、job.status 与凭证态分离映射。
> 目的: 把离线场景的「AI 任务挂起字段 / 联网后执行顺序 / cooldown 处理」**写死**，使 FE-09 离线队列与 BE-08 同步服务无需二次决策、不返工。
> 总原则（不可违背）: 设备**绝不缓存明文密钥**；离线 AI 任务一律**挂起**而非失败，不占用重试预算、不污染队列。

---

## 决策 1 · 离线 AI 任务挂起状态字段

**存储位置 = 客户端本地 SQLite（Flutter Drift/sqflite），不依赖服务端。** 联网恢复后逐条上送后端 `ai_generation_jobs`（见 `schema.sql`），本地记录标记 `synced`。

客户端本地队列表 `local_ai_task_queue`（最小字段；客户端侧定义见 `flutter/local_ai_task_queue.dart`，Drift + sqflite 双形态）:

| 字段 | 类型 | 说明 |
|---|---|---|
| id | uuid (PK) | 本地任务 id（上送后端后映射为 `ai_generation_jobs.client_task_id`） |
| user_id | uuid | 所属用户 |
| task_type | text | attribution / generation / variation / report |
| payload | json | **非敏感输入**（题干草稿、知识点 id、错因文本等），**不含任何密钥字段** |
| status | text | `pending_online` / `skipped` / `synced` / `failed` / `superseded`（枚举见下） |
| skip_reason | text/null | `status='skipped'` 时填：`cooldown` / `revoked` / `deprecated` |
| created_at | ts | 入队时间（用于联网后排序） |
| synced | bool | 是否已上送后端并收到 `job_id` |

`status` 枚举与语义：
- `pending_online`：已创建、等待联网后由**后端**用用户 BYOK 密钥执行；**不在设备执行、不携带密钥、仅记录意图**。
- `skipped`：**采用方案 A**——离线入口判定凭证态为 `revoked/deprecated/cooldown` 时，不创建 `pending_online`，改为创建 `skipped` 记录（`synced=false`），**保留在本地队列表**；联网后不执行、仅在任务页展示跳过原因 + 一句引导。这样「离线期间发生了什么」可追溯，而非仅一次性 toast。
- `synced`：已上送后端 `ai_generation_jobs` 且服务端返回 `job_id`，本地记录可清理或标记完成。
- `failed`：联网上送后后端执行失败且不可重试（非凭证类硬失败），保留并展示在设置/任务页。
- `superseded`：**仅本地标记**，不参与上送。当一条 `skipped` 记录被用户在任务页手动「重试」时，基于原记录**新建一条 `pending_online`** 重新进入离线入口判定，原 `skipped` 记录改为 `superseded` 保留可追溯（见决策 3）。

- 纯本地任务（建题 / 转缺陷单 / 验证 / 复盘）走普通本地表，与 `pending_online` 队列**分开**，互不影响。
- 离线入口即读取**本地凭证缓存** `local_credential_cache.status`（见决策 1.1）；若为 `revoked` / `deprecated` / `cooldown`，**直接创建 `skipped` 记录、不创建 `pending_online`**（见决策 3）。

### 决策 1.1 · 客户端凭证缓存安全边界（BYOK 红线）

设备本地**只缓存 6 个非敏感字段**，用于离线时判断「能否创建 `pending_online`」与「显示 cooldown 剩余时间」；**绝不缓存任何密钥材料**。

| 缓存字段 | SQLite 类型 | 来源 | 说明 |
|---|---|---|---|
| status | TEXT | `user_model_credentials.status` | active / deprecated / revoked / cooldown |
| provider | TEXT | `user_model_credentials.provider` | deepseek / openai_compatible |
| model | TEXT | `user_model_credentials.model_name` | 展示用 |
| key_preview | TEXT | `user_model_credentials.key_preview` | 仅末 4 位 |
| consecutive_failures | INTEGER | `user_model_credentials.consecutive_failures` | 熔断计数 |
| cooldown_until | INTEGER | `user_model_credentials.cooldown_until` | 熔断到期时间（epoch ms，与客户端表 `created_at` 同单位），**必须缓存**，否则离线无法显示 cooldown 倒计时 |

**绝不缓存**：`encrypted_key`、`dek_ciphertext`、`kms_key_id`、任何明文 `api_key` / DEK。
- 缓存随凭证变更**增量同步**（凭证表 `updated_at` / `version` 驱动）；`status='revoked'` 时**立即删除本地缓存记录**。
- 本地表 `local_credential_cache`（见 `flutter/local_ai_task_queue.dart`）结构严格按上表，不含任何密钥列。
- 离线队列与首页看板依赖此缓存读取凭证态，但**永远拿不到可解密的密钥**。

---

## 决策 2 · 联网后执行顺序（避免密钥失效时批量失败雪崩）

1. **先同步非 AI 数据**：把离线产生的缺陷单 / 作答 / 验证 / 复盘增量推送给后端；乐观锁 `version` 冲突按 409 仲裁（服务端优先 + 客户端提示）。**同步闸门**：非 AI 数据**全部完成同步**（或用户明确选择「稍后仲裁」）后，才开始逐条执行挂起的 AI 任务；若用户在 409 冲突处选择「稍后仲裁」，相关 AI 任务**保持 `pending_online` 不执行**，待用户回到网络环境处理冲突后再触发。
2. **再逐条执行挂起的 AI 任务**：按 `created_at` 升序，每条独立调用后端「AI 执行」接口（后端解密 BYOK → 调模型）。
3. **单条失败隔离**：某条因密钥失效（401/402/429）失败时，**仅该条**进入 `failed` + `credential_status`/`error_code`（UI 推导为 `credential_invalid` / `cooldown`），**不阻断**其余挂起任务执行。
4. **单批上限**：每批最多 **20 条**挂起任务上送执行，避免联网瞬间并发打爆后端与模型 API；超出分批处理。
5. **清理**：全部执行完毕或达单批上限后，本地 `synced=true` 的记录可清理；`failed` / `skipped` 记录保留并展示在设置/任务页。

> 关键：AI 任务**绝不**在设备用本地密钥执行；设备任何时刻不持有明文 `api_key` / `encrypted_key` / `dek_ciphertext`。（对齐 `byok-key-lifecycle.md` 场景 6）

### 决策 2.1 · 上送接口契约（本地 → 服务端）

- 上送接口：`POST /ai-jobs`
  - 请求体：`{ task_type, payload, client_task_id }`（`payload` 为 `local_ai_task_queue.payload` 原样；`client_task_id` 为本地 `id`）
  - 服务端：创建 `ai_generation_jobs`（初始 `status='pending'`，写入 `client_task_id`，`credential_id` 取当前 active 凭证快照），返回 `{ job_id }`。**创建时同步从 `credential_id` 对应凭证复制 `provider_snapshot` / `model_snapshot`**（凭证后续轮换 / 撤销 / 物理删除均不影响该 job 快照，保证可追溯「执行用的是哪家模型」，见 schema `ai_generation_jobs` 两列定义）。
  - 客户端：将本地 `id` ↔ 服务端 `job_id` 映射后，标记 `local_ai_task_queue.synced=true`。
- 字段映射细节（`payload` 内部字段名、`generation_meta` 回写）在 BE-00 建表后于 API 文档补全；本细则只定「上送动作与状态落点」。
- `ai_generation_jobs` **不含任何密钥字段**；`credential_id` 仅指向服务端已信封加密的凭证记录（对齐 `byok-key-lifecycle.md` 场景 6）。

---

## 决策 3 · cooldown / revoked / deprecated 状态下的离线队列处理

| 凭证态 | 离线入口行为 | 联网后行为 |
|---|---|---|
| `active` | 正常创建 `pending_online` | 正常上送执行 |
| `cooldown`（连续失败熔断） | **直接跳过**，标记 `skipped`（原因=cooldown），**不创建 pending_online** | 若 cooldown 已结束（active）或用户更新密钥 → 重新入队执行；否则保持 skipped，不重试 |
| `revoked`（用户撤销） | 直接跳过，标记 `skipped`（原因=凭证已撤销） | 引导去设置页重新配置；未配置前不重试 |
| `deprecated`（轮换旧版） | 直接跳过，标记 `skipped`（原因=凭证已轮换） | 引导选用最新 active 凭证；不重试旧版 |

**skipped 记录的重试语义**：`cooldown` / `revoked` / `deprecated` 状态下**不自动重试**（避免反复撞墙或不知情产生费用）。用户在任务页手动点「重试」时，基于原 `skipped` 记录**新建一条 `pending_online`** 重新进入上述离线入口判定（如 cooldown 已结束、或用户已更新/轮换到 active 凭证则可通过）；原 `skipped` 记录标记 `superseded`（仅本地标记、不参与上送、保留可追溯），不物理删除。

- **绝不**在离线期间把 AI 任务标成「失败待重试」红点刷屏；用户联网后看到的是干净的 skipped 标记 + 一句引导文案。
- `cooldown` 期间即使联网，也不主动重试，等冷却结束或用户手动「重试 / 更新密钥」再入队（避免反复撞墙，见 `byok-key-lifecycle.md` 场景 3 熔断规则）。

---

## 与七态状态机的衔接（job.status 与凭证态分离）

`ai_generation_jobs.status` 是**任务态**（不含凭证态）；FE-11 七态 UI 由 `job.status` + 凭证态（`credential_status` / `error_code`）共同推导：

| 七态 UI | 推导条件 |
|---|---|
| `generating` | job 刚创建，或 `status='running'`，或 `status='validating'`（正在自动校验，UI 显示「正在校验」子状态，仍归在 generating 下，不单独建 UI 态） |
| `validation_failed` | `status='validation_failed'` |
| `pending_review` | `status='pending_review'` |
| `approved` | `status='approved'`（已写 `questions.source='ai_generated'`） |
| `rejected` | `status='rejected'` |
| `credential_invalid` | `status='failed'` 且 `error_code IN ('401','402','429')`（或 `credential_status` 为 revoked/deprecated） |
| `cooldown` | `status='failed'` 且 `error_code='cooldown'`（连续失败熔断） |

离线 / 执行流程：
```
设备离线建 AI 任务
  -> 读 local_credential_cache.status
      若为 active  -> local_ai_task_queue.status='pending_online' (无明文)
      否则        -> local_ai_task_queue.status='skipped' + skip_reason (不创建 pending_online)
联网恢复
  -> 先同步非AI数据(乐观锁409仲裁) -> 按 created_at 升序, 每批≤20条逐条上送
  -> POST /ai-jobs -> ai_generation_jobs(status='pending', client_task_id 映射)
  -> 后端执行: pending -> running -> validating -> validation_failed | pending_review
  -> pending_review -> approved(写 questions, source='ai_generated') / rejected
凭证异常 -> job.status='failed' + credential_status/error_code (仅该条, 不雪崩)
skipped 记录联网后不执行, 仅展示跳过原因
```

> 后端 `ai_generation_jobs` 表定义（含 `credential_status` 列、`client_task_id` 列，且 `status` 不含凭证态）见 `schema.sql`；FE-11 七态 UI 由上述映射驱动。
