-- 题路 TillRoad · 迁移 0007：题库导入批次
--
-- ★ 编号说明：任务书写的是「0006_import_batch.sql」，但 0006 已被
--   migrations/0006_exam_custom_defect_questions.sql 占用（自定义考试类型 +
--   缺陷单多题关联）。迁移编号必须唯一且按序执行，所以本条改用 0007。
--
-- 为什么需要这一轮（用户反馈）：
--   多次导入之后题库变成一锅粥 —— 用户看不出「哪些题是哪一次导进来的」，
--   删错题只能一道一道勾。本轮给每道导入题打上批次标识，
--   前端就能按批次筛选、整批删除。
--
-- 设计取舍：
--   1) questions 上直接加冗余列（batch_id / import_filename / imported_at），
--      而不是只建一张 questions↔batch 关联表。
--      理由：题库列表页按批次过滤是**主路径**，冗余列可以直接走索引
--      `idx_q_batch`，不必每条列表 SQL 都 JOIN 一次关联表；
--      而且「那次导入的文件名 / 时间」属于题目的档案信息，
--      用户删掉 import_batches 行之后仍希望看到「这题是 xxx.json 导进来的」。
--   2) import_batches 存**统计口径**（filename / question_count），
--      供下拉框显示「文件名（N 题）· 相对时间」，避免每次进页面 count(*) 全表。
--   3) batch_id 可空：手动建题（POST /questions）、历史数据、seed 题都没有批次。
--      前端「全部批次」下能看到它们，选中具体批次时看不到 —— 这是预期行为。
--   4) 不建 batch_id 的外键：批次行是「账本」，题行是「数据」，
--      二者生命周期不该强绑（否则删批次记录要先处理题，迁移与清理都会变复杂）。
--      归属一致性由应用层保证 —— 导入时先插批次、再插题，同一事务。
--
-- 幂等：全部 IF NOT EXISTS，重复执行不会报错。

-- ---- 1. questions 上的批次档案列 ----
ALTER TABLE questions
  ADD COLUMN IF NOT EXISTS batch_id uuid;

ALTER TABLE questions
  ADD COLUMN IF NOT EXISTS import_filename text;

ALTER TABLE questions
  ADD COLUMN IF NOT EXISTS imported_at timestamptz;

-- 批次筛选走这条索引；只索引非空值（手动建题 / 历史数据的 batch_id 为 NULL，
-- 它们永远不该被「按批次」查询命中，索引里也不必占位）。
CREATE INDEX IF NOT EXISTS idx_q_batch
  ON questions(batch_id)
  WHERE batch_id IS NOT NULL;

-- ---- 2. 导入批次账本 ----
CREATE TABLE IF NOT EXISTS import_batches (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id        uuid NOT NULL REFERENCES users(id),
  filename       text NOT NULL,
  -- 该批次实际入库的题数（判重跳过的不算）。
  -- 导入开始先插 0，导入结束再 UPDATE 成真实条数 —— 见 server/routes/questions_import.mjs。
  question_count int  NOT NULL DEFAULT 0,
  created_at     timestamptz NOT NULL DEFAULT now()
);

-- 下拉框固定「该用户的批次，按时间倒序」，这条索引刚好覆盖。
CREATE INDEX IF NOT EXISTS idx_ib_user_time
  ON import_batches(user_id, created_at DESC);

COMMENT ON TABLE import_batches IS '题库导入批次（每次导入一行，供前端按批次筛选与整批删除）';
COMMENT ON COLUMN import_batches.question_count IS '该批次实际入库题数（判重跳过的请求不计入）';
COMMENT ON COLUMN questions.batch_id IS '导入批次 id；NULL = 手动建题 / 历史数据 / seed 题';
COMMENT ON COLUMN questions.imported_at IS '该题入库时间（与批次同源，便于按批次内时间排序）';
