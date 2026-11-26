-- 题路 TillRoad · 练习模式 R3（m26090）：题目隐藏表
--
-- 为什么需要这张表：
--   R3 拍板 Q2 —— 公共题（owner_user_id IS NULL）不属于任何用户，
--   所以**不能软删**（软删是把题从整个公共题库里拿走，别人也看不到了）。
--   但用户仍然希望「公共题我不想再看到」。
--   所以给公共题提供一条「只对我隐藏」的通路：question_hidden 记录
--   「哪个用户把哪道题藏起来了」，题本身不动。
--
-- 与 question_mastery（R2）的分工：
--   question_mastery：我的掌握状态（已掌握 / 未掌握 / 未标记），影响练习与筛选。
--   question_hidden：我的可见性偏好（我不想在题库里看到它），只影响列表。
--   两者互不影响：标记「已掌握」不隐藏，隐藏也不改掌握度。
--
-- 软删（questions.deleted_at）仍是「移除」的主手段 —— 它连模考组卷都抽不到。
-- 隐藏只影响题库列表与练习抽题（见 server/repositories/questions.mjs 的过滤）。
--
-- 幂等：全部 IF NOT EXISTS，重复执行不会报错。

CREATE TABLE IF NOT EXISTS question_hidden (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     uuid NOT NULL REFERENCES users(id),
  question_id uuid NOT NULL REFERENCES questions(id),
  hidden_at   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT question_hidden_user_question_key UNIQUE (user_id, question_id)
);

CREATE INDEX IF NOT EXISTS idx_qh_user ON question_hidden(user_id);
CREATE INDEX IF NOT EXISTS idx_qh_question ON question_hidden(question_id);

COMMENT ON TABLE question_hidden IS '用户隐藏的题目（只影响本人可见性；公共题不能软删，只能隐藏）';
COMMENT ON COLUMN question_hidden.hidden_at IS '隐藏时间（用于「最近隐藏」排序）';
