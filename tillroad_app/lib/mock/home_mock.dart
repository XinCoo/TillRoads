/// FE-01 首页看板的全部 mock 数据。
///
/// 为什么单独一个文件：FE-01 不连后端（硬约束：不发 HTTP），
/// 但后续接 BE-04/BE-06 时只需把这里换成 repository 调用，
/// 页面层代码不用动。所以这里的类型形状**刻意对齐后端真实响应**：
/// - 验证任务对齐 `GET /users/:userId/verification-tasks`（BE-04）
/// - 缺陷分布对齐复盘 metrics 的 `layer_dist`（BE-06）
/// - 倒计时对齐 `exam_profiles.exam_date` + `target_label`
library;

import 'package:flutter/foundation.dart';

/// 验证任务紧急度三态，取值与后端 urgency 字符串一致
/// （BE-04 `computeUrgency` 返回 'overdue' / 'due_soon' / 'normal'）。
enum TaskUrgency {
  overdue('overdue', '已逾期'),
  dueSoon('due_soon', '临期'),
  normal('normal', '正常');

  const TaskUrgency(this.wire, this.label);

  /// 与后端 JSON 对齐的字符串值
  final String wire;

  /// 界面展示用中文
  final String label;

  static TaskUrgency fromWire(String value) {
    for (final TaskUrgency item in TaskUrgency.values) {
      if (item.wire == value) return item;
    }
    // 未知值不抛错：后端新增枚举时前端不应白屏
    return TaskUrgency.normal;
  }
}

/// 一条待验证任务（对应一条处于 V1/V2/V3 的缺陷单）
@immutable
class VerificationTask {
  const VerificationTask({
    required this.id,
    required this.knowledgeNodeTitle,
    required this.subjectName,
    required this.stage,
    required this.daysLeft,
    required this.urgency,
  });

  final String id;

  /// 考点名，如「判断推理 · 逻辑判断」
  final String knowledgeNodeTitle;
  final String subjectName;

  /// 验证阶段 V1 / V2 / V3
  final String stage;

  /// 剩余天数；负数表示已逾期天数
  final int daysLeft;
  final TaskUrgency urgency;

  /// 剩余天数的展示文案：逾期时显示「逾期 N 天」，否则「剩 N 天」
  String get daysLeftLabel {
    if (daysLeft < 0) return '逾期 ${-daysLeft} 天';
    if (daysLeft == 0) return '今天到期';
    return '剩 $daysLeft 天';
  }
}

/// 缺陷分布的一根条形（对应后端 `layer_dist` 的一个 key）
@immutable
class LayerDistribution {
  const LayerDistribution({
    required this.layer,
    required this.label,
    required this.count,
  });

  /// 后端 error_layer 原始值，如 concept / method / calculation
  final String layer;

  /// 中文展示名
  final String label;
  final int count;
}

/// 首页看板的整体数据快照
@immutable
class HomeSnapshot {
  const HomeSnapshot({
    required this.examLabel,
    required this.daysToExam,
    required this.tasks,
    required this.distributions,
    required this.totalDefects,
  });

  /// 如「省考」
  final String examLabel;

  /// 距离考试天数（>0）
  final int daysToExam;

  /// 今日待验证任务（3 条：V1/V2/V3 各一）
  final List<VerificationTask> tasks;

  /// 缺陷分布（按 error_layer 聚合）
  final List<LayerDistribution> distributions;

  /// 未关闭缺陷单总数（分布卡片右上角显示）
  final int totalDefects;

  /// 分布条形的最大 count，用于计算相对宽度。
  /// 全为 0 时返回 1，避免除零。
  int get maxDistributionCount {
    int max = 0;
    for (final LayerDistribution item in distributions) {
      if (item.count > max) max = item.count;
    }
    return max == 0 ? 1 : max;
  }
}

/// FE-01 的静态 mock 数据。
///
/// 数字刻意做得像真实用户：欠着 3 条待验证（覆盖三态），
/// 缺陷集中在「概念不清」和「方法不会」，符合「省考 · 行测」的常见分布。
const HomeSnapshot kHomeSnapshot = HomeSnapshot(
  examLabel: '省考 · 行测',
  daysToExam: 47,
  totalDefects: 23,
  tasks: <VerificationTask>[
    VerificationTask(
      id: 'dt-v1-001',
      knowledgeNodeTitle: '判断推理 · 充分必要条件',
      subjectName: '行测',
      stage: 'V1',
      daysLeft: -2,
      urgency: TaskUrgency.overdue,
    ),
    VerificationTask(
      id: 'dt-v2-002',
      knowledgeNodeTitle: '资料分析 · 增长率比较',
      subjectName: '行测',
      stage: 'V2',
      daysLeft: 2,
      urgency: TaskUrgency.dueSoon,
    ),
    VerificationTask(
      id: 'dt-v3-003',
      knowledgeNodeTitle: '言语理解 · 逻辑填空',
      subjectName: '行测',
      stage: 'V3',
      daysLeft: 9,
      urgency: TaskUrgency.normal,
    ),
  ],
  distributions: <LayerDistribution>[
    LayerDistribution(layer: 'concept', label: '概念不清', count: 11),
    LayerDistribution(layer: 'method', label: '方法不会', count: 7),
    LayerDistribution(layer: 'calculation', label: '计算失误', count: 3),
    LayerDistribution(layer: 'reading', label: '审题偏差', count: 2),
  ],
);
