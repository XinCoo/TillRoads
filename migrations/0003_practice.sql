-- 题路 TillRoad · 迁移 0003：练习模式（practice sessions）
--
-- 背景（练习模式 R1 任务书）：
--   BE-02 的题库（questions）在 m17431 之后已经做到「公共题 + 用户私有题」分域，
--   但**没有任何地方记录用户练过什么**。模考（mock_exams）是一套完整的考试流程
--   （限时、生成报告、绑定考试目标），不适合「随手练 10 道」这种轻量场景。
--
-- 本迁移只加两张表（不改 schema.sql —— 那是 BE-00 冻结的基线）：
--   1. practice_sessions：一次练习的头（谁、什么范围、抽了几道、对了几道）；
--   2. practice_answers：一次练习里每道题的作答明细（选了什么、对不对、花了多久）。
--
-- ★ 归属：practice_sessions.user_id 存 token 映射出来的 userId，
--   客户端传什么都不认（服务端路由层强制覆盖），这样多用户隔离是数据层保证的，
--   不是「路由层忘了加 where」这种靠自觉的隔离。
--
-- ★ 幂等：全部用 IF NOT EXISTS / DROP IF EXISTS，重复执行不会报错。
--   新增迁移时把文件加进 scripts/migrate.mjs 的 UP_MIGRATIONS 与
--   server/db/test_schema.mjs 的 MIGRATION_FILES（顺序即执行顺序）。
--
-- 回滚（down）：migrations/0003_practice_down.sql

-- ---------------------------------------------------------------------------
-- practice_sessions：一次练习
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS practice_sessions (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id           uuid NOT NULL REFERENCES users(id),
  subject_id        uuid REFERENCES subjects(id),
  knowledge_node_id uuid REFERENCES knowledge_nodes(id),
  source            text,          -- mine | public | all（抽题来源，与 GET /questions/practice 同口径）
  total             int NOT NULL DEFAULT 0,
  correct           int NOT NULL DEFAULT 0,
  wrong             int NOT NULL DEFAULT 0,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  version           int NOT NULL DEFAULT 1,
  deleted_at        timestamptz
);

-- 练习历史按「谁的、最近的」查 —— 复合索引，前导列 user_id 决定归属过滤。
CREATE INDEX IF NOT EXISTS idx_ps_user
  ON practice_sessions(user_id, created_at DESC);

-- ---------------------------------------------------------------------------
-- practice_answers：一次练习里的每道题
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS practice_answers (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id   uuid NOT NULL REFERENCES practice_sessions(id) ON DELETE CASCADE,
  question_id  uuid NOT NULL REFERENCES questions(id),
  user_answer  text,          -- 客户端提交的作答（选项 key / 文本）
  is_correct   boolean,       -- null = 该题没有标准答案（公共题），用户自评
  duration_ms  int,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  version      int NOT NULL DEFAULT 1,
  deleted_at   timestamptz
);

-- 按会话取全部作答（详情页一次查完，避免 N+1）。
CREATE INDEX IF NOT EXISTS idx_pa_session
  ON practice_answers(session_id);
