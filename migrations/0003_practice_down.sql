-- 题路 TillRoad · 迁移 0003 回滚：删除练习模式的两张表
--
-- 顺序：先子表 practice_answers（它有 FK 指向 practice_sessions），
-- 再父表 practice_sessions。IF EXISTS 保证在「表本来就不存在」时也不报错。
--
-- 注意：practice_answers.session_id 上是 ON DELETE CASCADE，
-- 但先删子表再删父表仍然更直白 —— 回滚脚本要让人一眼看出依赖方向。

DROP INDEX IF EXISTS idx_pa_session;
DROP TABLE IF EXISTS practice_answers;

DROP INDEX IF EXISTS idx_ps_user;
DROP TABLE IF EXISTS practice_sessions;
