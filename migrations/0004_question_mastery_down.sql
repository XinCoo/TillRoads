-- 题路 TillRoad · 迁移 0004 回滚：question_mastery
--
-- 与 up 严格反向：先删索引再删表（DROP TABLE 会自动带走它上面的索引，
-- 所以先删索引只是为了在「表不存在但索引还在」的半回滚状态下也能跑通）。
--
-- 幂等：DROP ... IF EXISTS，重复执行不报错。
DROP INDEX IF EXISTS idx_qm_question;
DROP INDEX IF EXISTS idx_qm_user;
DROP TABLE IF EXISTS question_mastery;
