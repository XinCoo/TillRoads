-- 题路 TillRoad · 迁移 0006 回滚：自定义考试类型 + 缺陷单多题关联
--
-- 回滚顺序：先索引后表（与其它 down 脚本同形），再删新增列。
-- 全部 IF EXISTS，重复执行不会报错。
--
-- ★ exam_type 的 'custom' 枚举值**不可回滚**：
--   PostgreSQL 不支持删除枚举值（没有 DROP VALUE），只能「加值」不能「删值」。
--   因此 exam_type 上会**永久保留** 'custom' 这个成员 —— 属向前兼容的加法：
--   它只是多了一个没人用的枚举成员，不影响任何既有查询/写入。
--   本 down 脚本只回滚**结构**（表 / 索引 / 新增列），不动枚举成员。
--
-- ★ 同理，回填进 defect_questions 的历史数据随表一起消失；
--   旧的单值列 defect_tickets.question_id 全程保留（up 未删列，down 也不删），
--   所以回滚后历史缺陷单仍带着原来的单值题目 —— 不丢数据。

DROP INDEX IF EXISTS idx_dq_ticket;
DROP INDEX IF EXISTS uk_defect_question;
DROP TABLE IF EXISTS defect_questions;

ALTER TABLE defect_tickets DROP COLUMN IF EXISTS custom_reason;
ALTER TABLE exam_profiles DROP COLUMN IF EXISTS exam_type_custom;
