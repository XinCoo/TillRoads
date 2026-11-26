-- 题路 TillRoad · 迁移 0004：question_mastery（题目掌握度）
--
-- 背景（m25316 任务书 A1）：
--   练习模式 R1 只做到了「抽题 → 答题 → 判分 → 错题去归因」。
--   用户用了一周后反馈的最强需求是「答对的题我想标一下掌握状态」——
--   因为同一个人同一道题，今天做对了不代表三天后还记得。
--   没有这张表，掌握度只能存在手机本地，换设备就丢，也无法按掌握度筛题。
--
-- 本迁移只做**最小**改动（不改 schema.sql —— 那是 BE-00 冻结的基线）：
--   1. 新建 question_mastery 表：用户 × 题目 的掌握标记（每对唯一）。
--   2. 建两个索引：按用户查自己的掌握记录；按题目查（未来做题目维度的统计用）。
--
-- ★ 幂等：全部用 IF NOT EXISTS，重复执行不会报错、不会重复建表建索引。
--
-- 回滚（down）：migrations/0004_question_mastery_down.sql
--   DROP INDEX IF EXISTS idx_qm_question;
--   DROP TABLE IF EXISTS question_mastery;
--
-- 注意列的语义：
--   * mastered = true  → 用户明确标记「这道题我掌握了」。
--   * mastered = false → 用户明确标记「这道题还没掌握」（会去缺陷单里走一遍归因）。
--   * 表里**没有这一行** = 还没标记过（前端显示灰色「未标记」，
--     与「未掌握」在语义上必须区分开：前者是没管过，后者是管过且没过）。
--   这就是为什么用「行存在与否」而不是把 mastered 设成三态布尔。
--
CREATE TABLE IF NOT EXISTS question_mastery (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES users(id),
  question_id uuid NOT NULL REFERENCES questions(id),
  mastered boolean NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT question_mastery_user_question_key UNIQUE (user_id, question_id)
);

CREATE INDEX IF NOT EXISTS idx_qm_user
  ON question_mastery(user_id);

CREATE INDEX IF NOT EXISTS idx_qm_question
  ON question_mastery(question_id);
