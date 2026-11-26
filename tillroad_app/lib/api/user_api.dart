// 当前用户信息接口（A3②）。
//
// 后端契约（同事并行实现中）：
//   `GET /me` → 200
//   {
//     "id": "<uuid>",
//     "nickname": "<昵称或 null>",
//     "display_name": "显示名",
//     "masked_id": "1111****"
//   }
//   · `display_name` = nickname 非空则昵称，否则 `'用户_' + id 末 4 位`；
//   · `masked_id`   = id 前 4 位 + `****`；
//   · 无 token 时返回 401（由 ApiClient 转成 ApiException，页面无需额外处理）。
//
// ── 为什么路由是 `/me` 而不是 `/users/me` ────────────────────────────────
// 后端会把 `/users/<任意 id>` 的第 2 段改写成 token 对应用户，
// 所以 `/users/me` 会被当成「用户 id = me」去查库（必然查不到）。
// 只有 `/me` 这条不落在 `/users/` 前缀下的路由才是取「当前登录用户」。
//
// ── 为什么这里还有一个「带指定 token 的直连」实现 ──────────────────────
// `ApiClient._send` 的 Authorization 头取自全局 `kApiToken`，没有单请求级
// token 覆盖能力（api_client.dart 不在本次改动范围内）。而「切换 Token」必须
// 在**写盘之前**用新 token 验证一次（否则坏 token 落盘后旧凭证也丢了），
// 所以这里用 `package:http` 直接发一次请求，显式带 `Authorization: Bearer <新 token>`。

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/api_config.dart';
import '../logging/app_logger.dart';
import 'api_client.dart';

/// 当前登录用户的资料（来自 `GET /me`）。
class UserProfile {
  const UserProfile({
    required this.id,
    required this.nickname,
    required this.displayName,
    required this.maskedId,
  });

  /// 用户完整 id（UUID）。
  final String id;

  /// 昵称；后端没给（null / 缺字段）时为 null。
  final String? nickname;

  /// 展示名：昵称为空时后端会退化成 `用户_<id 末 4 位>`。
  final String displayName;

  /// 脱敏 id（`1111****`），用于界面展示，避免完整 id 出现在截图里。
  final String maskedId;

  /// 从 `GET /me` 的 JSON 解析。
  ///
  /// 字段缺失时全部按「后端没给」处理：
  ///   · `id` 缺失 → 空串（调用方拿它复制会得到空内容，界面会回退到本地 id）；
  ///   · `display_name` 缺失 → 用 `用户_<id 末 4 位>` 兜底（与后端同规则）；
  ///   · `masked_id` 缺失 → 用 `id` 前 4 位 + `****` 兜底（与后端同规则）。
  factory UserProfile.fromJson(Object? raw) {
    final Map<String, Object?> body = raw is Map
        ? raw.map<String, Object?>(
            (Object? key, Object? value) =>
                MapEntry<String, Object?>('$key', value),
          )
        : const <String, Object?>{};
    final String id = _stringOf(body['id']) ?? '';
    final String? nicknameRaw = _stringOf(body['nickname']);
    final String? nickname =
        (nicknameRaw == null || nicknameRaw.trim().isEmpty)
        ? null
        : nicknameRaw.trim();
    final String? displayNameRaw = _stringOf(body['display_name']);
    final String displayName = (displayNameRaw == null || displayNameRaw.isEmpty)
        ? _fallbackDisplayName(id)
        : displayNameRaw;
    final String? maskedRaw = _stringOf(body['masked_id']);
    final String maskedId = (maskedRaw == null || maskedRaw.isEmpty)
        ? _fallbackMaskedId(id)
        : maskedRaw;
    return UserProfile(
      id: id,
      nickname: nickname,
      displayName: displayName,
      maskedId: maskedId,
    );
  }

  /// 把 JSON 里的任意值读成「去空白的字符串」；值缺失或不是字符串时返回 null。
  static String? _stringOf(Object? value) {
    if (value is! String) return null;
    final String trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static String _fallbackDisplayName(String id) {
    if (id.isEmpty) return '未命名用户';
    final String tail = id.length <= 4 ? id : id.substring(id.length - 4);
    return '用户_$tail';
  }

  static String _fallbackMaskedId(String id) {
    if (id.isEmpty) return '—';
    final String head = id.length <= 4 ? id : id.substring(0, 4);
    return '$head****';
  }

  @override
  String toString() => 'UserProfile(id: $id, displayName: $displayName)';
}

/// 当前用户资料接口。
class UserApi {
  UserApi({ApiClient? client}) : _client = client ?? ApiClient();

  final ApiClient _client;

  /// 拉取当前登录用户资料（`GET /me`）。
  ///
  /// 401（没 token / token 无效）由 ApiClient 抛 ApiException，调用方自行决定
  /// 是提示「未登录」还是降级显示占位。
  Future<UserProfile> fetchMe() async {
    final Object? raw = await _client.get('/me');
    return UserProfile.fromJson(raw);
  }

  /// 修改当前用户昵称（`PATCH /me`，m28943）。
  ///
  /// 后端契约：body 只传 `nickname` 一个字段；成功返回与 `GET /me` **同形**的
  /// 完整资料，所以直接用 [UserProfile.fromJson] 解，调用方拿到什么就是最新的
  /// 昵称 / display_name / masked_id，不需要再补一次 GET。
  ///
  /// 失败（400 / 401 / 404）由 ApiClient 抛 [ApiException]，`body` 里带后端错误码：
  ///   · `MISSING_NICKNAME`（没传字段，正常前端不会遇到）
  ///   · `INVALID_NICKNAME`（非法字符 / 太短 / 超长，message 可直显给用户）
  ///   · `not_found`（用户已软删）
  /// 调用方必须把失败提示给用户——“静默失败”正是 A3 要修的问题。
  Future<UserProfile> updateNickname(String nickname) async {
    final Object? raw = await _client.patch(
      '/me',
      body: <String, Object?>{'nickname': nickname},
    );
    return UserProfile.fromJson(raw);
  }

  void close() => _client.close();

  // ─────────────────────────── 带指定 token 的直连校验 ───────────────────────

  /// 用**指定** token 直接请求一次 `GET /me`，返回该 token 对应的用户资料。
  ///
  /// 存在的唯一理由：切换 Token 时必须「先验证、后写盘」——若新 token 无效，
  /// 旧 token 必须继续可用；而 `ApiClient` 只会带上全局的 `kApiToken`，
  /// 没法在不改 `api_client.dart` 的前提下用另一个 token 发请求。
  ///
  /// 失败时抛 [ApiException]（401 → statusCode 401），调用方据此**不写盘**。
  static Future<UserProfile> fetchMeWithToken(
    String token, {
    Duration timeout = kApiTimeout,
    http.Client? httpClient,
  }) async {
    final String normalized = token.trim();
    if (normalized.isEmpty) {
      throw ApiException('Token 不能为空');
    }
    final http.Client client = httpClient ?? http.Client();
    final bool owned = httpClient == null;
    final Uri uri = buildApiUri(kApiBaseUrl, '/me');
    try {
      final http.Request request = http.Request('GET', uri);
      request.headers['Accept'] = 'application/json';
      request.headers['Authorization'] = 'Bearer $normalized';
      final http.StreamedResponse response = await client
          .send(request)
          .timeout(timeout);
      final String raw = await response.stream.bytesToString();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        // 与 ApiClient 的口径保持一致：401 是「凭证无效」，其余按状态码报。
        final String message = response.statusCode == 401
            ? 'Token 无效或已过期（401）'
            : '后端返回 ${response.statusCode}';
        AppLogger.instance.warn(
          'API',
          'GET /me 校验失败：${response.statusCode}',
        );
        throw ApiException(
          message,
          statusCode: response.statusCode,
          body: raw,
          uri: uri,
        );
      }
      Object? decoded;
      if (raw.isNotEmpty) {
        try {
          decoded = jsonDecode(raw);
        } catch (_) {
          decoded = raw;
        }
      }
      return UserProfile.fromJson(decoded);
    } on TimeoutException {
      throw ApiException(
        '请求超时（${timeout.inSeconds}s），请检查后端是否在运行',
        uri: uri,
      );
    } on ApiException {
      rethrow;
    } catch (e) {
      throw ApiException('无法连接后端（$e）', uri: uri);
    } finally {
      if (owned) client.close();
    }
  }
}
