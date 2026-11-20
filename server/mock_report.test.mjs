// server/mock_report.test.mjs
// 题路 TillRoad · BE-05 T5：报告生成纯函数单测（零依赖、无 PG、本机可跑）
//
// 覆盖：四项指标 + v3_candidates + 边界（全对 / 全错 / 首次模考 stability=null /
//       无闭合缺陷 repeat_rate=0 / 主观题不计入分母 / 无考点分组兜底）

import test from 'node:test';
import assert from 'node:assert/strict';

import {
  UNGROUPED,
  REPORT_METRICS,
  normalizeAnswerText,
  isAutoGradable,
  gradeAnswer,
  coefficientOfVariation,
  mockAccuracy,
  reportGenerator,
} from './mock_report.mjs';

// ---------------------------------------------------------------------------
// T0 常量
// ---------------------------------------------------------------------------

test('T0 常量：UNGROUPED 是稳定令牌，REPORT_METRICS 恰好四项且不含 strategy_execution', () => {
  assert.equal(UNGROUPED, '__ungrouped__');
  assert.deepEqual([...REPORT_METRICS], [
    'module_accuracy',
    'avg_duration_ms',
    'stability',
    'defect_repeat_rate',
  ]);
  assert.ok(!REPORT_METRICS.includes('strategy_execution'));
  assert.ok(Object.isFrozen(REPORT_METRICS));
});

// ---------------------------------------------------------------------------
// T1 答案归一与判分
// ---------------------------------------------------------------------------

test('T1 normalizeAnswerText：去空白/全半角标点、全角折半、统一大写', () => {
  assert.equal(normalizeAnswerText('A'), 'A');
  assert.equal(normalizeAnswerText(' a '), 'A');
  assert.equal(normalizeAnswerText('Ａ'), 'A'); // 全角 A -> NFKC 折成半角
  assert.equal(normalizeAnswerText('A。'), 'A');
  assert.equal(normalizeAnswerText('A ，B'), 'AB');
  assert.equal(normalizeAnswerText(null), '');
  assert.equal(normalizeAnswerText(undefined), '');
  assert.equal(normalizeAnswerText(''), '');
});

test('T2 gradeAnswer：对/错/未作答/主观题/无标准答案', () => {
  const q = { type: 'choice', answer: 'B' };
  assert.equal(gradeAnswer(q, 'b'), true);
  assert.equal(gradeAnswer(q, 'B '), true);
  assert.equal(gradeAnswer(q, 'C'), false);
  // 有标准答案但未作答 = 错（不是「无法判分」）
  assert.equal(gradeAnswer(q, ''), false);
  assert.equal(gradeAnswer(q, null), false);

  // 主观题：无法自动判分 -> null，不参与正确率分母
  assert.equal(gradeAnswer({ type: 'essay', answer: '要点一' }, '要点一'), null);
  assert.equal(gradeAnswer({ type: 'short_answer', answer: 'x' }, 'x'), null);
  assert.equal(gradeAnswer({ type: 'choice', answer: 'B', is_subjective: true }, 'B'), null);

  // 题库没有标准答案 = 数据缺失，不能判成用户答错
  assert.equal(gradeAnswer({ type: 'choice', answer: null }, 'B'), null);
  assert.equal(gradeAnswer({ type: 'choice', answer: '  ' }, 'B'), null);
});

test('T3 isAutoGradable：主观题型与 is_subjective 标记都拦下', () => {
  assert.equal(isAutoGradable({ type: 'choice' }), true);
  assert.equal(isAutoGradable({ type: 'fill' }), true);
  assert.equal(isAutoGradable({ type: 'essay' }), false);
  assert.equal(isAutoGradable({ type: 'short_answer' }), false);
  assert.equal(isAutoGradable({ type: 'choice', is_subjective: true }), false);
  assert.equal(isAutoGradable({}), true); // 无 type 不拦，交给 answer 是否为空兜底
});

// ---------------------------------------------------------------------------
// T4 变异系数
// ---------------------------------------------------------------------------

test('T4 coefficientOfVariation：全等值 cv=0、均值 0 返回 null、空值 null', () => {
  assert.equal(coefficientOfVariation([0.8, 0.8, 0.8]), 0);
  assert.equal(coefficientOfVariation([]), null);
  assert.equal(coefficientOfVariation([0, 0, 0]), null); // 均值 0，cv 无定义
  // [0.5, 0.6, 0.7]：mean=0.6, sd=sqrt(((0.01+0+0.01)/3))=0.0816496...
  assert.equal(coefficientOfVariation([0.5, 0.6, 0.7]), 0.136083);
  // 非数字被过滤
  assert.equal(coefficientOfVariation([0.8, null, NaN, '0.8', 0.8]), 0);
});

test('T5 mockAccuracy：只数已判分行，全未判分返回 null', () => {
  assert.equal(
    mockAccuracy({ questions: [{ is_correct: true }, { is_correct: false }] }),
    0.5,
  );
  assert.equal(mockAccuracy({ questions: [{ is_correct: true }, { is_correct: true }] }), 1);
  // null（未判分，如主观题）不计入分母
  assert.equal(mockAccuracy({ questions: [{ is_correct: true }, { is_correct: null }] }), 1);
  assert.equal(mockAccuracy({ questions: [{ is_correct: null }] }), null);
  assert.equal(mockAccuracy({ questions: [] }), null);
  assert.equal(mockAccuracy({}), null);
  assert.equal(mockAccuracy({ questions: [null, 'x', 3] }), null);
});

// ---------------------------------------------------------------------------
// T6 module_accuracy + avg_duration_ms
// ---------------------------------------------------------------------------

const Q = (id, kn, title) => ({ question_id: id, knowledge_node_id: kn, knowledge_node_title: title });

test('T6 module_accuracy：按 knowledge_node 分组，正确率与 ungraded 分别计数', () => {
  const questions = [Q('q1', 'kn-a', '函数'), Q('q2', 'kn-a', '函数'), Q('q3', 'kn-b', '几何'), Q('q4', 'kn-b', '几何')];
  const attempts = [
    { question_id: 'q1', is_correct: true, duration_ms: 1000 },
    { question_id: 'q2', is_correct: false, duration_ms: 3000 },
    { question_id: 'q3', is_correct: true, duration_ms: 2000 },
    { question_id: 'q4', is_correct: null, duration_ms: 4000 }, // 主观题
  ];

  const rep = reportGenerator({ questions, attempts });

  assert.equal(rep.module_accuracy['kn-a'].title, '函数');
  assert.equal(rep.module_accuracy['kn-a'].correct, 1);
  assert.equal(rep.module_accuracy['kn-a'].total, 2);
  assert.equal(rep.module_accuracy['kn-a'].accuracy, 0.5);
  assert.equal(rep.module_accuracy['kn-a'].ungraded, 0);

  assert.equal(rep.module_accuracy['kn-b'].correct, 1);
  assert.equal(rep.module_accuracy['kn-b'].total, 1); // q4 未判分，不进分母
  assert.equal(rep.module_accuracy['kn-b'].accuracy, 1);
  assert.equal(rep.module_accuracy['kn-b'].ungraded, 1);

  assert.equal(rep.overall.correct, 2);
  assert.equal(rep.overall.total, 3);
  assert.equal(rep.overall.accuracy, 0.666667);
  assert.equal(rep.overall.ungraded, 1);
  assert.equal(rep.ungraded_count, 1);
});

test('T6b 考点名兼容两种键名：仓储传 title、旧版传 knowledge_node_title 都能取到', () => {
  // 回归锁定：server/repositories/mock_exams.mjs 提交时给 reportGenerator 的题是
  //   { question_id, knowledge_node_id, title }
  // 而本文件旧版只读 knowledge_node_title → module_accuracy[*].title 恒 null，
  // 前端只能显示成「考点 <uuid 前 8 位>」。修正为 q.knowledge_node_title ?? q.title。
  const questions = [
    { question_id: 'q1', knowledge_node_id: 'kn-a', title: '法律常识' },
    { question_id: 'q2', knowledge_node_id: 'kn-b', knowledge_node_title: '行程问题' },
    { question_id: 'q3', knowledge_node_id: 'kn-c', knowledge_node_title: '两者都有', title: '应取前者' },
    { question_id: 'q4', knowledge_node_id: 'kn-d', title: null, knowledge_node_title: null },
  ];
  const attempts = [
    { question_id: 'q1', is_correct: true, duration_ms: 100 },
    { question_id: 'q2', is_correct: true, duration_ms: 100 },
    { question_id: 'q3', is_correct: true, duration_ms: 100 },
    { question_id: 'q4', is_correct: true, duration_ms: 100 },
  ];

  const rep = reportGenerator({ questions, attempts });

  // 只有 title 键（仓储真实形状）
  assert.equal(rep.module_accuracy['kn-a'].title, '法律常识');
  assert.equal(rep.avg_duration_ms.by_knowledge_node['kn-a'].title, '法律常识');
  // 只有 knowledge_node_title 键（旧测试/旧调用方形状）
  assert.equal(rep.module_accuracy['kn-b'].title, '行程问题');
  assert.equal(rep.avg_duration_ms.by_knowledge_node['kn-b'].title, '行程问题');
  // 两者都有时以 knowledge_node_title 优先（向后兼容旧语义）
  assert.equal(rep.module_accuracy['kn-c'].title, '两者都有');
  // 两者都缺仍是 null，不伪造名字
  assert.equal(rep.module_accuracy['kn-d'].title, null);
  assert.equal(rep.avg_duration_ms.by_knowledge_node['kn-d'].title, null);
});

test('T7 avg_duration_ms：按考点平均 + 全卷平均，未判分的题也算用时', () => {
  const questions = [Q('q1', 'kn-a', '函数'), Q('q2', 'kn-a', '函数'), Q('q3', 'kn-b', '几何')];
  const attempts = [
    { question_id: 'q1', is_correct: true, duration_ms: 1000 },
    { question_id: 'q2', is_correct: false, duration_ms: 2001 },
    { question_id: 'q3', is_correct: null, duration_ms: 6001 },
  ];

  const rep = reportGenerator({ questions, attempts });

  assert.equal(rep.avg_duration_ms.by_knowledge_node['kn-a'].avg_duration_ms, 1501); // (1000+2001)/2 四舍五入
  assert.equal(rep.avg_duration_ms.by_knowledge_node['kn-a'].count, 2);
  assert.equal(rep.avg_duration_ms.by_knowledge_node['kn-b'].avg_duration_ms, 6001);
  assert.equal(rep.avg_duration_ms.overall, 3001); // (1000+2001+6001)/3
});

test('T8 无考点的题归到 UNGROUPED，title 为 null', () => {
  const questions = [Q('q1', null, null), Q('q2', 'kn-a', '函数')];
  const attempts = [
    { question_id: 'q1', is_correct: true, duration_ms: 100 },
    { question_id: 'q2', is_correct: false, duration_ms: 200 },
  ];
  const rep = reportGenerator({ questions, attempts });
  assert.ok(Object.prototype.hasOwnProperty.call(rep.module_accuracy, UNGROUPED));
  assert.equal(rep.module_accuracy[UNGROUPED].title, null);
  assert.equal(rep.module_accuracy[UNGROUPED].accuracy, 1);
});

test('T9 全对与全错的极端值', () => {
  const questions = [Q('q1', 'kn-a', 'A'), Q('q2', 'kn-a', 'A')];

  const allRight = reportGenerator({
    questions,
    attempts: [
      { question_id: 'q1', is_correct: true, duration_ms: 10 },
      { question_id: 'q2', is_correct: true, duration_ms: 20 },
    ],
  });
  assert.equal(allRight.overall.accuracy, 1);
  assert.equal(allRight.module_accuracy['kn-a'].accuracy, 1);
  assert.equal(allRight.defect_repeat_rate.total_wrong, 0);
  assert.equal(allRight.defect_repeat_rate.rate, 0);
  assert.deepEqual(allRight.v3_candidates, []);

  const allWrong = reportGenerator({
    questions,
    attempts: [
      { question_id: 'q1', is_correct: false, duration_ms: 10 },
      { question_id: 'q2', is_correct: false, duration_ms: 20 },
    ],
  });
  assert.equal(allWrong.overall.accuracy, 0);
  assert.equal(allWrong.module_accuracy['kn-a'].accuracy, 0);
  assert.equal(allWrong.defect_repeat_rate.total_wrong, 2);
});

test('T10 空卷不抛错：各指标退化而不是 NaN', () => {
  const rep = reportGenerator({});
  assert.deepEqual(rep.module_accuracy, {});
  assert.equal(rep.avg_duration_ms.overall, null);
  assert.deepEqual(rep.avg_duration_ms.by_knowledge_node, {});
  assert.equal(rep.stability, null);
  assert.deepEqual(rep.defect_repeat_rate, { repeat_count: 0, total_wrong: 0, rate: 0 });
  assert.equal(rep.strategy_execution, null);
  assert.deepEqual(rep.v3_candidates, []);
  assert.equal(rep.overall.accuracy, null);
});

// ---------------------------------------------------------------------------
// T11 stability
// ---------------------------------------------------------------------------

test('T11 stability：首次模考（无历史）返回 null，不硬编 0', () => {
  const questions = [Q('q1', 'kn-a', 'A')];
  const rep = reportGenerator({
    questions,
    attempts: [{ question_id: 'q1', is_correct: true, duration_ms: 10 }],
    recentMocks: [],
  });
  assert.equal(rep.stability, null);
});

test('T12 stability：与历史两次一起算 cv，历史顺序为「越近越前」', () => {
  const questions = [Q('q1', 'kn-a', 'A')];
  // 本次 1.0，历史 0.5 与 0.0 -> [1, 0.5, 0] mean=0.5 sd=sqrt(((0.25+0+0.25)/3))=0.408248 -> cv=0.816497
  const rep = reportGenerator({
    questions,
    attempts: [{ question_id: 'q1', is_correct: true, duration_ms: 10 }],
    recentMocks: [
      { questions: [{ is_correct: true }, { is_correct: false }] }, // 0.5
      { questions: [{ is_correct: false }] }, // 0.0
    ],
  });
  assert.equal(rep.stability, 0.816497);
});

test('T13 stability：历史超过两次只取近两次（共 3 点），且忽略全未判分的历史', () => {
  const questions = [Q('q1', 'kn-a', 'A')];
  // 本次 1.0 + 最近两次 1.0/1.0 -> cv=0，第 4 个 0.0 不应被读入
  const rep = reportGenerator({
    questions,
    attempts: [{ question_id: 'q1', is_correct: true, duration_ms: 10 }],
    recentMocks: [
      { questions: [{ is_correct: true }] },
      { questions: [{ is_correct: true }] },
      { questions: [{ is_correct: false }] }, // 第 4 个，超出窗口
      { questions: [{ is_correct: false }] },
    ],
  });
  assert.equal(rep.stability, 0);

  // 中间混入一条全未判分的历史（主观题），应被跳过而不是算成 0
  const rep2 = reportGenerator({
    questions,
    attempts: [{ question_id: 'q1', is_correct: true, duration_ms: 10 }],
    recentMocks: [
      { questions: [{ is_correct: null }] }, // 跳过
      { questions: [{ is_correct: true }] }, // 1.0
    ],
  });
  assert.equal(rep2.stability, 0); // [1, 1] -> cv 0
});

// ---------------------------------------------------------------------------
// T14 defect_repeat_rate
// ---------------------------------------------------------------------------

test('T14 defect_repeat_rate：错题中关联 CLOSED 缺陷单的比例', () => {
  const questions = [Q('q1', 'kn-a', 'A'), Q('q2', 'kn-a', 'A'), Q('q3', 'kn-b', 'B')];
  const attempts = [
    { question_id: 'q1', is_correct: false, duration_ms: 10 }, // 错，有 CLOSED 缺陷
    { question_id: 'q2', is_correct: false, duration_ms: 10 }, // 错，无缺陷
    { question_id: 'q3', is_correct: true, duration_ms: 10 }, // 对，不计
  ];
  const closedDefects = [
    { id: 'd1', status: 'CLOSED', question_id: 'q1', knowledge_node_id: 'kn-a' },
    // 对题上的 CLOSED 缺陷不算重复错（只有错题才计入）
    { id: 'd2', status: 'CLOSED', question_id: 'q3', knowledge_node_id: 'kn-b' },
  ];

  const rep = reportGenerator({ questions, attempts, closedDefects });
  assert.equal(rep.defect_repeat_rate.repeat_count, 1);
  assert.equal(rep.defect_repeat_rate.total_wrong, 2);
  assert.equal(rep.defect_repeat_rate.rate, 0.5);
});

test('T15 defect_repeat_rate：无 CLOSED 缺陷时 rate=0 而不是 null/NaN；分母 0 时 rate=0', () => {
  const questions = [Q('q1', 'kn-a', 'A')];
  const wrongAll = reportGenerator({
    questions,
    attempts: [{ question_id: 'q1', is_correct: false, duration_ms: 10 }],
    closedDefects: [],
  });
  assert.equal(wrongAll.defect_repeat_rate.repeat_count, 0);
  assert.equal(wrongAll.defect_repeat_rate.total_wrong, 1);
  assert.equal(wrongAll.defect_repeat_rate.rate, 0);

  // 没有错题 -> 分母 0，rate 定义成 0（不是 NaN）
  const noWrong = reportGenerator({
    questions,
    attempts: [{ question_id: 'q1', is_correct: true, duration_ms: 10 }],
    closedDefects: [],
  });
  assert.equal(noWrong.defect_repeat_rate.total_wrong, 0);
  assert.equal(noWrong.defect_repeat_rate.rate, 0);
});

test('T16 defect_repeat_rate：非 CLOSED 状态的缺陷不参与重复率', () => {
  const questions = [Q('q1', 'kn-a', 'A')];
  const attempts = [{ question_id: 'q1', is_correct: false, duration_ms: 10 }];
  const rep = reportGenerator({
    questions,
    attempts,
    closedDefects: [{ id: 'd1', status: 'V3', question_id: 'q1', knowledge_node_id: 'kn-a' }],
  });
  assert.equal(rep.defect_repeat_rate.repeat_count, 0);
  assert.equal(rep.defect_repeat_rate.rate, 0);
});

// ---------------------------------------------------------------------------
// T17 v3_candidates
// ---------------------------------------------------------------------------

test('T17 v3_candidates：错题按 knowledge_node_id 匹配 V3 缺陷单', () => {
  const questions = [Q('q1', 'kn-a', 'A'), Q('q2', 'kn-b', 'B')];
  const attempts = [
    { question_id: 'q1', is_correct: false, duration_ms: 10 }, // 错，kn-a 有 V3
    { question_id: 'q2', is_correct: true, duration_ms: 10 }, // 对，不出候选
  ];
  const closedDefects = [
    { id: 'd-v3', status: 'V3', question_id: null, knowledge_node_id: 'kn-a' },
  ];

  const rep = reportGenerator({ questions, attempts, closedDefects });
  assert.equal(rep.v3_candidates.length, 1);
  assert.deepEqual(rep.v3_candidates[0], {
    defect_ticket_id: 'd-v3',
    question_id: 'q1',
    knowledge_node_id: 'kn-a',
  });
});

test('T18 v3_candidates：同考点多张 V3 各出一条、同一 (缺陷,题) 不重复、答案对的不出', () => {
  const questions = [Q('q1', 'kn-a', 'A')];
  const attempts = [{ question_id: 'q1', is_correct: false, duration_ms: 10 }];
  const closedDefects = [
    { defect_ticket_id: 'd1', status: 'V3', knowledge_node_id: 'kn-a' },
    { defect_ticket_id: 'd2', status: 'V3', knowledge_node_id: 'kn-a' },
    { defect_ticket_id: 'd1', status: 'V3', knowledge_node_id: 'kn-a' }, // 重复输入
  ];

  const rep = reportGenerator({ questions, attempts, closedDefects });
  assert.equal(rep.v3_candidates.length, 2); // d1, d2 各一条，重复的 d1 被去重
  assert.deepEqual(rep.v3_candidates.map((x) => x.defect_ticket_id).sort(), ['d1', 'd2']);
});

test('T19 v3_candidates：考点不匹配 / 题无考点时不出候选', () => {
  const questions = [Q('q1', 'kn-a', 'A'), Q('q2', null, null)];
  const attempts = [
    { question_id: 'q1', is_correct: false, duration_ms: 10 },
    { question_id: 'q2', is_correct: false, duration_ms: 10 },
  ];
  const closedDefects = [{ id: 'd1', status: 'V3', knowledge_node_id: 'kn-z' }];
  const rep = reportGenerator({ questions, attempts, closedDefects });
  assert.deepEqual(rep.v3_candidates, []);
});

// ---------------------------------------------------------------------------
// T20 strategy_execution
// ---------------------------------------------------------------------------

test('T20 strategy_execution 恒为 null（拍板项 4：MVP 无跳过行为记录）', () => {
  const rep = reportGenerator({
    questions: [Q('q1', 'kn-a', 'A')],
    attempts: [{ question_id: 'q1', is_correct: true, duration_ms: 10 }],
  });
  assert.equal(rep.strategy_execution, null);
  assert.ok(Object.prototype.hasOwnProperty.call(rep, 'strategy_execution'));
});

// ---------------------------------------------------------------------------
// T21 容错
// ---------------------------------------------------------------------------

test('T21 脏输入不抛错：缺 attempts / 缺字段 / attempts 里有卷外题', () => {
  const rep = reportGenerator({
    questions: [Q('q1', 'kn-a', 'A'), { question_id: null }, null, 'x'],
    attempts: [
      { question_id: 'q-unknown', is_correct: true, duration_ms: 5 }, // 卷外题，不应影响统计
      null,
      { question_id: 'q1' }, // 没 is_correct -> 未判分
    ],
  });
  assert.equal(rep.overall.total, 0);
  assert.equal(rep.overall.ungraded, 1);
  assert.equal(rep.overall.correct, 0);
});
