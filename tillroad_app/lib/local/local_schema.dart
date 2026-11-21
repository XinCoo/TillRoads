// 本地 SQLite 的表结构与建表脚本（本地优先架构 R1）。
//
// 字段与索引严格对齐 docs/local-first-design.md 的 §2.1 通用约定 / §2.3 逐表字段：
//   T1 exam_profiles      ← 设计 §2.3 T1
//   T2 subjects           ← 设计 §2.3 T2
//   T3 knowledge_nodes    ← 设计 §2.3 T3
//   T4 defect_tickets     ← 设计 §2.3 T4（精简：不落 actions jsonb /
//                            verification_state / JOIN 展示字段 / deleted_at）
//   T5 actions            ← 设计 §2.3 T5（云端表名 actions，非 defect_actions）
//   T6 verifications      ← 设计 §2.3 T6
//   T8 mock_exams         ← 设计 §2.3 T8
//   T9 review_cycles      ← 设计 §2.3 T9
//   T10 pending_operations← 设计 §2.3 T10
//   T11 sync_state        ← **R1 改为 local_meta（key/value）**，见下
//
// 与设计文档的两处有意偏差（都记在文档末尾的「R1 实现记录」里）：
//   ① 不建 T7 questions_cache —— 任务书拍板「R1 不建，R5 按报告页实际需要再定」。
//   ② T11 sync_state（每资源一行的水位表）改为 local_meta（通用 key/value）：
//      任务书 B2 明确要求 local_meta 存 token_fingerprint / last_sync_at / schema_version。
//      单用户单设备场景下，同步水位一共就 6 个资源 × 5 个字段，用 key/value 表达
//      （`sync.<resource>.<field>`）省一张表、少一套 DAO，语义不损失。
//      代价：无法用 SQL 直接汇总「哪些资源还没拉过」，R3 里用一次 LIKE 查询即可。
//
// 命名约定（与设计 §2.1 一致）：
//   · 同步元数据三列 `local_id`(PK) / `server_id`(UNIQUE NULL) / `sync_state`(INT)
//     只加在「可能离线创建」的表上；纯目录表与纯云端表用 server_id 直接当主键。
//   · 时间一律 TEXT（ISO 8601 UTC），日期用 `YYYY-MM-DD`。
//   · 布尔一律 INTEGER 0/1（SQLite 没有 bool）。
//   · 枚举一律 TEXT，取值与 schema.sql 的 enum 逐字一致。

/// 本地库 schema 版本。改表结构必须 +1 并在 [LocalSchema.onUpgrade] 里加迁移。
const int kLocalSchemaVersion = 1;

/// 建表语句：顺序即执行顺序（无外键约束，故顺序只影响可读性）。
///
/// 为什么**不**声明 `FOREIGN KEY`：
///   本地表是「云端表的投影 + 待发送队列」，父子行的到达顺序由同步过程决定
///   （例如离线建的单会先有 defect_tickets 行、服务端回填 server_id 后才补齐子表）。
///   硬外键会让「先落父后落子」的中间态直接写失败，而 SQLite 又无法在不重建表的前提下
///   临时关掉约束。一致性改由 DAO 层与 R3 的对账保证（设计 §3.5 / §3.6 的 6 条不变量）。
const List<String> kLocalSchemaStatements = <String>[
  // ── T11 local_meta ────────────────────────────────────────────────────────
  // 通用 key/value：token_fingerprint / schema_version / sync.<resource>.<field>
  // 为什么用 TEXT 存所有值：只有少数几个键需要被解析，统一 TEXT 省掉类型分支；
  // 需要数字时由 DAO 侧 `int.tryParse` 兜底。
  '''
CREATE TABLE local_meta (
  key        TEXT PRIMARY KEY,
  value      TEXT,
  updated_at TEXT NOT NULL
)''',

  // ── T1 exam_profiles ──────────────────────────────────────────────────────
  // 设计 §2.3 T1。deleted_at 不落本地（服务端软删 = 本地删行）。
  '''
CREATE TABLE exam_profiles (
  local_id       TEXT PRIMARY KEY,
  server_id      TEXT,
  sync_state     INTEGER NOT NULL DEFAULT 0,
  user_id        TEXT NOT NULL,
  exam_type      TEXT,
  target_label   TEXT,
  target_score   REAL,
  subject_target TEXT,
  exam_date      TEXT,
  daily_minutes  INTEGER,
  source_scope   TEXT,
  baseline       TEXT,
  status         TEXT,
  created_at     TEXT,
  updated_at     TEXT,
  version        INTEGER NOT NULL DEFAULT 1
)''',

  // ── T2 subjects ───────────────────────────────────────────────────────────
  // 设计 §2.3 T2：纯目录表，永不在本地创建 → exam_profile_id 直接存云端 id。
  '''
CREATE TABLE subjects (
  local_id        TEXT PRIMARY KEY,
  server_id       TEXT,
  sync_state      INTEGER NOT NULL DEFAULT 0,
  exam_profile_id TEXT NOT NULL,
  name            TEXT NOT NULL,
  kind            TEXT,
  layer_template_id TEXT,
  created_at      TEXT,
  updated_at      TEXT,
  version         INTEGER NOT NULL DEFAULT 1
)''',

  // ── T3 knowledge_nodes ────────────────────────────────────────────────────
  // 设计 §2.3 T3：纯目录表，parent_id 自关联（存云端 id）。
  '''
CREATE TABLE knowledge_nodes (
  local_id        TEXT PRIMARY KEY,
  server_id       TEXT,
  sync_state      INTEGER NOT NULL DEFAULT 0,
  subject_id      TEXT NOT NULL,
  title           TEXT NOT NULL,
  parent_id       TEXT,
  freq_tag        TEXT,
  weight_to_target REAL NOT NULL DEFAULT 0,
  created_at      TEXT,
  updated_at      TEXT,
  version         INTEGER NOT NULL DEFAULT 1
)''',

  // ── T4 defect_tickets ─────────────────────────────────────────────────────
  // 设计 §2.3 T4。比云端少 4 类列（见文件头注释）：
  //   · actions jsonb          → 子表 actions
  //   · verification_state     → 子表 verifications
  //   · JOIN 展示字段          → 本地 JOIN knowledge_nodes/subjects
  //   · deleted_at             → 软删即删行
  // error_layer / error_cause 允许 NULL：DRAFT 态允许未归因（schema P0-3 同语义）。
  '''
CREATE TABLE defect_tickets (
  local_id          TEXT PRIMARY KEY,
  server_id         TEXT,
  sync_state        INTEGER NOT NULL DEFAULT 0,
  user_id           TEXT NOT NULL,
  exam_profile_id   TEXT,
  knowledge_node_id TEXT,
  question_id       TEXT,
  q_type            TEXT,
  error_layer       TEXT,
  error_cause       TEXT,
  priority          TEXT,
  status            TEXT NOT NULL DEFAULT 'DRAFT',
  verification_round INTEGER NOT NULL DEFAULT 1,
  reopen_count      INTEGER NOT NULL DEFAULT 0,
  reopen_reason     TEXT,
  closed_at         TEXT,
  created_at        TEXT,
  updated_at        TEXT,
  version           INTEGER NOT NULL DEFAULT 1
)''',

  // ── T5 actions ────────────────────────────────────────────────────────────
  // 设计 §2.3 T5。外键指向 defect_tickets.local_id（不是 server_id），
  // 这样离线建单时子行无需等云端回填。
  '''
CREATE TABLE actions (
  local_id               TEXT PRIMARY KEY,
  server_id              TEXT,
  sync_state             INTEGER NOT NULL DEFAULT 0,
  defect_ticket_local_id TEXT NOT NULL,
  content                TEXT NOT NULL,
  done                   INTEGER NOT NULL DEFAULT 0,
  due                    TEXT,
  created_at             TEXT,
  updated_at             TEXT,
  version                INTEGER NOT NULL DEFAULT 1
)''',

  // ── T6 verifications ──────────────────────────────────────────────────────
  // 设计 §2.3 T6。round 参与唯一索引，与云端 idx_ver_dt_stage 同构。
  '''
CREATE TABLE verifications (
  local_id               TEXT PRIMARY KEY,
  server_id              TEXT,
  sync_state             INTEGER NOT NULL DEFAULT 0,
  defect_ticket_local_id TEXT NOT NULL,
  stage                  TEXT NOT NULL,
  round                  INTEGER NOT NULL DEFAULT 1,
  verify_type            TEXT,
  question_id            TEXT,
  result                 TEXT NOT NULL DEFAULT 'pending',
  evidence               TEXT,
  verified_at            TEXT,
  created_at             TEXT,
  version                INTEGER NOT NULL DEFAULT 1
)''',

  // ── T8 mock_exams ─────────────────────────────────────────────────────────
  // 设计 §2.3 T8。卷子永远在云端创建 → server_id 当主键，无 local_id。
  // questions 存的是「条目」JSON（question_id/attempt_id/is_correct/duration_ms），
  // 不是题面（R1 不建 questions_cache，题面不入库）。
  '''
CREATE TABLE mock_exams (
  server_id          TEXT PRIMARY KEY,
  sync_state         INTEGER NOT NULL DEFAULT 0,
  exam_profile_id    TEXT,
  mode               TEXT,
  duration_limit_ms  INTEGER,
  questions          TEXT,
  report             TEXT,
  submitted_at       TEXT,
  created_at         TEXT,
  updated_at         TEXT,
  version            INTEGER NOT NULL DEFAULT 1
)''',

  // ── T9 review_cycles ──────────────────────────────────────────────────────
  // 设计 §2.3 T9。复盘在云端生成 → server_id 当主键，无 local_id。
  '''
CREATE TABLE review_cycles (
  server_id   TEXT PRIMARY KEY,
  sync_state  INTEGER NOT NULL DEFAULT 0,
  user_id     TEXT,
  cycle_type  TEXT,
  period      TEXT,
  metrics     TEXT,
  completed   INTEGER NOT NULL DEFAULT 0,
  created_at  TEXT,
  updated_at  TEXT,
  version     INTEGER NOT NULL DEFAULT 1
)''',

  // ── T10 pending_operations ────────────────────────────────────────────────
  // 设计 §2.3 T10 + 任务书 B2 的字段名。R1 只建表与 CRUD，**不实现推送**（R4）。
  //   · op_id AUTOINCREMENT 保证单调递增 = 全局发送顺序（设计 §3.6 不变量 1）
  //   · path_template 存占位符形式，推送时用 server_id 替换（设计 §3.2 关键点 2）
  //   · base_version 可 NULL：POST 建单时服务端不收版本
  //   · status: 0=pending 1=inflight 2=failed_retryable 3=conflict 4=dead
  '''
CREATE TABLE pending_operations (
  op_id           INTEGER PRIMARY KEY AUTOINCREMENT,
  entity_type     TEXT NOT NULL,
  entity_local_id TEXT NOT NULL,
  operation       TEXT NOT NULL,
  path_template   TEXT NOT NULL,
  payload         TEXT NOT NULL DEFAULT '{}',
  base_version    INTEGER,
  status          INTEGER NOT NULL DEFAULT 0,
  retry_count     INTEGER NOT NULL DEFAULT 0,
  next_retry_at   TEXT,
  last_error      TEXT,
  created_at      TEXT NOT NULL
)''',

  // ── 索引 ──────────────────────────────────────────────────────────────────
  // 全部来自设计 §2.3 各表的「索引」小节。唯一索引都带 WHERE server_id IS NOT NULL：
  //   SQLite 的 UNIQUE 允许多个 NULL，显式声明意图更清楚，也避免未来换成
  //   `CREATE UNIQUE INDEX ... WHERE` 时行为突变。

  // T1
  'CREATE UNIQUE INDEX IF NOT EXISTS ux_ep_server ON exam_profiles(server_id) WHERE server_id IS NOT NULL',
  'CREATE INDEX IF NOT EXISTS idx_ep_user ON exam_profiles(user_id, status)',

  // T2
  'CREATE UNIQUE INDEX IF NOT EXISTS uq_sub_server ON subjects(server_id) WHERE server_id IS NOT NULL',
  'CREATE INDEX IF NOT EXISTS idx_sub_ep ON subjects(exam_profile_id)',

  // T3
  'CREATE UNIQUE INDEX IF NOT EXISTS uq_kn_server ON knowledge_nodes(server_id) WHERE server_id IS NOT NULL',
  'CREATE INDEX IF NOT EXISTS idx_kn_subject ON knowledge_nodes(subject_id)',
  'CREATE INDEX IF NOT EXISTS idx_kn_parent ON knowledge_nodes(parent_id)',

  // T4 —— idx_dt_created 的列顺序必须与服务端 `ORDER BY dt.created_at ASC, dt.id ASC` 一致，
  // 否则列表顺序会在接页面后跳变（设计 §2.3 T4 的说明）。
  'CREATE UNIQUE INDEX IF NOT EXISTS ux_dt_server ON defect_tickets(server_id) WHERE server_id IS NOT NULL',
  'CREATE INDEX IF NOT EXISTS idx_dt_user_status ON defect_tickets(user_id, status)',
  'CREATE INDEX IF NOT EXISTS idx_dt_created ON defect_tickets(created_at ASC, local_id ASC)',
  'CREATE INDEX IF NOT EXISTS idx_dt_node ON defect_tickets(knowledge_node_id)',
  'CREATE INDEX IF NOT EXISTS idx_dt_sync ON defect_tickets(sync_state)',

  // T5
  'CREATE UNIQUE INDEX IF NOT EXISTS uq_act_server ON actions(server_id) WHERE server_id IS NOT NULL',
  'CREATE INDEX IF NOT EXISTS idx_act_ticket ON actions(defect_ticket_local_id)',

  // T6 —— 与云端 idx_ver_dt_stage 同构：同单同阶段同轮次只能有一条
  'CREATE UNIQUE INDEX IF NOT EXISTS uq_ver_server ON verifications(server_id) WHERE server_id IS NOT NULL',
  'CREATE UNIQUE INDEX IF NOT EXISTS ux_ver_ticket_stage_round ON verifications(defect_ticket_local_id, stage, round)',
  'CREATE INDEX IF NOT EXISTS idx_ver_ticket ON verifications(defect_ticket_local_id)',

  // T8
  'CREATE INDEX IF NOT EXISTS idx_me_profile ON mock_exams(exam_profile_id, created_at DESC)',

  // T9 —— 对齐云端 idx_rc_user(user_id, cycle_type, period)
  'CREATE UNIQUE INDEX IF NOT EXISTS uq_rc_user_type_period ON review_cycles(user_id, cycle_type, period)',
  'CREATE INDEX IF NOT EXISTS idx_rc_period ON review_cycles(period DESC)',

  // T10 —— 出队查询是「按 status + next_retry_at 取最早一条」
  'CREATE INDEX IF NOT EXISTS idx_po_status_next ON pending_operations(status, next_retry_at)',
  'CREATE INDEX IF NOT EXISTS idx_po_entity ON pending_operations(entity_type, entity_local_id, op_id)',
];

/// `CREATE TABLE` 的表名清单：供测试断言「10 张表都在」，也供 [LocalDb] 的自检日志用。
const List<String> kLocalTableNames = <String>[
  'local_meta',
  'exam_profiles',
  'subjects',
  'knowledge_nodes',
  'defect_tickets',
  'actions',
  'verifications',
  'mock_exams',
  'review_cycles',
  'pending_operations',
];

/// 索引名清单：供测试断言索引数量与命名。
const List<String> kLocalIndexNames = <String>[
  'ux_ep_server',
  'idx_ep_user',
  'uq_sub_server',
  'idx_sub_ep',
  'uq_kn_server',
  'idx_kn_subject',
  'idx_kn_parent',
  'ux_dt_server',
  'idx_dt_user_status',
  'idx_dt_created',
  'idx_dt_node',
  'idx_dt_sync',
  'uq_act_server',
  'idx_act_ticket',
  'uq_ver_server',
  'ux_ver_ticket_stage_round',
  'idx_ver_ticket',
  'idx_me_profile',
  'uq_rc_user_type_period',
  'idx_rc_period',
  'idx_po_status_next',
  'idx_po_entity',
];
