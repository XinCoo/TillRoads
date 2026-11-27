// 本机「已隐藏题」快照存储。
//
// ── 为什么存在这个文件 ──────────────────────────────────────────────────
// 后端有 `PATCH /questions/:id/hide`（隐藏 / 取消隐藏），但**没有任何**
// 「列出已隐藏题」的端点；更麻烦的是 `GET /questions` 会默认**排除**当前
// 用户已隐藏的题。于是「已隐藏」这个筛选档如果只靠网络，永远只能拿到空列表。
// 本轮硬约束禁止改后端（server/ / schema.sql / migrations/ / core/），
// 所以只能在前端本地记一份快照：隐藏成功时写一条，取消隐藏时删一条。
//
// ── 已知限制（必须接受，不是 bug） ───────────────────────────────────────
//   * 这份快照是**本机**的。在 A 设备隐藏的题，B 设备的「已隐藏」列表里看不到；
//     但服务端仍然会为这个用户排除它们，所以 B 设备的「全部」里同样看不到 ——
//     表现为「题凭空少了」。这是后端缺端点的直接后果。
//   * 换账号（userId 变化）后各自一份快照，互不干扰。
//   * 清缓存 / 重装 App 后快照丢失，「已隐藏」列表会变空，但题库里照样看不到那些题。
//
// ── 将来怎么办 ──────────────────────────────────────────────────────────
// 后端一旦提供 `GET /questions/hidden`（或 `GET /questions?hidden=true`），
// **应当直接删除本文件**，并把题库管理页的 hidden 分支改成请求那个端点。
// 本地快照与服务端真值之间不存在可靠的合并逻辑，不要试图两边都对账。

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 一条「本机隐藏过的题」的轻量快照。
///
/// 只存列表页需要展示 / 回填的字段：隐藏列表里点「取消隐藏」时，
/// 只需要 [id] 去调接口，其余字段是为了让卡片（题干 / 题型 / 来源）还能渲染。
class HiddenQuestion {
  const HiddenQuestion({
    required this.id,
    required this.stem,
    required this.type,
    required this.source,
    this.hiddenAt = '',
  });

  /// 题目 id（取消隐藏时用它调 `PATCH /questions/:id/hide`）。
  final String id;

  /// 题干原文（卡片只展示前两行，但仍存全文，将来若要回填详情更省事）。
  final String stem;

  /// 题型原始值（`choice` / `fill` …），展示时再走 `questionTypeLabel`。
  final String type;

  /// 来源原始值（`manual` / `import` …）。
  final String source;

  /// 隐藏时间，ISO-8601 字符串（`DateTime.toIso8601String()`）。
  ///
  /// 存字符串而不是毫秒整数：本地快照是给人排查问题的，
  /// 直接 `prefs` 里看到 `2026-11-27T10:00:00.000` 比看一串数字友好。
  /// 解析失败一律当「没有时间」，不影响列表可用性。
  final String hiddenAt;

  /// 从本地快照反序列化。**不抛异常**：任何类型不对的字段都退化成空串。
  factory HiddenQuestion.fromJson(Map<String, Object?> json) {
    return HiddenQuestion(
      id: _str(json['id']),
      stem: _str(json['stem']),
      type: _str(json['type']),
      source: _str(json['source']),
      hiddenAt: _str(json['hidden_at']),
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'id': id,
      'stem': stem,
      'type': type,
      'source': source,
      'hidden_at': hiddenAt,
    };
  }

  static String _str(Object? value) => value is String ? value : '';
}

/// 「本机隐藏过的题」的持久化仓库（shared_preferences，一个用户一个 key）。
///
/// key 形如 `hidden_questions.<userId>`，值是 JSON 数组字符串。
///
/// 读写全部**吞异常**：这是纯辅助缓存，任何一次解析失败都不该让题库管理页白屏
/// （该页 [_load] 里直接 await 本类，抛出去就只剩错误态）。
class HiddenQuestionStore {
  const HiddenQuestionStore();

  /// 存储 key 前缀。刻意带上 userId：换账号不串数据。
  static const String keyPrefix = 'hidden_questions.';

  static String keyFor(String userId) => '$keyPrefix$userId';

  /// 读取某个用户的隐藏快照（按隐藏时间倒序，新隐藏的在前）。
  ///
  /// 任何异常（没有这个 key / JSON 坏了 / 顶层不是数组 / 元素不是对象）
  /// 都返回空列表并 `debugPrint`，**绝不抛**。
  Future<List<HiddenQuestion>> load(String userId) async {
    final String key = keyFor(userId);
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? raw = prefs.getString(key);
      if (raw == null || raw.trim().isEmpty) return <HiddenQuestion>[];

      final Object? decoded = jsonDecode(raw);
      if (decoded is! List) {
        debugPrint('[HiddenQuestionStore] $key 不是 JSON 数组，按空列表处理');
        return <HiddenQuestion>[];
      }

      final List<HiddenQuestion> list = <HiddenQuestion>[];
      for (final Object? item in decoded) {
        if (item is! Map) {
          debugPrint('[HiddenQuestionStore] $key 里有非对象元素，已跳过');
          continue;
        }
        final HiddenQuestion q =
            HiddenQuestion.fromJson(item.cast<String, Object?>());
        // 没有 id 的条目在列表里没法「取消隐藏」，直接丢掉。
        if (q.id.isEmpty) continue;
        list.add(q);
      }
      list.sort((HiddenQuestion a, HiddenQuestion b) {
        return b.hiddenAt.compareTo(a.hiddenAt);
      });
      return list;
    } catch (e) {
      debugPrint('[HiddenQuestionStore] 读取 $key 失败（按空列表处理）：$e');
      return <HiddenQuestion>[];
    }
  }

  /// 新增 / 覆盖一条快照（同 id 只保留最新一条）。
  Future<void> add(String userId, HiddenQuestion question) async {
    if (question.id.isEmpty) return;
    final List<HiddenQuestion> list = await load(userId);
    list.removeWhere((HiddenQuestion q) => q.id == question.id);
    list.insert(0, question);
    await _save(userId, list);
  }

  /// 删掉一条快照（取消隐藏成功时调用）。
  Future<void> remove(String userId, String questionId) async {
    if (questionId.isEmpty) return;
    final List<HiddenQuestion> list = await load(userId);
    final int before = list.length;
    list.removeWhere((HiddenQuestion q) => q.id == questionId);
    if (list.length == before) return;
    await _save(userId, list);
  }

  /// 清空某个用户的快照（本轮页面没调用；留给「清除本地缓存」之类的入口）。
  Future<void> clear(String userId) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.remove(keyFor(userId));
    } catch (e) {
      debugPrint('[HiddenQuestionStore] 清空 ${keyFor(userId)} 失败：$e');
    }
  }

  /// 写回整个数组。
  ///
  /// 同样吞异常：写失败最多是「这次隐藏没记进本地列表」，
  /// 服务端那边已经隐藏成功了，没必要为此弹错误打断用户。
  Future<void> _save(String userId, List<HiddenQuestion> list) async {
    final String key = keyFor(userId);
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String encoded = jsonEncode(
        list.map((HiddenQuestion q) => q.toJson()).toList(growable: false),
      );
      await prefs.setString(key, encoded);
    } catch (e) {
      debugPrint('[HiddenQuestionStore] 写入 $key 失败：$e');
    }
  }
}
