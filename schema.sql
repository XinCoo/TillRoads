-- ============================================================================
-- 题路 TillRoad · 数据库 Schema (PostgreSQL 15+)
-- 版本: v0.3-schema1  |  配套文档: 题路TillRoad-开发文档初稿.md (第4/11/15节)
-- 修订(P0 修复, 详见 REVIEW-NOTES.md):
--   P0-1 全面幂等化: CREATE TABLE/INDEX IF NOT EXISTS + CREATE TRIGGER 前 DROP IF EXISTS;
--   P0-2 verifications 引入 round 轮次 / defect_tickets.verification_round, 唯一索引含 round;
--   P0-3 DRAFT 建单允许未归因(NULL), 禁用语/归因必填仅在非 DRAFT 时强制。
--   可重复执行(配合 BE-00 CI 二次执行幂等门禁)。
-- A 轮加固(本轮, 详见交付说明): A1 set_updated 已覆盖 ai_generation_jobs / 验证按 tgfoid 强校验;
--   A2 顿号改等长 translate 显式 1:1 映射(方案 a: '、'->',') + 全角空格 U+3000 改显式删除;
--   A3 credential_status / weight 两处 CHECK 显式命名 + 幂等补建 + 验证按 conname 精确匹配。
-- 设计要点:
--   1) 题库内容层(questions/assets/subjective_rubric_points) 与
--      用户缺陷单层(defect_tickets/attempts/actions/verifications/...) 分表,
--      通过 question_id 关联; 用户私有题不上传公有池。
--   2) 所有表含同步字段 created_at/updated_at/version/deleted_at,
--      version 乐观锁 + 冲突仲裁见文末《同步与冲突仲裁》。
--   3) defect_tickets.status 用 ENUM + 触发器强制状态迁移(体现"已处理≠已解决")。
--   4) content_hash 归一化规则、assets.storage_key 路径规范见对应注释。
--   5) ORM 映射: 表名即实体(见第4节); 驼峰字段映射为 snake_case, jsonb→实体内对象。
--   6) BYOK 架构: 平台不预设/不承担模型 API, 用户自填密钥(user_model_credentials);
--      密钥 KMS 信封加密, 平台日志不记明文; AI 生成题经审核队列入库
--      (source=ai_generated + generation_meta 可追溯)。核心闭环不依赖 AI。
--   7) BYOK provider 范围 MVP 锁死: 仅 deepseek / openai_compatible 两类(薄 adapter);
--      凭证状态机含 deprecated(轮换保留)/revoked(撤销)/cooldown(连续失败熔断)。
-- ============================================================================

-- ------------------------- 枚举类型 (idempotent) --------------------------
DO $$ BEGIN CREATE TYPE defect_status AS ENUM
  ('DRAFT','ANALYZED','ACTION_DONE','V1','V2','V3','REOPENED','CLOSED');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN CREATE TYPE priority_level AS ENUM ('P0','P1','P2');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN CREATE TYPE verify_stage AS ENUM ('V1','V2','V3');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN CREATE TYPE verify_type AS ENUM
  ('redo_hidden','similar_variant','new_question','timed_mock','teach_back','peer_check');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN CREATE TYPE verify_result AS ENUM ('pending','pass','fail');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN CREATE TYPE exam_type AS ENUM
  ('civil_service','postgrad','final_exam','vocational','adult_self_study');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN CREATE TYPE subject_kind AS ENUM ('objective','subjective','essay');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN CREATE TYPE question_source AS ENUM ('manual','photo','import','mock','ai_generated');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- 生产迁移: ALTER TYPE question_source ADD VALUE 'ai_generated'; (PG11+ 支持, 须在事务外执行)

DO $$ BEGIN CREATE TYPE difficulty AS ENUM ('easy','medium','hard');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN CREATE TYPE user_role AS ENUM ('student','admin');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN CREATE TYPE cycle_type AS ENUM ('daily','weekly','monthly');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN CREATE TYPE plan_generated_by AS ENUM ('user','ai');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN CREATE TYPE asset_owner AS ENUM ('question','attempt','defect');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN CREATE TYPE cred_provider AS ENUM ('deepseek','openai_compatible');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- ============================================================================
-- 表定义
-- ============================================================================

-- ---- users ----
CREATE TABLE IF NOT EXISTS users (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  nickname    text,
  avatar      text,
  timezone    text NOT NULL DEFAULT 'Asia/Shanghai',
  role        user_role NOT NULL DEFAULT 'student',
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  version     int NOT NULL DEFAULT 1,
  deleted_at  timestamptz
);

-- ---- user_model_credentials (BYOK 信封加密凭证, 平台不托管明文/不承担费用) ----
-- 信封加密(对齐 byok-key-lifecycle.md 场景1/2/4):
--   * 每条用户密钥用独立 DEK 加密 -> encrypted_key; DEK 由 CMK(KMS) 加密 -> dek_ciphertext
--   * 调用时: KMS 解 dek_ciphertext 得 DEK_plain -> AES 解 encrypted_key 得 api_key; 仅本次调用驻留
--   * 明文 api_key 永不落库/不回显/不记日志; key_preview 仅末4位
--   * status 四态: active(可用) / deprecated(轮换后旧版, 历史可追溯但不再新用)
--                  / revoked(用户撤销, 立即停调, 历史不可撤回) / cooldown(连续失败熔断, 临时停用)
--   * 连续 3 次 401/402/429 -> cooldown 30min, 期间不发请求; 更新密钥或手动重试清零
--   * provider 枚举 MVP 锁死 deepseek/openai_compatible; openai_compatible 必填 base_url
CREATE TABLE IF NOT EXISTS user_model_credentials (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         uuid NOT NULL REFERENCES users(id),
  provider        cred_provider NOT NULL,  -- MVP 锁死: deepseek / openai_compatible
  model_name      text NOT NULL,    -- 用户选模型, 推荐默认 DeepSeek V4.1 Flash
  base_url        text,             -- openai_compatible 必填; deepseek 可空(用默认端点)
  encrypted_key   bytea NOT NULL,   -- 用户密钥密文(由独立 DEK 加密)
  dek_ciphertext  bytea NOT NULL,   -- DEK 经 CMK 加密后的密文(KMS 托管 CMK 解密)
  kms_key_id      text NOT NULL,    -- 信封加密所用 CMK 标识(云 KMS)
  key_version     int  NOT NULL DEFAULT 1,  -- 轮换版本号(新密钥=旧+1, 旧置 deprecated)
  key_preview     text,             -- 末4位展示, 如 '...3f9a'
  status          text NOT NULL DEFAULT 'active'
                    CONSTRAINT chk_umc_status
                    CHECK (status IN ('active','deprecated','revoked','cooldown')),
  consecutive_failures int NOT NULL DEFAULT 0,  -- 连续失败计数; 达阈值进 cooldown
  cooldown_until  timestamptz,      -- 熔断到期时间; 为 null 表示非熔断态
  revoked_at      timestamptz,      -- 撤销时间(撤销语义); status='revoked' 时由触发器写入
  last_used_at    timestamptz,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  version         int NOT NULL DEFAULT 1,
  deleted_at      timestamptz,
  -- MVP 仅两类 provider; openai_compatible 必须带 base_url
  CONSTRAINT chk_umc_baseurl CHECK (provider <> 'openai_compatible' OR base_url IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS idx_umc_user ON user_model_credentials(user_id, status);

-- ---- ai_generation_jobs (AI 生成题任务, BYOK 后端执行, FE-11 审核七态上游) ----
-- 离线: 设备 local_ai_task_queue.status='pending_online' -> 联网上送本表(status='pending')
-- 任务态枚举(与 UI 七态区分, 不含凭证态): pending -> running -> validating
--   -> validation_failed -> pending_review -> approved(写 questions,source='ai_generated') / rejected / failed
-- 凭证态(credential_invalid/cooldown)不混入 job.status: 用 credential_status 快照表达;
--   UI 七态中的 credential_invalid/cooldown 由 (status='failed' + error_code) 推导(见 offline-sync-spec.md)
-- 设备离线不写明文密钥; payload 不含任何密钥材料(对齐 byok-key-lifecycle.md 场景6; 细则见 offline-sync-spec.md)
CREATE TABLE IF NOT EXISTS ai_generation_jobs (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id            uuid NOT NULL REFERENCES users(id),
  credential_id      uuid REFERENCES user_model_credentials(id), -- 执行所用 BYOK 凭证(版本快照)
  client_task_id     uuid,          -- 映射设备 local_ai_task_queue.id, 上送后回写 synced
  credential_status  text CONSTRAINT chk_aijob_cred_status CHECK (credential_status IS NULL OR credential_status IN ('active','deprecated','revoked','cooldown')),
                                        -- 执行/失败时的凭证态快照(取值须与七态推导表 credential_status 一致, 防脏数据混入七态)
  provider_snapshot  text,          -- 创建 job 时从凭证快照的 provider (凭证轮换/撤销/物理删除后仍可还原执行用的是哪家)
  model_snapshot     text,          -- 创建 job 时从凭证快照的 model_name (generation_meta 仅在 approved 后写入, job 本身需自持快照)
  job_type           text NOT NULL CHECK (job_type IN ('attribution','generation','variation','report')),
  prompt_version     text,          -- 生成所用提示词版本(回写 generation_meta)
  payload            jsonb NOT NULL, -- 非敏感输入(题干草稿/知识点/错因文本等), 不含密钥
  status             text NOT NULL DEFAULT 'pending'
                       CONSTRAINT chk_aijob_status
                       CHECK (status IN ('pending','running','validating','validation_failed',
                                         'pending_review','approved','rejected','failed')),
  review_status      text,          -- 镜像 generation_meta.review_status
  result_question_id uuid,          -- approved 后写入 questions(source='ai_generated'); FK 在文末 ALTER TABLE 添加(questions 在其后定义)
  error_code         text,          -- 401/402/429/cooldown/unknown (配合 credential_status 表达凭证失败)
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  version            int NOT NULL DEFAULT 1,
  deleted_at         timestamptz
);
CREATE INDEX IF NOT EXISTS idx_aijob_user ON ai_generation_jobs(user_id, status);
CREATE INDEX IF NOT EXISTS idx_aijob_client ON ai_generation_jobs(client_task_id);

-- ---- exam_profiles (考试目标与约束) ----
CREATE TABLE IF NOT EXISTS exam_profiles (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       uuid NOT NULL REFERENCES users(id),
  exam_type     exam_type NOT NULL,
  target_label  text,
  target_score  numeric(6,2),
  subject_target jsonb,
  exam_date     date,
  daily_minutes int,
  source_scope  jsonb,
  baseline      jsonb,
  status        text NOT NULL DEFAULT 'active' CHECK (status IN ('active','archived')),
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  version       int NOT NULL DEFAULT 1,
  deleted_at    timestamptz
);
CREATE INDEX IF NOT EXISTS idx_ep_user ON exam_profiles(user_id);

-- ---- subjects ----
CREATE TABLE IF NOT EXISTS subjects (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  exam_profile_id   uuid NOT NULL REFERENCES exam_profiles(id) ON DELETE CASCADE,
  name              text NOT NULL,
  kind              subject_kind NOT NULL,
  layer_template_id uuid,           -- 关联能力层级模板; FK 在文末 ALTER TABLE 添加(capability_layers 在其后定义)
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  version          int NOT NULL DEFAULT 1,
  deleted_at       timestamptz
);
CREATE INDEX IF NOT EXISTS idx_sub_ep ON subjects(exam_profile_id);

-- ---- knowledge_nodes (考点树, 自关联) ----
CREATE TABLE IF NOT EXISTS knowledge_nodes (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  subject_id        uuid NOT NULL REFERENCES subjects(id) ON DELETE CASCADE,
  title             text NOT NULL,
  parent_id         uuid REFERENCES knowledge_nodes(id),
  freq_tag          text CHECK (freq_tag IN ('high','mid','low')),
  weight_to_target  numeric(4,3) DEFAULT 0,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  version           int NOT NULL DEFAULT 1,
  deleted_at        timestamptz
);
CREATE INDEX IF NOT EXISTS idx_kn_subject ON knowledge_nodes(subject_id);
CREATE INDEX IF NOT EXISTS idx_kn_parent  ON knowledge_nodes(parent_id);

-- ---- capability_layers (能力层级模板) ----
CREATE TABLE IF NOT EXISTS capability_layers (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name          text NOT NULL,
  layers        jsonb NOT NULL,   -- [{order:int,key:text,label:text,desc:text}]
  customizable  boolean NOT NULL DEFAULT true,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  version       int NOT NULL DEFAULT 1,
  deleted_at    timestamptz
);

-- ---- questions (题库内容层, 文本为主体) ----
CREATE TABLE IF NOT EXISTS questions (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source            question_source NOT NULL,  -- 含 ai_generated(由用户 BYOK 生成)
  subject_id        uuid REFERENCES subjects(id),
  knowledge_node_id uuid REFERENCES knowledge_nodes(id),
  type              text NOT NULL,   -- choice/fill/short_answer/essay/material
  stem              text NOT NULL,
  options           jsonb,          -- [{key,text}]
  answer            text,
  analysis          text,
  formula_text      text,           -- 公式用 LaTeX 文本存储, 如 $a^2+b^2=c^2$
  difficulty        difficulty,
  tags              jsonb,          -- 用户标签; 不含生成元数据(见 generation_meta)
  generation_meta   jsonb,          -- AI 生成题可追溯标记(仅 source=ai_generated 时必填):
                                    --   {model:text, prompt_version:text,
                                    --    review_status:('pending'|'approved'|'rejected')}
                                    --   经用户审核队列确认(review_status='approved')后方可入库对外使用
  content_hash      text NOT NULL,  -- 归一化指纹(见 normalize_question_text)
  asset_refs       jsonb,          -- [{asset_id:uuid, role:text}]
  is_subjective     boolean NOT NULL DEFAULT false,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  version           int NOT NULL DEFAULT 1,
  deleted_at        timestamptz
);
CREATE INDEX IF NOT EXISTS idx_q_hash ON questions(content_hash);
CREATE INDEX IF NOT EXISTS idx_q_kn   ON questions(knowledge_node_id);
CREATE INDEX IF NOT EXISTS idx_q_sub  ON questions(subject_id);

-- ---- assets (外置资产, 仅存引用) ----
-- storage_key 规范: tillroad://{scope}/{owner_type}/{owner_id}/{asset_type}/{uuid}.{ext}
--   scope = local | oss:<bucket>
--   例: tillroad://local/question/3f2a.../image/9b1c...png
--       tillroad://oss:tillroad-cn/attempt/.../audio/...m4a
--   客户端按 scope 路由: local->本机文件系统; oss:*->对象存储 SDK
CREATE TABLE IF NOT EXISTS assets (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_type  asset_owner NOT NULL,
  owner_id    uuid NOT NULL,
  storage_key text NOT NULL,
  mime        text,
  size_bytes  bigint,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  version     int NOT NULL DEFAULT 1,
  deleted_at  timestamptz
);
CREATE INDEX IF NOT EXISTS idx_asset_owner ON assets(owner_type, owner_id);

-- ---- attempts (作答记录) ----
CREATE TABLE IF NOT EXISTS attempts (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  question_id   uuid NOT NULL REFERENCES questions(id),
  user_id       uuid NOT NULL REFERENCES users(id),
  is_correct    boolean,
  duration_ms   int,
  answer_text   text,
  mock_exam_id  uuid,               -- 若属模考; FK 在文末 ALTER TABLE 添加(mock_exams 在其后定义)
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  version       int NOT NULL DEFAULT 1,
  deleted_at    timestamptz
);
CREATE INDEX IF NOT EXISTS idx_attempt_q    ON attempts(question_id);
CREATE INDEX IF NOT EXISTS idx_attempt_user ON attempts(user_id);

-- ---- defect_tickets (缺陷单) ★ ----
CREATE TABLE IF NOT EXISTS defect_tickets (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id           uuid NOT NULL REFERENCES users(id),
  exam_profile_id   uuid NOT NULL REFERENCES exam_profiles(id),
  knowledge_node_id uuid REFERENCES knowledge_nodes(id),
  question_id       uuid REFERENCES questions(id),
  q_type            text,
  error_layer       text,          -- P0-3: DRAFT 可空(建单未归因); 转 ANALYZED 时触发器强制非空
  error_cause       text,          -- P0-3: DRAFT 可空; 转 ANALYZED 时强制非空且禁禁用语
  actions           jsonb,         -- 冗余快照; 规范化行见 actions 表
  priority          priority_level,
  status            defect_status NOT NULL DEFAULT 'DRAFT',
  verification_state jsonb NOT NULL DEFAULT '{"v1":"pending","v2":"pending","v3":"pending"}'::jsonb,
  reopen_count      int NOT NULL DEFAULT 0,
  verification_round int NOT NULL DEFAULT 1,  -- P0-2: 当前验证轮次; REOPENED->ANALYZED 时 +1
  reopen_reason     text,
  created_at        timestamptz NOT NULL DEFAULT now(),
  closed_at         timestamptz,
  updated_at        timestamptz NOT NULL DEFAULT now(),
  version           int NOT NULL DEFAULT 1,
  deleted_at        timestamptz
);
CREATE INDEX IF NOT EXISTS idx_dt_user   ON defect_tickets(user_id);
CREATE INDEX IF NOT EXISTS idx_dt_status ON defect_tickets(status);
CREATE INDEX IF NOT EXISTS idx_dt_kn     ON defect_tickets(knowledge_node_id);
CREATE INDEX IF NOT EXISTS idx_dt_ep     ON defect_tickets(exam_profile_id);

-- ---- actions (处理动作, 规范化) ----
CREATE TABLE IF NOT EXISTS actions (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  defect_ticket_id uuid NOT NULL REFERENCES defect_tickets(id) ON DELETE CASCADE,
  content         text NOT NULL,
  done            boolean NOT NULL DEFAULT false,
  due             timestamptz,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  version         int NOT NULL DEFAULT 1,
  deleted_at      timestamptz
);
CREATE INDEX IF NOT EXISTS idx_act_dt ON actions(defect_ticket_id);

-- ---- verifications (三次验证记录) ----
CREATE TABLE IF NOT EXISTS verifications (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  defect_ticket_id uuid NOT NULL REFERENCES defect_tickets(id) ON DELETE CASCADE,
  stage           verify_stage NOT NULL,
  round           int NOT NULL DEFAULT 1,  -- P0-2: 验证轮次, 与 defect_tickets.verification_round 对齐
  verify_type     verify_type NOT NULL,
  question_id     uuid REFERENCES questions(id),
  result          verify_result NOT NULL DEFAULT 'pending',
  evidence        text,
  verified_at     timestamptz,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  version         int NOT NULL DEFAULT 1,
  deleted_at      timestamptz
);
CREATE INDEX IF NOT EXISTS idx_ver_dt ON verifications(defect_ticket_id);
DROP INDEX IF EXISTS idx_ver_dt_stage;
CREATE UNIQUE INDEX idx_ver_dt_stage ON verifications(defect_ticket_id, stage, round); -- 每(阶段,轮次)仅一条; 重开后新 round 可再插, 保留历史证据

-- ---- mock_exams (模考) ----
CREATE TABLE IF NOT EXISTS mock_exams (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  exam_profile_id   uuid NOT NULL REFERENCES exam_profiles(id),
  mode              text NOT NULL CHECK (mode IN ('module','full')),
  duration_limit_ms int,
  questions         jsonb,   -- [{question_id, attempt_id, is_correct, duration_ms}]
  report            jsonb,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  version           int NOT NULL DEFAULT 1,
  deleted_at        timestamptz
);
CREATE INDEX IF NOT EXISTS idx_me_ep ON mock_exams(exam_profile_id);

-- ---- review_cycles (复盘) ----
CREATE TABLE IF NOT EXISTS review_cycles (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     uuid NOT NULL REFERENCES users(id),
  cycle_type  cycle_type NOT NULL,
  period      text NOT NULL,   -- 2026-W47 / 2026-11-13
  metrics     jsonb,
  completed   boolean NOT NULL DEFAULT false,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  version     int NOT NULL DEFAULT 1,
  deleted_at  timestamptz
);
CREATE INDEX IF NOT EXISTS idx_rc_user ON review_cycles(user_id, cycle_type, period);

-- ---- plans (计划) ----
CREATE TABLE IF NOT EXISTS plans (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         uuid NOT NULL REFERENCES users(id),
  daily_minutes   int,
  items           jsonb,       -- [{type, ref_id, due, done}]
  generated_by    plan_generated_by NOT NULL DEFAULT 'user',
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  version         int NOT NULL DEFAULT 1,
  deleted_at      timestamptz
);
CREATE INDEX IF NOT EXISTS idx_plan_user ON plans(user_id);

-- ---- subjective_rubric_points (申论/主观题要点库, 15.3-2 决策: 维度表+要点列表) ----
-- 结构: 每道主观题下挂多个维度(dimension), 每维度含若干要点(point_text),
--       关键要点(is_key_point)用于"漏点"判定; AI 批改以此为参照并标注不确定性。
CREATE TABLE IF NOT EXISTS subjective_rubric_points (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  question_id  uuid NOT NULL REFERENCES questions(id) ON DELETE CASCADE,
  dimension    text NOT NULL,   -- 立意/结构/论证/素材/语言/时间 或自定义
  point_text   text NOT NULL,
  is_key_point boolean NOT NULL DEFAULT false,
  weight       numeric(4,3) DEFAULT 1 CONSTRAINT chk_rubric_weight CHECK (weight >= 0),  -- A3: 负权重无意义, 显式命名便于验证按 conname 精确匹配
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  version      int NOT NULL DEFAULT 1,
  deleted_at   timestamptz
);
CREATE INDEX IF NOT EXISTS idx_rp_q ON subjective_rubric_points(question_id);

-- ============================================================================
-- 建表后外键补建 (修复前向引用: 被引用表在引用表之后定义, CREATE TABLE 时尚未存在)
--   采用 ALTER TABLE ADD CONSTRAINT, 不改变既有表顺序; 每个 FK 包在 DO 块中以
--   duplicate_object 异常兜底, 保证 schema.sql 可重复执行 (CI 幂等, ON_ERROR_STOP=1 下二次执行不报 already exists)。
-- ============================================================================
-- P0-2/P0-3 增量补列(兼容从 v0.2 旧库升级; 全新库由上方 CREATE TABLE 直接带上, ADD IF NOT EXISTS / DROP NOT NULL 均为无害 no-op)
ALTER TABLE defect_tickets ADD COLUMN IF NOT EXISTS verification_round int NOT NULL DEFAULT 1;
ALTER TABLE defect_tickets ALTER COLUMN error_layer DROP NOT NULL;
ALTER TABLE defect_tickets ALTER COLUMN error_cause  DROP NOT NULL;
ALTER TABLE verifications  ADD COLUMN IF NOT EXISTS round int NOT NULL DEFAULT 1;

-- A3: 命名 CHECK 约束(显式 conname, 便于末尾验证 SQL 按 conname 精确匹配);
--   全新库由上方 CREATE TABLE 内联命名约束直接带上; 旧库(约束为自动名)由本 DO 块按 conname 幂等补建。
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                 WHERE conname='chk_aijob_cred_status' AND conrelid='ai_generation_jobs'::regclass) THEN
    ALTER TABLE ai_generation_jobs ADD CONSTRAINT chk_aijob_cred_status
      CHECK (credential_status IS NULL OR credential_status IN ('active','deprecated','revoked','cooldown'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                 WHERE conname='chk_rubric_weight' AND conrelid='subjective_rubric_points'::regclass) THEN
    ALTER TABLE subjective_rubric_points ADD CONSTRAINT chk_rubric_weight CHECK (weight >= 0);
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  ALTER TABLE subjects
    ADD CONSTRAINT fk_subjects_layer FOREIGN KEY (layer_template_id)
    REFERENCES capability_layers(id);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  ALTER TABLE attempts
    ADD CONSTRAINT fk_attempts_mockexam FOREIGN KEY (mock_exam_id)
    REFERENCES mock_exams(id);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  ALTER TABLE ai_generation_jobs
    ADD CONSTRAINT fk_aijob_question FOREIGN KEY (result_question_id)
    REFERENCES questions(id);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- 每用户至多一个 active 凭证 (轮换/手动改状态不致出现两个 active; 软删除外)
--   并发轮换或手动改状态时, 若已存在 active 则唯一索引拒绝, 应用层需先把旧记录置 deprecated
--   deleted_at 非空的已删记录不受约束, 允许历史 active 凭证软删后重新激活
--   IF NOT EXISTS 保证可重复执行
CREATE UNIQUE INDEX IF NOT EXISTS idx_umc_one_active
  ON user_model_credentials(user_id)
  WHERE status = 'active' AND deleted_at IS NULL;

-- ============================================================================
-- 触发器: version/updated_at 自动维护
-- ============================================================================
CREATE OR REPLACE FUNCTION set_updated() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := now();
  NEW.version := OLD.version + 1;
  RETURN NEW;
END;
$$;

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'users','user_model_credentials','exam_profiles','subjects','knowledge_nodes','capability_layers',
    'questions','assets','attempts','defect_tickets','actions','verifications',
    'mock_exams','review_cycles','plans','subjective_rubric_points','ai_generation_jobs']
  LOOP
    EXECUTE format(
      'DROP TRIGGER IF EXISTS trg_%1$s_upd ON %1$s;
       CREATE TRIGGER trg_%1$s_upd BEFORE UPDATE ON %1$s
       FOR EACH ROW EXECUTE FUNCTION set_updated();', t);
  END LOOP;
END $$;

-- ============================================================================
-- 触发器: defect_tickets 状态机约束 (体现"已处理≠已解决")
--   - 仅允许以下迁移; 其余 RAISE EXCEPTION
--   - 进入 REOPENED 累加 reopen_count
--   - 进入 CLOSED 写入 closed_at
--   - ACTION_DONE 不能直跳 CLOSED (不在允许表里)
-- ============================================================================
CREATE OR REPLACE FUNCTION check_defect_transition() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  allowed jsonb := '{
    "DRAFT":["ANALYZED"],
    "ANALYZED":["ACTION_DONE"],
    "ACTION_DONE":["V1"],
    "V1":["V2","REOPENED"],
    "V2":["V3","REOPENED"],
    "V3":["CLOSED","REOPENED"],
    "REOPENED":["ANALYZED"],
    "CLOSED":[]
  }'::jsonb;
BEGIN
  IF OLD.status IS DISTINCT FROM NEW.status THEN
    -- allowed->(OLD.status::text) 取当前态允许的下一态数组(jsonb); 展开后判等
    -- 注意: 不能用 ->> 后再 ? (text ? text 操作符不存在, 会导致 CREATE FUNCTION 编译失败)
    IF NOT EXISTS (
      SELECT 1 FROM jsonb_array_elements_text(allowed->(OLD.status::text)) v WHERE v = NEW.status::text
    ) THEN
      RAISE EXCEPTION 'ILLEGAL_DEFECT_TRANSITION: % -> %', OLD.status, NEW.status;
    END IF;
    IF NEW.status = 'REOPENED' AND OLD.status <> 'REOPENED' THEN
      NEW.reopen_count := OLD.reopen_count + 1;
    END IF;
    -- P0-2: 重开后重新归因(REOPENED->ANALYZED)开启新一轮验证轮次, 使 (stage,round) 可重复插入
    IF NEW.status = 'ANALYZED' AND OLD.status = 'REOPENED' THEN
      NEW.verification_round := OLD.verification_round + 1;
    END IF;
    IF NEW.status = 'CLOSED' AND OLD.status <> 'CLOSED' THEN
      NEW.closed_at := now();
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_defect_transition ON defect_tickets;
CREATE TRIGGER trg_defect_transition BEFORE UPDATE ON defect_tickets
  FOR EACH ROW EXECUTE FUNCTION check_defect_transition();

-- 禁用语拦截 (对齐 AC-DT-02): 命中则禁止写入 error_cause
CREATE OR REPLACE FUNCTION check_defect_forbidden_phrase() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  -- P0-3: DRAFT 建单未归因(仅记录错题); 禁用语/归因必填仅在非 DRAFT(尤其转入 ANALYZED)时强制
  IF NEW.status = 'DRAFT' THEN
    RETURN NEW;
  END IF;
  IF NEW.status = 'ANALYZED' AND (NEW.error_layer IS NULL OR NEW.error_cause IS NULL) THEN
    RAISE EXCEPTION 'MISSING_ERROR_LAYER_OR_CAUSE';
  END IF;
  IF NEW.error_cause ~ '粗心|马虎|没掌握|我懂了|大意|差不多|忘了' THEN
    RAISE EXCEPTION 'FORBIDDEN_PHRASE_IN_ERROR_CAUSE';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_defect_phrase ON defect_tickets;
CREATE TRIGGER trg_defect_phrase BEFORE INSERT OR UPDATE ON defect_tickets
  FOR EACH ROW EXECUTE FUNCTION check_defect_forbidden_phrase();

-- 撤销语义: status 置 revoked 时写入 revoked_at (对齐 byok-key-lifecycle.md 场景4)
-- cooldown 由应用层在连续失败达阈值时写入 status='cooldown' + cooldown_until; deprecated 由轮换流程写入
CREATE OR REPLACE FUNCTION set_revoked_at() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  -- 仅 UPDATE 生效; INSERT 时 OLD 为 NULL, 守卫避免 OLD.status/revoled_at 误判 (即便未来误挂 INSERT 也安全)
  IF TG_OP <> 'UPDATE' THEN RETURN NEW; END IF;
  IF NEW.status = 'revoked' AND (OLD.status IS DISTINCT FROM NEW.status OR OLD.revoked_at IS NULL) THEN
    NEW.revoked_at := now();
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_umc_revoked ON user_model_credentials;
CREATE TRIGGER trg_umc_revoked BEFORE UPDATE ON user_model_credentials
  FOR EACH ROW EXECUTE FUNCTION set_revoked_at();

-- ============================================================================
-- content_hash 归一化规则 (对齐 15.3-3 / A1 去重)
--   1) 取 stem + options(按 key 排序拼接) + formula_text
--   2) 全角标点转半角; 去除所有空白(空格/换行/tab)
--   3) 公式 LaTeX 规范化(应用层, 见下) 后再拼入
--   4) 计算 sha256 作为 content_hash
--   注: 仅做标点/空白归一, 不做字母大小写化(公式变量大小写敏感);
--       LaTeX 深度规范化(去 $...$ 内空格, 统一 \frac{}{} 形态, 命令大小写)
--       由导入服务在写入前完成, 不在 DB 内实现。
-- ============================================================================
CREATE OR REPLACE FUNCTION normalize_question_text(
  p_stem text, p_options jsonb, p_formula text
) RETURNS text LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  s    text := COALESCE(p_stem,'');
  opts text := '';
BEGIN
  IF p_options IS NOT NULL THEN
    SELECT string_agg(v->>'text', '' ORDER BY v->>'key')
      INTO opts FROM jsonb_array_elements(p_options) v;
  END IF;
  s := s || COALESCE(opts,'') || COALESCE(p_formula,'');
  -- 全角标点 -> 半角 (A2 方案 a: 等长 1:1 显式映射, 顿号保留并列分隔语义)
  --   translate from/to 均 13 字符严格等长: 第 13 位 '、' -> 半角逗号 ',';
  --   不再依赖「目标串更短 -> 末位字符被隐式删除」的脆弱机制(防「甲、乙」与「甲乙」误合并);
  --   全角空格 U+3000 改为下方显式 replace 删除(排版噪声), 与 core/index.mjs FULLWIDTH_MAP 对齐。
  --   全角引号仍由下方 replace 处理, 避开 translate 引号转义陷阱。
  s := translate(s, '，。！？；：（）【】《》、', ',.!?;:()[]<>,');
  s := replace(s, '　', '');  -- A2: 全角空格(U+3000)显式删除, 替代原隐式删除
  s := replace(s, '“', '"');   -- 全角左双引号 -> 半角
  s := replace(s, '”', '"');   -- 全角右双引号 -> 半角
  s := replace(s, '‘', '''');  -- 全角左单引号 -> 半角 ('''' 解码为一个半角单引号)
  s := replace(s, '’', '''');  -- 全角右单引号 -> 半角
  -- 去除所有空白
  s := regexp_replace(s, '\s+', '', 'g');
  RETURN encode(sha256(convert_to(s,'UTF8')), 'hex');
END;
$$;

-- ============================================================================
-- 同步与冲突仲裁
--   字段: updated_at(最后修改), version(每次 UPDATE +1, 乐观锁), deleted_at(软删)
--   写流程:
--     客户端发起 UPDATE ... WHERE id=$id AND version=$base_version
--     受影响行数=0 -> 返回 409 + 服务端当前行(含其 version/updated_at)
--     用户在端上仲裁(保留/合并/覆盖), 再带新 base_version 重试
--   软删除: DELETE 改为 UPDATE ... SET deleted_at=now(); 同步时下发 deleted_at
--   结构性冲突(同缺陷单并发改 status)由触发器 + 上述乐观锁双重保障
-- ============================================================================

-- ============================================================================
-- 附录: 关键接口契约 (与文档第11节对齐)
-- ----------------------------------------------------------------------------
-- POST /defect-tickets  (P0-3: 两阶段建单, 对齐 4.3「DRAFT 建单未归因」+ AC-DT-03)
--   req : {exam_profile_id,question_id,knowledge_node_id,q_type,
--          [error_layer,error_cause,actions,verification_plan]}  <- 归因字段可选
--   res : 201 {id,status:"DRAFT"}        <- 未带归因: 仅登记错题, error_layer/error_cause 可为 NULL
--         201 {id,status:"ANALYZED",priority,verification_state}  <- 带完整归因: 直接分析
-- POST /defect-tickets/{id}/analyze  (DRAFT/REOPENED -> ANALYZED, 补齐归因; 重归因开启新一轮)
--   req : {error_layer,error_cause,actions,verification_plan}
--   res : 200 {status:"ANALYZED",priority,verification_round}
--   校验: error_cause 命中禁用语 -> 400 {error:"forbidden_phrase"};
--         转 ANALYZED 缺 error_layer/error_cause -> 400 {error:"missing_error_layer_or_cause"}
--         (DB 触发器 trg_defect_phrase 同步兜底: DRAFT 放行 / 转 ANALYZED 强制归因+禁禁用语)
--         REOPENED -> ANALYZED 时 verification_round+1 (P0-2), 新 round 可重走 V1/V2/V3, 历史保留
--
-- POST /verifications  (规范路径; Node 骨架另提供 POST /defect-tickets/{id}/verifications 等价别名)
--   req : {defect_ticket_id,stage:V1|V2|V3,verify_type,question_id,result,evidence}
--   res : 200 {status,verification_state}  (PG 目标契约; Node 骨架返回 201 {ticket,verification})
--         result=fail -> status:"REOPENED"(触发器累加 reopen_count)
--         stage V1 pass -> status:"V2"; V2 pass -> "V3"; V3 pass -> "CLOSED"
--   并发保护: 每 (defect_ticket_id, stage, round) 唯一, 重复提交冲突返回 409;
--             重开(REOPENED->ANALYZED)后 verification_round+1, 新 round 可重新走 V1/V2/V3, 历史验证记录保留
--
-- GET /mock-exams/{id}/report
--   res : {module_accuracy:{...},avg_duration_ms:{...},
--          stability:{cv_3run},defect_repeat_rate,leak_rate}
--   leak_rate 仅主观题模考非空; 正确率结合 difficulty 计算
--
-- GET /review-cycles?type=weekly
--   res : {period,open_defects,layer_dist:{layer:count},verify_pass_rate,completed}
-- ============================================================================

-- ============================================================================
-- 附录(续): BYOK 与 AI 生成题契约 (对齐第7节 BYOK 架构)
-- ----------------------------------------------------------------------------
-- POST /user-model-credentials        (AI-05)
--   req : {provider, model_name, base_url?, api_key(明文, 仅本次传输)}
--   res : 201 {id, key_preview, status:"active"}   -- api_key 立即 KMS 加密, 不回明文
--   revoke: PATCH {id} status->"revoked"           -- 撤销语义, 立即停止调用
--
-- POST /ai/questions:generate         (BE-10, 需用户 BYOK 配置)
--   req : {subject_id, knowledge_node_id, type, count(1–20), prompt_version}
--   res : 202 {job_id, status:"pending"}            -- 异步生成→结构化→验证队列
--   约束: count 范围 1–20, 超出返回 400 (防止打爆模型 API 与审核队列)
--         (管线借鉴 PrepDojo: 生成→结构化→验证→入库, 入库前加本平台的用户确认审核环节)
--   GET  /ai/questions:review-queue
--   res : [{job_id, question_draft(stem/options/answer), generation_meta:{model,prompt_version}}]
--   POST /ai/questions:review/{job_id}  body:{decision:'approved'|'rejected'}
--         approved -> 写入 questions(source='ai_generated', generation_meta.review_status='approved')
--         rejected -> 丢弃草稿, generation_meta.review_status='rejected'(仅留审计)
--   约束: count 范围 1–20, 超出返回 400 (防止打爆模型 API 与审核队列);
--         无有效 user_model_credentials 时, 所有 AI 接口返回 402/503 "BYOK_REQUIRED";
--         平台不代付, 核心闭环(目标/缺陷/验证/复盘)完全不依赖 AI。
-- ============================================================================

-- ============================================================================
-- 附录: 建表后验证 SQL (BE-00 收尾自检)
--   执行: psql -f schema.sql  (本段在末尾自动运行)  或单独 psql -f 本段
--   期望: 打印 SCHEMA_VERIFY_OK; 任一失败则 RAISE EXCEPTION (中断迁移, 配合 ON_ERROR_STOP=1)
--   检查项: 关键表存在 / ai_generation_jobs.status 任务态且不含凭证态 /
--           user_model_credentials.status 四态齐全 / 触发器生效 / 乐观锁字段存在
-- ============================================================================
DO $$
DECLARE
  v_cnt     int;
  v_def     text;
  v_trig    int;
  v_missing text[] := '{}';
  v_bad     text[] := '{}';
BEGIN
  -- 1) 关键表存在性
  SELECT count(*) INTO v_cnt FROM pg_tables
   WHERE schemaname='public' AND tablename IN
     ('users','user_model_credentials','ai_generation_jobs','defect_tickets','subjective_rubric_points');
  IF v_cnt <> 5 THEN
    v_missing := v_missing || format('key_tables_missing (found %s/5)', v_cnt);
  END IF;

  -- 2) ai_generation_jobs.status: 含任务态, 且不含凭证态混入
  --    按约束名精确匹配 chk_aijob_status (避免 ILIKE '%status%' 在多 CHECK 约束时的非确定性)
  SELECT pg_get_constraintdef(c.oid) INTO v_def
    FROM pg_constraint c
   WHERE c.conname='chk_aijob_status';
  IF v_def IS NULL THEN
    v_missing := v_missing || 'ai_generation_jobs.status CHECK 缺失';
  ELSE
    IF v_def NOT ILIKE '%pending_review%' OR v_def NOT ILIKE '%validation_failed%'
       OR v_def NOT ILIKE '%approved%' OR v_def NOT ILIKE '%rejected%' THEN
      v_missing := v_missing || 'ai_generation_jobs.status 任务态不全';
    END IF;
    IF v_def ILIKE '%credential_invalid%' OR v_def ILIKE '%''cooldown''%' THEN
      v_bad := v_bad || 'ai_generation_jobs.status 误含凭证态(credential_invalid/cooldown)';
    END IF;
  END IF;

  -- 3) user_model_credentials.status 四态齐全 (按约束名精确匹配 chk_umc_status)
  SELECT pg_get_constraintdef(c.oid) INTO v_def
    FROM pg_constraint c
   WHERE c.conname='chk_umc_status';
  IF v_def IS NULL OR v_def NOT ILIKE '%active%' OR v_def NOT ILIKE '%revoked%'
     OR v_def NOT ILIKE '%deprecated%' OR v_def NOT ILIKE '%cooldown%' THEN
    v_missing := v_missing || 'user_model_credentials.status 四态不全';
  END IF;

  -- 4) 触发器存在且生效
  SELECT count(*) INTO v_trig FROM pg_trigger
   WHERE tgrelid='defect_tickets'::regclass AND tgname='trg_defect_transition' AND NOT tgisinternal;
  IF v_trig = 0 THEN v_missing := v_missing || 'trg_defect_transition 缺失'; END IF;
  SELECT count(*) INTO v_trig FROM pg_trigger
   WHERE tgrelid='defect_tickets'::regclass AND tgname='trg_defect_phrase' AND NOT tgisinternal;
  IF v_trig = 0 THEN v_missing := v_missing || 'trg_defect_phrase 缺失'; END IF;
  SELECT count(*) INTO v_trig FROM pg_trigger
   WHERE tgrelid='user_model_credentials'::regclass AND tgname='trg_umc_revoked' AND NOT tgisinternal;
  IF v_trig = 0 THEN v_missing := v_missing || 'trg_umc_revoked 缺失'; END IF;

  -- 6.1) ai_generation_jobs 须挂 set_updated 触发器 (否则 version 永不递增, 乐观锁静默失效, 违反 offline-sync 409 仲裁约定)
  SELECT count(*) INTO v_trig FROM pg_trigger t
   JOIN pg_proc p ON p.oid = t.tgfoid
   WHERE t.tgrelid='ai_generation_jobs'::regclass AND t.tgname='trg_ai_generation_jobs_upd'
     AND NOT t.tgisinternal AND p.proname='set_updated';
  IF v_trig = 0 THEN
    v_missing := v_missing || 'trg_ai_generation_jobs_upd 缺失或未指向 set_updated()(乐观锁失效)';
  END IF;

  -- 5) 乐观锁字段存在(冲突仲裁)
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_name='defect_tickets' AND column_name='version') THEN
    v_missing := v_missing || 'defect_tickets.version 缺失(乐观锁)';
  END IF;

  -- 6.2) P0-2: 验证轮次字段存在(重开后 (stage,round) 可重复插入, 保留历史验证证据)
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_name='defect_tickets' AND column_name='verification_round') THEN
    v_missing := v_missing || 'defect_tickets.verification_round 缺失(重开轮次)';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_name='verifications' AND column_name='round') THEN
    v_missing := v_missing || 'verifications.round 缺失';
  END IF;

  -- 6.3) P0-2: 唯一索引须含 round 维度, 否则重开后无法再插 V1/V2 且丢历史证据
  IF NOT EXISTS (SELECT 1 FROM pg_indexes
                 WHERE schemaname='public' AND indexname='idx_ver_dt_stage'
                   AND indexdef ILIKE '%round%') THEN
    v_bad := v_bad || 'idx_ver_dt_stage 未含 round 维度(重开会丢验证历史)';
  END IF;

  -- 6) questions.generation_meta 列存在(AI 生成题可追溯标记)
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_name='questions' AND column_name='generation_meta') THEN
    v_missing := v_missing || 'questions.generation_meta 缺失';
  END IF;

  -- 7) ai_generation_jobs.credential_status 列存在(凭证态与任务态分离)
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_name='ai_generation_jobs' AND column_name='credential_status') THEN
    v_missing := v_missing || 'ai_generation_jobs.credential_status 缺失';
  END IF;

  -- 8) idx_umc_one_active 部分唯一索引存在(每用户至多一个 active 凭证)
  IF NOT EXISTS (SELECT 1 FROM pg_indexes
                 WHERE schemaname='public' AND indexname='idx_umc_one_active') THEN
    v_missing := v_missing || 'idx_umc_one_active 索引缺失';
  END IF;

  -- 9) normalize_question_text 冒烟测试 (防 translate 错位导致静默错 hash: 等价输入必须产出相同指纹)
  --    全角标点 vs 半角 必须归一一致; 含空白 vs 去空白 必须一致; 否则导入去重会漏判且不报错
  IF normalize_question_text('你好，世界。测试：A（B）【C】', NULL, NULL)
     <> normalize_question_text('你好,世界.测试:A(B)[C]', NULL, NULL) THEN
    v_bad := v_bad || 'normalize_question_text 全角/半角归一不一致(translate 可能错位)';
  END IF;
  IF normalize_question_text('a  b  c', NULL, NULL)
     <> normalize_question_text('abc', NULL, NULL) THEN
    v_bad := v_bad || 'normalize_question_text 空白未归一';
  END IF;
  -- 9.1) 顿号必须映射为半角逗号(保留并列分隔), 不得被删除(否则"甲、乙"与"甲乙"去重误合并)
  IF normalize_question_text('甲、乙', NULL, NULL)
     <> normalize_question_text('甲,乙', NULL, NULL) THEN
    v_bad := v_bad || 'normalize_question_text 顿号未映射为逗号';
  END IF;
  IF normalize_question_text('甲、乙', NULL, NULL)
     = normalize_question_text('甲乙', NULL, NULL) THEN
    v_bad := v_bad || 'normalize_question_text 顿号被删除(导致"甲、乙"与"甲乙"误合并)';
  END IF;

  -- 9.2) A2: 全角空格(U+3000)显式删除, 与 Node 端一致(排版噪声不进入 hash)
  IF normalize_question_text('甲　乙', NULL, NULL)
     <> normalize_question_text('甲乙', NULL, NULL) THEN
    v_bad := v_bad || 'normalize_question_text 全角空格未显式删除';
  END IF;

  -- 10) A3: 命名 CHECK 约束按 conname 精确匹配(凭证态快照 / 主观题权重非负)
  SELECT pg_get_constraintdef(c.oid) INTO v_def
    FROM pg_constraint c
   WHERE c.conname='chk_aijob_cred_status' AND c.conrelid='ai_generation_jobs'::regclass;
  IF v_def IS NULL OR v_def NOT ILIKE '%credential_status%' THEN
    v_missing := v_missing || 'chk_aijob_cred_status 命名约束缺失';
  END IF;
  SELECT pg_get_constraintdef(c.oid) INTO v_def
    FROM pg_constraint c
   WHERE c.conname='chk_rubric_weight' AND c.conrelid='subjective_rubric_points'::regclass;
  IF v_def IS NULL OR v_def NOT ILIKE '%weight%' THEN
    v_missing := v_missing || 'chk_rubric_weight 命名约束缺失';
  END IF;

  IF array_length(v_missing,1) IS NULL AND array_length(v_bad,1) IS NULL THEN
    RAISE NOTICE 'SCHEMA_VERIFY_OK: 表/枚举/触发器/乐观锁 自检通过';
  ELSE
    RAISE EXCEPTION 'SCHEMA_VERIFY_FAILED missing=% bad=%', v_missing, v_bad;
  END IF;
END $$;
