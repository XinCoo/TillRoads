// 本地库的公开入口（barrel）。
//
// 为什么需要 barrel：R2 起页面会同时用到 `LocalDb`、若干 DAO 与常量，
// 一个 `import 'package:tillroad_app/local/local.dart';` 比 6 行分散 import 好读，
// 也避免页面层出现 `dao/` 这种实现细节路径。

export 'dao/dao_base.dart' show Col, LocalQuery, PendingStatus, SyncState, nowIso, toLocalValue;
export 'dao/local_meta_dao.dart' show LocalMetaDao, MetaKey;
export 'dao/pending_operations_dao.dart' show PendingOperation, PendingOperationsDao;
export 'dao/sync_table_dao.dart' show SyncTableDao;
export 'dao/table_daos.dart'
    show
        ActionsDao,
        DefectTicketsDao,
        ExamProfilesDao,
        KnowledgeNodesDao,
        LocalDaos,
        MockExamsDao,
        ReviewCyclesDao,
        SubjectsDao,
        VerificationsDao;
export 'local_db.dart' show LocalDb, LocalDbInventory;
export 'package:tillroad_app/config/local_config.dart'
    show
        kLocalDbFileName,
        kLocalDbReady,
        kLocalDbUnavailableReason,
        kLocalFirstEnabled;
export 'local_schema.dart'
    show kLocalIndexNames, kLocalSchemaStatements, kLocalSchemaVersion, kLocalTableNames;
export 'verify_window.dart'
    show
        Urgency,
        UrgencyResult,
        computeUrgency,
        computeUrgencyForStage,
        isUrgency,
        isVerifyStage,
        kDayMs,
        kDueSoonDays,
        kVerifyStages,
        kVerifyWindows,
        parseLocalTime,
        windowDaysFor;
export 'first_fill.dart'
    show
        LocalCache,
        ensureInitialData,
        isFirstFillComplete,
        kFillPageSize,
        kLocalDataRevision,
        kFillMaxDetailTickets,
        localDefectCount;
export 'local_refresh.dart'
    show
        checkLocalStatusConsistency,
        clearLocalCache,
        isRefreshingFromCloud,
        kChildRefreshStatuses,
        kMaxChildRefresh,
        kRefreshMaxPages,
        kRefreshPageSize,
        refreshLocalFromCloud;
export 'local_queries.dart'
    show
        loadActiveExamProfile,
        loadDefectStats,
        loadDefectTicketById,
        loadDefectTickets,
        loadExamProfiles,
        loadFirstSubject,
        loadKnowledgeNodes,
        loadVerificationSummary,
        loadVerificationTasks,
        localHasAnyData;
export 'sha256.dart' show Sha256;

export 'local_state_machine.dart'
    show
        LocalActionState,
        LocalTicketState,
        LocalValidationException,
        ReanalyzeDecision,
        VerificationDecision,
        assertAnalyzable,
        assertBeginVerification,
        assertCanBeginVerification,
        assertNoForbiddenPhrase,
        assertTransition,
        applyVerification,
        canTransition,
        containsForbiddenPhrase,
        describeLocalStateMachine,
        findForbiddenPhrases,
        kDefectStatuses,
        kDefectTransitions,
        kForbiddenPhrases,
        kStageVerifyTypes,
        kVerifyResults,
        kVerifyTypes,
        reanalyze,
        validateVerifyType;

export 'write_queue.dart'
    show WriteQueue, WriteQueueResult, WriteQueueStatus, newLocalId;

export 'push_engine.dart'
    show
        PushEngine,
        PushOutcome,
        PushReport,
        PushScheduler,
        kPushBackoffCapSeconds,
        kPushBackoffBaseSeconds,
        kPushMaxRetry;
