-- 题路 TillRoad · 迁移 0002 回滚：移除 questions.owner_user_id
--
-- ★ 幂等：DROP INDEX / DROP COLUMN 都用 IF EXISTS，重复执行不会报错。
--
-- 注意：回滚会**丢掉所有用户私有题的归属信息**（owner_user_id 变成 NULL，
-- 于是这些题会被当成公共题）。生产回滚前请先确认没有需要保留的归属关系。

DROP INDEX IF EXISTS idx_q_owner;

ALTER TABLE questions
  DROP COLUMN IF EXISTS owner_user_id;
