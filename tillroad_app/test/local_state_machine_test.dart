// 本地状态机单元测试（R4a 任务 A2）。
//
// 对齐方式：`core/index.test.mjs` 里与状态机/归因/禁用语/验证推进相关的 10 条用例
// 逐条搬成 Dart 版本（用例名保留「core 同名」的字样），再补上本文件独有的
// `validateVerifyType`、`assertCanBeginVerification`、规则表一致性等用例。
// 目的很直白：**后端把状态机收紧或放宽时，这里必须同时改**，否则离线放过的操作
// 会在联网推送时被 400 拒绝，用户看到的就是「明明点了却同步失败」。

import 'package:flutter_test/flutter_test.dart';
import 'package:tillroad_app/local/local_state_machine.dart';

/// 断言抛出指定业务码的 [LocalValidationException]。
void expectCode(void Function() body, String code) {
  try {
    body();
  } on LocalValidationException catch (e) {
    expect(e.code, code, reason: '业务码不符合预期：${e.code}');
    return;
  }
  fail('期望抛出 LocalValidationException($code)，但没有抛');
}

void main() {
  group('状态机（对齐 core/index.test.mjs）', () {
    test('状态机：合法迁移', () {
      expect(canTransition('DRAFT', 'ANALYZED'), isTrue);
      expect(canTransition('ACTION_DONE', 'V1'), isTrue);
      expect(canTransition('V3', 'CLOSED'), isTrue);
      expect(canTransition('V1', 'REOPENED'), isTrue);
      // assertTransition 合法时不抛、不返回值。
      expect(() => assertTransition('DRAFT', 'ANALYZED'), returnsNormally);
    });

    test('状态机：ACTION_DONE 不能直接 CLOSED（核心不变量 已处理≠已解决）', () {
      expect(canTransition('ACTION_DONE', 'CLOSED'), isFalse);
      expectCode(() => assertTransition('ACTION_DONE', 'CLOSED'), 'ILLEGAL_DEFECT_TRANSITION');
    });

    test('状态机：非法迁移 DRAFT->CLOSED / CLOSED 为终态', () {
      expect(canTransition('DRAFT', 'CLOSED'), isFalse);
      expect(canTransition('CLOSED', 'ANALYZED'), isFalse);
      expect(canTransition('NOPE', 'ANALYZED'), isFalse);
    });

    test('禁用语：命中与未命中', () {
      expect(containsForbiddenPhrase('这次是粗心了'), isTrue);
      expect(containsForbiddenPhrase('概念混淆：把 A 当成 B'), isFalse);
      expect(containsForbiddenPhrase(null), isFalse);
      expect(findForbiddenPhrases('马虎且没掌握'), <String>['马虎', '没掌握']);
      expectCode(() => assertNoForbiddenPhrase('我懂了'), 'FORBIDDEN_PHRASE_IN_ERROR_CAUSE');
    });

    test('归因：转 ANALYZED 必须层级+原因且无禁用语（AC-DT-03 / P0-3）', () {
      expect(
        () => assertAnalyzable(
          status: 'DRAFT',
          errorLayer: 'concept',
          errorCause: '把充分条件当成必要条件',
        ),
        returnsNormally,
      );
      expectCode(
        () => assertAnalyzable(status: 'DRAFT', errorLayer: null, errorCause: 'x'),
        'MISSING_ERROR_LAYER',
      );
      expectCode(
        () => assertAnalyzable(status: 'DRAFT', errorLayer: 'concept', errorCause: '   '),
        'MISSING_ERROR_CAUSE',
      );
      expectCode(
        () => assertAnalyzable(status: 'DRAFT', errorLayer: 'concept', errorCause: '粗心'),
        'FORBIDDEN_PHRASE_IN_ERROR_CAUSE',
      );
      expectCode(
        () => assertAnalyzable(status: 'CLOSED', errorLayer: 'concept', errorCause: 'x'),
        'ILLEGAL_DEFECT_TRANSITION',
      );
    });

    test('验证：V1->V2->V3->CLOSED 全 pass 链路', () {
      expect(
        applyVerification(const LocalTicketState(status: 'V1'), 'V1', 'pass').status,
        'V2',
      );
      expect(
        applyVerification(const LocalTicketState(status: 'V2'), 'V2', 'pass').status,
        'V3',
      );
      expect(
        applyVerification(const LocalTicketState(status: 'V3'), 'V3', 'pass').status,
        'CLOSED',
      );
    });

    test('验证：fail->REOPENED，reopen_count+1，连续重开>=3 提示抽验', () {
      final VerificationDecision r1 = applyVerification(
        const LocalTicketState(status: 'V1', reopenCount: 0),
        'V1',
        'fail',
      );
      expect(r1.status, 'REOPENED');
      expect(r1.reopenCount, 1);
      expect(r1.reopenWarning, isFalse);

      final VerificationDecision r2 = applyVerification(
        const LocalTicketState(status: 'V2', reopenCount: 2),
        'V2',
        'fail',
      );
      expect(r2.reopenCount, 3);
      expect(r2.reopenWarning, isTrue);
    });

    test('验证：阶段不匹配 / 非法结果报错', () {
      expectCode(
        () => applyVerification(const LocalTicketState(status: 'ACTION_DONE'), 'V1', 'pass'),
        'INVALID_VERIFICATION_STAGE',
      );
      expectCode(
        () => applyVerification(const LocalTicketState(status: 'V1'), 'V1', 'maybe'),
        'INVALID_VERIFICATION_RESULT',
      );
    });

    // 口径与 core 不同，必须与*云端端点*对齐：`PATCH /:id/begin-verification`
    // 要求当前是 ANALYZED（它自己在一个事务里做 ANALYZED→ACTION_DONE→V1 两跳）。
    test('beginVerification：仅 ANALYZED->V1（云端端点口径，非 core 的 ACTION_DONE）', () {
      expect(() => assertBeginVerification('ANALYZED'), returnsNormally);
      expectCode(() => assertBeginVerification('DRAFT'), 'ILLEGAL_DEFECT_TRANSITION');
      // 云端端点自己把 ANALYZED 推进到 ACTION_DONE，所以本地不许再收 ACTION_DONE。
      expectCode(() => assertBeginVerification('ACTION_DONE'), 'ILLEGAL_DEFECT_TRANSITION');
      // 非 V1 阶段一律拒绝。
      expectCode(() => assertBeginVerification('ANALYZED', stage: 'V2'), 'INVALID_VERIFICATION_STAGE');
    });

    test('reanalyze：REOPENED->ANALYZED 且 verification_round+1（P0-2 轮次）', () {
      final ReanalyzeDecision r = reanalyze(
        const LocalTicketState(status: 'REOPENED', verificationRound: 2, reopenCount: 3),
      );
      expect(r.status, 'ANALYZED');
      expect(r.verificationRound, 3);
      expect(r.reopenCount, 3);
      // 非 REOPENED 即使迁移本身合法（DRAFT→ANALYZED）也要拒绝。
      expectCode(
        () => reanalyze(const LocalTicketState(status: 'DRAFT')),
        'ILLEGAL_DEFECT_TRANSITION',
      );
    });
  });

  group('进入验证门禁', () {
    test('无动作 -> NO_ACTIONS', () {
      expectCode(
        () => assertCanBeginVerification(const <LocalActionState>[]),
        'NO_ACTIONS',
      );
    });

    test('只有空白动作也算没有动作', () {
      expectCode(
        () => assertCanBeginVerification(const <LocalActionState>[
          LocalActionState(content: '   '),
        ]),
        'NO_ACTIONS',
      );
    });

    test('有未完成动作 -> ACTIONS_NOT_DONE 且带 pendingCount', () {
      try {
        assertCanBeginVerification(const <LocalActionState>[
          LocalActionState(content: '重做第 3 题', done: true),
          LocalActionState(content: '整理错因'),
        ]);
        fail('期望抛 ACTIONS_NOT_DONE');
      } on LocalValidationException catch (e) {
        expect(e.code, 'ACTIONS_NOT_DONE');
        expect(e.details['pendingCount'], 1);
      }
    });

    test('全部完成 -> 通过', () {
      expect(
        () => assertCanBeginVerification(const <LocalActionState>[
          LocalActionState(content: '重做第 3 题', done: true),
          LocalActionState(content: '整理错因', done: true),
        ]),
        returnsNormally,
      );
    });
  });

  group('验证方式白名单', () {
    test('V1 允许 redo_hidden / similar_variant / teach_back', () {
      for (final String type in <String>['redo_hidden', 'similar_variant', 'teach_back']) {
        expect(() => validateVerifyType(stage: 'V1', verifyType: type), returnsNormally);
      }
    });

    test('V1 不允许 new_question / timed_mock', () {
      expectCode(() => validateVerifyType(stage: 'V1', verifyType: 'new_question'), 'INVALID_VERIFY_TYPE');
      expectCode(() => validateVerifyType(stage: 'V1', verifyType: 'timed_mock'), 'INVALID_VERIFY_TYPE');
    });

    test('V2 只允许 new_question', () {
      expect(() => validateVerifyType(stage: 'V2', verifyType: 'new_question'), returnsNormally);
      expectCode(() => validateVerifyType(stage: 'V2', verifyType: 'teach_back'), 'INVALID_VERIFY_TYPE');
    });

    test('V3 允许 timed_mock 与 teach_back（对 core 的刻意放宽）', () {
      expect(() => validateVerifyType(stage: 'V3', verifyType: 'timed_mock'), returnsNormally);
      expect(() => validateVerifyType(stage: 'V3', verifyType: 'teach_back'), returnsNormally);
      expectCode(() => validateVerifyType(stage: 'V3', verifyType: 'peer_check'), 'INVALID_VERIFY_TYPE');
    });

    test('未知阶段 / 未知方式分别报错', () {
      expectCode(() => validateVerifyType(stage: 'V4', verifyType: 'timed_mock'), 'INVALID_VERIFICATION_STAGE');
      expectCode(() => validateVerifyType(stage: 'V1', verifyType: 'nonsense'), 'INVALID_VERIFY_TYPE');
    });
  });

  group('规则表一致性', () {
    test('八态与迁移表键完全覆盖', () {
      expect(kDefectStatuses.length, 8);
      expect(kDefectTransitions.keys.toSet(), kDefectStatuses.toSet());
    });

    test('每个迁移目标都是合法状态', () {
      for (final MapEntry<String, List<String>> e in kDefectTransitions.entries) {
        for (final String to in e.value) {
          expect(kDefectStatuses, contains(to), reason: '${e.key} -> $to 的目标不是合法状态');
        }
      }
    });

    test('禁用语与 schema/core 逐字一致（7 条）', () {
      expect(kForbiddenPhrases, <String>['粗心', '马虎', '没掌握', '我懂了', '大意', '差不多', '忘了']);
    });

    test('CLOSED 是终态', () {
      expect(kDefectTransitions['CLOSED'], isEmpty);
    });

    test('describeLocalStateMachine 能序列化且含关键键', () {
      final String json = describeLocalStateMachine();
      expect(json, contains('transitions'));
      expect(json, contains('forbiddenPhrases'));
      expect(json, contains('stageVerifyTypes'));
    });
  });
}
