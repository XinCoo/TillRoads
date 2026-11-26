-- 题路 TillRoad · 迁移 0006：自定义考试类型 + 缺陷单多题关联
--
-- 为什么需要这一轮（两件独立的事，凑在一次迁移里）：
--   1) **自定义考试**：exam_type 原本是 5 个固定枚举值
--      (civil_service/postgrad/final_exam/vocational/adult_self_study)，
--      用户遇到模板之外的考试（例如「单位内部晋升考试」）就没有可选项。
--      本轮加枚举值 'custom'，具体名称放到 exam_profiles.exam_type_custom
--      （≤20 字，长度由**后端**校验；DB 层不加 CHECK，避免与后端口径分叉）。
--   2) **缺陷单挂多题**：defect_tickets 原本只有单值列 question_id，
--      一个缺陷单最多挂一道题；而真实场景是「一道错题连带它的同类题 / 变式题」。
--      本轮加关联表 defect_questions（缺陷单 → 题目 一对多）。
--
-- ★ 枚举值 'custom' 的 PG 语义（**不要改这一段**）：
--   PG12 起允许在事务块内执行 `ALTER TYPE ... ADD VALUE`，但**新值在本事务提交前不可用**：
--   同事务内不能拿 'custom' 去 INSERT / UPDATE，也不能拿它做比较或建索引
--   （PG 会报 "unsafe use of new value ... of enum type exam_type"）。
--   所以本文件**绝不往表里写 'custom' 字面量**：
--     * 不给 exam_profiles.exam_type 加 DEFAULT 'custom'（加了会在同事务里炸）；
--     * 不在 INSERT/UPDATE 语句里出现 'custom'。
--   真正写 'custom' 的地方留给下一轮的应用层（POST /exam-profiles 放开 exam_type='custom'），
--   那时该枚举值早已提交，可用。
--
-- ★ 关于 scripts/migrate.mjs 的执行方式（结论已核对 CI）：
--   scripts/migrate.mjs 把 schema.sql + 所有迁移拼成**一条** client.query(sql)；
--   node-postgres 在无参数时走简单查询协议，多条语句会被 PG 包进**一个隐式事务**。
--   隐式事务也是「一个事务」，所以上面「提交前不可用」的约束照样成立 ——
--   结论：本文件不在同事务内使用 'custom'，即可安全通过。
--   CI 用的是 postgres:15（见 .github/workflows/schema-ci.yml 的 services.postgres.image），
--   PG15 ≥ PG12，具备「事务内 ADD VALUE」语义；若本机是 PG11 及更早，
--   `ALTER TYPE ... ADD VALUE` 会因「cannot run inside a transaction block」失败，
--   此时需单独执行该语句（见文件末尾说明）。
--
-- ★ 旧的单值列 defect_tickets.question_id **保留不删**：
--   本轮不破坏既有契约（前端与已有集成测试仍在读写它）。
--   回填语句把历史缺陷单的单值题目复制进 defect_questions，
--   让历史单在新的「关联题目列表」里**可见**；
--   后续 R 轮再决定是否废弃 defect_tickets.question_id
--   （那时按「先双写 → 再切读 → 最后删列」的顺序推进，不在本轮做）。
--
-- 幂等：全部 IF NOT EXISTS / ON CONFLICT DO NOTHING，重复执行不会报错。

-- ---------------------------------------------------------------------------
-- 1) exam_type 枚举加 'custom'（见文件头关于「事务内不可用」的说明）
-- ---------------------------------------------------------------------------
ALTER TYPE exam_type ADD VALUE IF NOT EXISTS 'custom';

-- ---------------------------------------------------------------------------
-- 2) 自定义考试名称（≤20 字，后端校验）
-- ---------------------------------------------------------------------------
ALTER TABLE exam_profiles ADD COLUMN IF NOT EXISTS exam_type_custom text;

-- ---------------------------------------------------------------------------
-- 3) 自定义错因文本（≤60 字）
-- ---------------------------------------------------------------------------
ALTER TABLE defect_tickets ADD COLUMN IF NOT EXISTS custom_reason varchar(60);

-- ---------------------------------------------------------------------------
-- 4) 缺陷单 ↔ 题目 的一对多关联表
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS defect_questions (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  defect_ticket_id uuid NOT NULL REFERENCES defect_tickets(id) ON DELETE CASCADE,
  question_id      uuid NOT NULL REFERENCES questions(id),
  sort             int NOT NULL DEFAULT 0,
  created_at       timestamptz NOT NULL DEFAULT now()
);

-- 同一缺陷单内同一道题只挂一次（回填 ON CONFLICT 依赖这个唯一索引）
CREATE UNIQUE INDEX IF NOT EXISTS uk_defect_question ON defect_questions(defect_ticket_id, question_id);

-- 按缺陷单取全部关联题并按 sort 排序（列表页一次查完，避免 N+1）
CREATE INDEX IF NOT EXISTS idx_dq_ticket ON defect_questions(defect_ticket_id, sort);

COMMENT ON TABLE defect_questions IS '缺陷单与题目的一对多关联（旧 defect_tickets.question_id 单值列的替代）';
COMMENT ON COLUMN defect_questions.sort IS '展示顺序（小在前）';

-- ---------------------------------------------------------------------------
-- 5) 旧数据回填：把 defect_tickets.question_id 的单值题目搬进关联表
--    （幂等：ON CONFLICT DO NOTHING；只搬未软删的缺陷单）
-- ---------------------------------------------------------------------------
INSERT INTO defect_questions (defect_ticket_id, question_id, sort)
SELECT id, question_id, 1 FROM defect_tickets
WHERE question_id IS NOT NULL AND deleted_at IS NULL
ON CONFLICT (defect_ticket_id, question_id) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 回滚：migrations/0006_exam_custom_defect_questions_down.sql
--   注意：exam_type 的 'custom' 枚举值**不可回滚**（PG 不支持删除枚举值），
--   属向前兼容的加法。
-- ---------------------------------------------------------------------------
