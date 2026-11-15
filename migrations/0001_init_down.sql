-- ============================================================================
-- 迁移 0001 (down): 回滚初始建表 (BE-00 反向)
--   执行: psql -v ON_ERROR_STOP=1 -f migrations/0001_init_down.sql
-- 说明: 子表在前、父表在后 CASCADE 删除; 再删自定义函数与枚举类型。
--   注: 仅删除本项目对象, 不影响其它 schema。本地 Flutter 表(local_ai_task_queue /
--   local_credential_cache) 由客户端迁移自行管理, 不在此处删除。
-- ============================================================================

DROP TABLE IF EXISTS
  subjective_rubric_points,
  verifications,
  actions,
  defect_tickets,
  attempts,
  mock_exams,
  ai_generation_jobs,
  questions,
  knowledge_nodes,
  subjects,
  exam_profiles,
  user_model_credentials,
  review_cycles,
  plans,
  capability_layers,
  assets,
  users
CASCADE;

DROP FUNCTION IF EXISTS set_updated() CASCADE;
DROP FUNCTION IF EXISTS check_defect_transition() CASCADE;
DROP FUNCTION IF EXISTS check_defect_forbidden_phrase() CASCADE;
DROP FUNCTION IF EXISTS set_revoked_at() CASCADE;
DROP FUNCTION IF EXISTS normalize_question_text(text, jsonb, text) CASCADE;

DROP TYPE IF EXISTS
  defect_status,
  priority_level,
  verify_stage,
  verify_type,
  verify_result,
  exam_type,
  subject_kind,
  question_source,
  difficulty,
  user_role,
  cycle_type,
  plan_generated_by,
  asset_owner,
  cred_provider
CASCADE;
