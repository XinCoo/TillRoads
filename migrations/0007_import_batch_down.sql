-- 题路 TillRoad · 迁移 0007 回滚：题库导入批次
--
-- 回滚顺序：先索引后表（与其它 down 脚本同形），最后删 questions 上的新增列。
-- 全部 IF EXISTS，重复执行不会报错。
--
-- ★ 数据丢失说明（这是有意为之，不是 bug）：
--   本 down 会删掉 import_batches 整表与 questions.batch_id / import_filename /
--   imported_at 三列 —— 即「批次档案」全部消失。
--   已经被软删（deleted_at 非空）的题**不会**因此复活或消失：
--   批次只是筛选维度，题目本体与软删状态都在 questions 里，不受影响。
--   回滚后用户仍能逐题勾选删除，只是不能再按批次整批删。
--
-- ★ 先删索引再删列：DROP COLUMN 本身会连带删掉建在该列上的索引，
--   但显式 DROP INDEX 让脚本在「列已被手工删掉但索引还在」的半途状态也能幂等通过。

DROP INDEX IF EXISTS idx_ib_user_time;
DROP TABLE IF EXISTS import_batches;

DROP INDEX IF EXISTS idx_q_batch;

ALTER TABLE questions DROP COLUMN IF EXISTS imported_at;
ALTER TABLE questions DROP COLUMN IF EXISTS import_filename;
ALTER TABLE questions DROP COLUMN IF EXISTS batch_id;
