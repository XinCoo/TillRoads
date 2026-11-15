-- ============================================================================
-- 迁移 0001 (up): 初始建表 (BE-00)
--   单一事实来源: ../schema.sql
--     (含 表 / 枚举 / 函数 / 触发器 / 归一化函数 / 同步与冲突仲裁 / 验证 SQL)
--   本脚本只负责「执行 schema.sql 并触发末尾的验证 SQL」, 不在两处重复维护 DDL。
-- 执行: psql -v ON_ERROR_STOP=1 -f migrations/0001_init_up.sql
-- 期望: 末尾打印 SCHEMA_VERIFY_OK (见 schema.sql 验证附录)
-- ============================================================================
\ir ../schema.sql
-- schema.sql 末尾已包含验证 SQL (DO 块), 执行后会自动打印 SCHEMA_VERIFY_OK; 任一自检项缺失则 RAISE EXCEPTION 中断迁移 (配合 ON_ERROR_STOP=1)。
