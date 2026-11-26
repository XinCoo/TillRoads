-- 题路 TillRoad · 练习模式 R3（m26090）：question_hidden 回滚
--
-- 回滚顺序：先索引后表（与其它 down 脚本同形）。
-- 全部 IF EXISTS，重复执行不会报错。

DROP INDEX IF EXISTS idx_qh_question;
DROP INDEX IF EXISTS idx_qh_user;
DROP TABLE IF EXISTS question_hidden;
