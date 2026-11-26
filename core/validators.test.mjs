// core/validators.test.mjs — BE-01 第 1 步 · V1–V12 纯校验函数单元测试
// node:test，零第三方依赖；import * as V from './validators.mjs'（端无关纯函数）
import test from 'node:test';
import assert from 'node:assert/strict';
import * as V from './validators.mjs';

// 统一断言工具：成功形状恒为 { ok:true }；失败形状恒带稳定的 code + 可读 message
function ok(result) {
  assert.equal(result.ok, true, `expected ok=true, got ${JSON.stringify(result)}`);
}
function bad(result, code) {
  assert.equal(result.ok, false, `expected ok=false, got ${JSON.stringify(result)}`);
  assert.equal(typeof result.code, 'string');
  assert.equal(typeof result.message, 'string');
  if (code) assert.equal(result.code, code, `message was: ${result.message}`);
}

const L1 = { order: 1, key: 'concept', label: '概念', desc: '概念层' };
const L2 = { order: 2, key: 'process', label: '流程', desc: '流程层' };

// ---------------------------------------------------------------------------
test('V0 常量与 schema.sql ENUM / CHECK 对齐（先读后写的实证锚点）', () => {
  assert.deepEqual([...V.EXAM_TYPES],
    ['civil_service', 'postgrad', 'final_exam', 'vocational', 'adult_self_study', 'custom']);
  assert.deepEqual([...V.SUBJECT_KINDS], ['objective', 'subjective', 'essay']);
  assert.deepEqual([...V.FREQ_TAGS], ['high', 'mid', 'low']);
  assert.deepEqual([...V.PROFILE_STATUSES], ['active', 'archived']);
});

// ---------------------------------------------------------------------------
test('V1 validateExamType：5 个合法值 / 明确拒绝 K12 / 非法 / null', () => {
  for (const v of V.EXAM_TYPES) ok(V.validateExamType(v));
  // K12 相关值有独立失败码，而不是混在 INVALID_EXAM_TYPE 里
  for (const v of ['k12', 'K12', 'gaokao', 'zhongkao', 'high_school',
                   'middle-school', 'primary_school', 'elementary',
                   '小学', '初中', '高中', '中考', '高考']) {
    bad(V.validateExamType(v), 'EXAM_TYPE_K12_FORBIDDEN');
  }
  bad(V.validateExamType('unknown'), 'INVALID_EXAM_TYPE');
  bad(V.validateExamType(''), 'INVALID_EXAM_TYPE');
  bad(V.validateExamType(null), 'INVALID_EXAM_TYPE');
  bad(V.validateExamType(undefined), 'INVALID_EXAM_TYPE');
  bad(V.validateExamType(5), 'INVALID_EXAM_TYPE');
});

// ---------------------------------------------------------------------------
test('V2 validateSubjectKind：3 个合法值 / 非法 / null（NOT NULL 无豁免）', () => {
  for (const v of V.SUBJECT_KINDS) ok(V.validateSubjectKind(v));
  bad(V.validateSubjectKind('multiple_choice'), 'INVALID_SUBJECT_KIND');
  bad(V.validateSubjectKind('Objective'), 'INVALID_SUBJECT_KIND');   // 大小写敏感
  bad(V.validateSubjectKind(null), 'INVALID_SUBJECT_KIND');
  bad(V.validateSubjectKind(undefined), 'INVALID_SUBJECT_KIND');
  bad(V.validateSubjectKind(1), 'INVALID_SUBJECT_KIND');
});

// ---------------------------------------------------------------------------
test('V3 validateFreqTag：3 个合法值 / null+undefined 合法 / 非法', () => {
  for (const v of V.FREQ_TAGS) ok(V.validateFreqTag(v));
  ok(V.validateFreqTag(null));          // schema 列可空
  ok(V.validateFreqTag(undefined));
  bad(V.validateFreqTag(''), 'INVALID_FREQ_TAG');
  bad(V.validateFreqTag('HIGH'), 'INVALID_FREQ_TAG');
  bad(V.validateFreqTag('urgent'), 'INVALID_FREQ_TAG');
});

// ---------------------------------------------------------------------------
test('V4 validateProfileStatus：active/archived / 非法 / null', () => {
  ok(V.validateProfileStatus('active'));
  ok(V.validateProfileStatus('archived'));
  bad(V.validateProfileStatus('deleted'), 'INVALID_PROFILE_STATUS');
  bad(V.validateProfileStatus(''), 'INVALID_PROFILE_STATUS');
  bad(V.validateProfileStatus(null), 'INVALID_PROFILE_STATUS');
  bad(V.validateProfileStatus(undefined), 'INVALID_PROFILE_STATUS');
});

// ---------------------------------------------------------------------------
test('V5 validateTargetScore：0 / 9999.99 边界 / null / 非法 / 超刻度 / PG 字符串', () => {
  ok(V.validateTargetScore(null));             // 列可空
  ok(V.validateTargetScore(undefined));
  ok(V.validateTargetScore(0));                // 下边界
  ok(V.validateTargetScore(80));
  ok(V.validateTargetScore(80.00));
  ok(V.validateTargetScore(9999.99));          // 上边界 numeric(6,2)
  ok(V.validateTargetScore('9999.99'));        // PG numeric 读回是字符串
  ok(V.validateTargetScore('80.000'));         // 末尾 0 不算超刻度
  bad(V.validateTargetScore(10000), 'INVALID_TARGET_SCORE');
  bad(V.validateTargetScore(10000.00), 'INVALID_TARGET_SCORE');
  bad(V.validateTargetScore(-1), 'INVALID_TARGET_SCORE');
  bad(V.validateTargetScore(80.123), 'INVALID_TARGET_SCORE');   // 3 位小数，PG 会静默四舍五入
  bad(V.validateTargetScore('9999.991'), 'INVALID_TARGET_SCORE');
  bad(V.validateTargetScore('abc'), 'INVALID_TARGET_SCORE');
  bad(V.validateTargetScore(NaN), 'INVALID_TARGET_SCORE');
  bad(V.validateTargetScore(Infinity), 'INVALID_TARGET_SCORE');
  bad(V.validateTargetScore(''), 'INVALID_TARGET_SCORE');
  bad(V.validateTargetScore('1e3'), 'INVALID_TARGET_SCORE');     // 科学计数法不接受
});

// ---------------------------------------------------------------------------
test('V6 validateDailyMinutes：1 边界 / 0,-1,小数非法 / null 合法', () => {
  ok(V.validateDailyMinutes(null));
  ok(V.validateDailyMinutes(1));               // 最小正整数
  ok(V.validateDailyMinutes(60));
  ok(V.validateDailyMinutes('120'));           // PG int 读回字符串
  bad(V.validateDailyMinutes(0), 'INVALID_DAILY_MINUTES');
  bad(V.validateDailyMinutes(-1), 'INVALID_DAILY_MINUTES');
  bad(V.validateDailyMinutes(1.5), 'INVALID_DAILY_MINUTES');
  bad(V.validateDailyMinutes('abc'), 'INVALID_DAILY_MINUTES');
  ok(V.validateDailyMinutes(undefined));  // 可空列: 未提供 = 跳过校验(与 V5/V7/V8/V9 一致)
  bad(V.validateDailyMinutes(NaN), 'INVALID_DAILY_MINUTES');
});

// ---------------------------------------------------------------------------
test('V7 validateWeightToTarget：0 / 9.999 边界 / 10,-1 / null / 超刻度', () => {
  ok(V.validateWeightToTarget(null));
  ok(V.validateWeightToTarget(undefined));
  ok(V.validateWeightToTarget(0));
  ok(V.validateWeightToTarget(0.5));
  ok(V.validateWeightToTarget(9.999));         // 上边界 numeric(4,3)
  ok(V.validateWeightToTarget('9.999'));
  ok(V.validateWeightToTarget('1.0000'));      // 末尾 0 不算超刻度
  bad(V.validateWeightToTarget(10), 'INVALID_WEIGHT_TO_TARGET');
  bad(V.validateWeightToTarget(9.9999), 'INVALID_WEIGHT_TO_TARGET');
  bad(V.validateWeightToTarget(-1), 'INVALID_WEIGHT_TO_TARGET');
  bad(V.validateWeightToTarget('abc'), 'INVALID_WEIGHT_TO_TARGET');
  bad(V.validateWeightToTarget(NaN), 'INVALID_WEIGHT_TO_TARGET');
  bad(V.validateWeightToTarget(Infinity), 'INVALID_WEIGHT_TO_TARGET');
});

// ---------------------------------------------------------------------------
test('V8 validateExamDate：合法日期 / Date 实例 / null / 假日期不被静默归一', () => {
  ok(V.validateExamDate(null));
  ok(V.validateExamDate(undefined));
  ok(V.validateExamDate('2026-11-15'));
  ok(V.validateExamDate('2024-02-29'));        // 闰年真实存在
  ok(V.validateExamDate('2026-11-15T10:00:00Z'));  // ISO datetime，PG date 列截断时间
  ok(V.validateExamDate(new Date('2026-11-15')));
  bad(V.validateExamDate('2026-02-30'), 'INVALID_EXAM_DATE');  // Date.parse 会归一到 3/2，这里必须拒绝
  bad(V.validateExamDate('2026-13-01'), 'INVALID_EXAM_DATE');
  bad(V.validateExamDate('2026-00-10'), 'INVALID_EXAM_DATE');
  bad(V.validateExamDate('not-a-date'), 'INVALID_EXAM_DATE');
  bad(V.validateExamDate(new Date('bad')), 'INVALID_EXAM_DATE');
  bad(V.validateExamDate(20261115), 'INVALID_EXAM_DATE');
  bad(V.validateExamDate('2026-11-15T99:99:99Z'), 'INVALID_EXAM_DATE');
});

// ---------------------------------------------------------------------------
test('V9 validateLayers：合法 / create 必非空 / update 可省 / 必填键 / 重复 / 非法', () => {
  ok(V.validateLayers([L1, L2]));
  ok(V.validateLayers([]));                    // DB 只要求 NOT NULL，不要求非空数组
  ok(V.validateLayers([{ ...L1, label: '', desc: '' }])); // 空字符串仍是 string
  // create / update 两种调用语义在本函数内区分
  ok(V.validateLayers(null));                  // 默认 update：不带 layers = 不修改
  ok(V.validateLayers(undefined, { mode: 'update' }));
  bad(V.validateLayers(null, { mode: 'create' }), 'LAYERS_REQUIRED');
  bad(V.validateLayers(undefined, { mode: 'create' }), 'LAYERS_REQUIRED');
  // 结构与必填键
  bad(V.validateLayers({}), 'INVALID_LAYERS');
  bad(V.validateLayers([{ ...L1, desc: undefined }]), 'INVALID_LAYERS'); // desc 键在但值非 string
  bad(V.validateLayers([{ order: 1, key: 'a', label: 'x' }]), 'INVALID_LAYERS');
  bad(V.validateLayers([{ ...L1, order: 1.5 }]), 'INVALID_LAYERS');
  bad(V.validateLayers([{ ...L1, order: '1' }]), 'INVALID_LAYERS');
  bad(V.validateLayers([{ ...L1, key: '  ' }]), 'INVALID_LAYERS');
  bad(V.validateLayers([{ ...L1, label: 123 }]), 'INVALID_LAYERS');
  bad(V.validateLayers([null]), 'INVALID_LAYERS');
  bad(V.validateLayers([[L1]]), 'INVALID_LAYERS');
  // order / key 各自不重复
  bad(V.validateLayers([L1, { ...L1 }]), 'DUPLICATE_LAYER_ORDER');
  bad(V.validateLayers([L1, { ...L2, key: 'concept' }]), 'DUPLICATE_LAYER_KEY');
});

// ---------------------------------------------------------------------------
test('V10 validateCustomizableGate：false 锁 layers/customizable / true 放行 / 失败关闭', () => {
  ok(V.validateCustomizableGate({ customizable: true }, { layers: [L1] }));
  ok(V.validateCustomizableGate({ customizable: true }, { customizable: false }));
  ok(V.validateCustomizableGate({ customizable: false }, { name: '改名允许' }));
  ok(V.validateCustomizableGate({ customizable: false }, {}));
  ok(V.validateCustomizableGate({ customizable: false }, null));
  bad(V.validateCustomizableGate({ customizable: false }, { layers: [L1] }),
      'CUSTOMIZABLE_LOCKED');
  bad(V.validateCustomizableGate({ customizable: false }, { customizable: true }),
      'CUSTOMIZABLE_LOCKED');   // 不允许把官方模板改成可自定义
  bad(V.validateCustomizableGate({ customizable: false }, { layers: [], customizable: false }),
      'CUSTOMIZABLE_LOCKED');
  bad(V.validateCustomizableGate(null, { layers: [L1] }), 'CUSTOMIZABLE_LOCKED'); // 取不到 current 保守锁住
  bad(V.validateCustomizableGate(undefined, { layers: [L1] }), 'CUSTOMIZABLE_LOCKED');
});

// ---------------------------------------------------------------------------
test('V11 validateExamProfileRequired：AC-EXAM-01 四项 / 一次收集 fields[] / 存在性 vs 合法性分工', () => {
  ok(V.validateExamProfileRequired({
    exam_type: 'postgrad', target_score: 400, exam_date: '2027-12-20', daily_minutes: 120
  }));
  ok(V.validateExamProfileRequired({
    exam_type: 'civil_service', target_label: '某岗位', exam_date: '2027-03-01', daily_minutes: 60
  }));                                        // 目标分或岗位至少一项
  ok(V.validateExamProfileRequired({
    exam_type: 'vocational', target_score: 0, exam_date: '2027-01-01', daily_minutes: 1
  }));                                        // 0 视为「已填」
  const all = V.validateExamProfileRequired({});
  bad(all, 'MISSING_REQUIRED_FIELD');
  assert.deepEqual(all.fields,
    ['exam_type', 'target_score_or_target_label', 'exam_date', 'daily_minutes']);
  const some = V.validateExamProfileRequired({ exam_type: 'postgrad', target_label: '岗位' });
  bad(some, 'MISSING_REQUIRED_FIELD');
  assert.deepEqual(some.fields, ['exam_date', 'daily_minutes']);
  // 存在性通过但值非法，交给 V1/V5/V6/V8 各自拒绝（职责不重叠）
  ok(V.validateExamProfileRequired({
    exam_type: 'postgrad', target_score: 1, exam_date: '2027-01-01', daily_minutes: 0
  }));
  bad(V.validateDailyMinutes(0), 'INVALID_DAILY_MINUTES');
});

// ---------------------------------------------------------------------------
test('V12 validateBaseVersion：正整数 / 0,-1,小数,null 非法 / 字符串合法', () => {
  ok(V.validateBaseVersion(1));
  ok(V.validateBaseVersion(2));
  ok(V.validateBaseVersion('3'));              // 与 numeric 读回字符串同构
  bad(V.validateBaseVersion(0), 'INVALID_BASE_VERSION');
  bad(V.validateBaseVersion(-1), 'INVALID_BASE_VERSION');
  bad(V.validateBaseVersion(1.5), 'INVALID_BASE_VERSION');
  bad(V.validateBaseVersion(null), 'INVALID_BASE_VERSION');     // 无 null 豁免
  bad(V.validateBaseVersion(undefined), 'INVALID_BASE_VERSION');
  bad(V.validateBaseVersion('abc'), 'INVALID_BASE_VERSION');
  bad(V.validateBaseVersion(NaN), 'INVALID_BASE_VERSION');
});

// ---------------------------------------------------------------------------
test('firstInvalid 组合原语：全通过 / 取第一个失败 / 兼容嵌套 error 形', () => {
  ok(V.firstInvalid(V.validateExamType('postgrad'), V.validateDailyMinutes(60)));
  const r = V.firstInvalid(V.validateExamType('postgrad'),
                           V.validateTargetScore(10000),
                           V.validateDailyMinutes(0));
  bad(r, 'INVALID_TARGET_SCORE');
  // core/index.mjs 的 validateAIGenerateRequest 用 { ok:false, error:{...} } 形，仍视作失败
  const nested = { ok: false, error: { code: 'INVALID_COUNT', message: 'x' } };
  assert.equal(V.firstInvalid(nested).ok, false);
  ok(V.firstInvalid());
});

// ---------------------------------------------------------------------------
test('V15 validateNickname：中文/英文/数字组合合法，空格与符号/emoji/超长被拒', () => {
  // 合法：中文、英文、数字各自单独或混合
  ok(V.validateNickname('张三'));
  ok(V.validateNickname('Tom'));
  ok(V.validateNickname('abc123'));
  ok(V.validateNickname('张三Tom2026'));
  ok(V.validateNickname('张三A1'));
  // 首尾空白先 trim 再校验（用户从输入框粘过来的情况）
  ok(V.validateNickname('  李四  '));
  // 边界：2 个字符合法、20 个字符合法、21 个被拒
  ok(V.validateNickname('ab'));
  const twenty = 'a'.repeat(20);
  ok(V.validateNickname(twenty));
  bad(V.validateNickname('a'.repeat(21)), 'INVALID_NICKNAME');
  // 太短 / 全空白 / 空串
  bad(V.validateNickname('a'), 'INVALID_NICKNAME');
  bad(V.validateNickname('   '), 'INVALID_NICKNAME');
  bad(V.validateNickname(''), 'INVALID_NICKNAME');
  // 非法字符：空格（中间）、下划线、连字符、标点、emoji、全角空格
  bad(V.validateNickname('张 三'), 'INVALID_NICKNAME');
  bad(V.validateNickname('zhang_san'), 'INVALID_NICKNAME');
  bad(V.validateNickname('zhang-san'), 'INVALID_NICKNAME');
  bad(V.validateNickname('张三!'), 'INVALID_NICKNAME');
  bad(V.validateNickname('张三🙂'), 'INVALID_NICKNAME');
  // 全角空格在中间：非法（在首尾则会被 trim 掉，属预期）
  bad(V.validateNickname('张　三'), 'INVALID_NICKNAME');
  // 首尾全角空格被 trim 后合法（与 ASCII 空格一致）
  ok(V.validateNickname('　　张三　　'));
  // 非字符串
  bad(V.validateNickname(null), 'INVALID_NICKNAME');
  bad(V.validateNickname(123), 'INVALID_NICKNAME');
  bad(V.validateNickname(undefined), 'INVALID_NICKNAME');
  // 失败形状冻结（与其他校验器一致）
  assert.equal(Object.isFrozen(V.validateNickname('张 三')), true);
});

// ---------------------------------------------------------------------------
test('纯函数契约：不修改入参、无副作用、返回值冻结可安全复用', () => {
  const input = { exam_type: 'postgrad', target_score: 400,
                  exam_date: '2027-12-20', daily_minutes: 120 };
  const snapshot = JSON.stringify(input);
  V.validateExamProfileRequired(input);
  V.validateExamType(input.exam_type);
  assert.equal(JSON.stringify(input), snapshot, '不得修改入参');
  const layers = [L1, L2];
  const layersSnapshot = JSON.stringify(layers);
  V.validateLayers(layers);
  assert.equal(JSON.stringify(layers), layersSnapshot, '不得修改 layers 数组');
  assert.equal(Object.isFrozen(V.validateTargetScore(80)), true);
  assert.equal(Object.isFrozen(V.EXAM_TYPES), true);
});
