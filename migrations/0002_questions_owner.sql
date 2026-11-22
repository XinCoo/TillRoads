-- 题路 TillRoad · 迁移 0002：questions 表加 owner_user_id（题库多用户隔离）
--
-- 背景（m17431 任务书 A1）：
--   BE-02 的导入管线（POST /questions/import）做完后，questions 表是**全局**题库：
--   任何用户导入的题都进同一张表，而 content_hash 查重也是全局的
--   （server/repositories/questions.mjs 的 findHashConflict / server/import/dedupe.mjs
--     都是 `WHERE content_hash = $1 AND deleted_at IS NULL`）。
--   后果有两个：
--     1. 用户 A 导入过的题，用户 B 再导入同一份文件会被判重（duplicates），
--        B 拿不到自己的题 —— 多用户场景下「题库」变成了「第一个人的题库」。
--     2. 组卷抽题时无法区分「公共题」与「别人的私有题」，别人的题也会被抽进卷子。
--
-- 本迁移只做**最小**改动（不改 schema.sql —— 那是 BE-00 冻结的基线）：
--   1. questions 加一列 owner_user_id uuid REFERENCES users(id)；
--      NULL = 公共题（seed 数据、系统题），非 NULL = 该用户私有题。
--   2. 建索引 idx_q_owner，方便按 owner 过滤。
--
-- ★ 幂等：全部用 IF NOT EXISTS，重复执行不会报错、不会重复建索引。
--   PG 12+ 的 `ADD COLUMN IF NOT EXISTS` 会跳过已存在的列，
--   注意它**不会**自动补上列上的约束（这里 owner_user_id 不加 NOT NULL，
--   因为公共题必须是 NULL）。
--
-- 回滚（down）：migrations/0002_questions_owner_down.sql
--   DROP INDEX IF EXISTS idx_q_owner;
--   ALTER TABLE questions DROP COLUMN IF EXISTS owner_user_id;

ALTER TABLE questions
  ADD COLUMN IF NOT EXISTS owner_user_id uuid REFERENCES users(id);

CREATE INDEX IF NOT EXISTS idx_q_owner
  ON questions(owner_user_id)
  WHERE owner_user_id IS NOT NULL;
