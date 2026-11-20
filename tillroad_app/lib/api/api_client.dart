// 通用 HTTP 客户端（FE-03 联调）。
//
// 只用 Dart 官方 http 包，封装四件事：
//   1. 拼 URL（基址来自 api_config，页面不碰）；
//   2. JSON 编解码；
//   3. 统一超时；
//   4. 统一错误 → ApiException。
//
// 为什么不在这里做重试：
//   两个 GET 端点都是幂等的，重试本身安全；但本轮错误态要**演示给用户看**
//   （任务 D3 要求后端停掉时显示「加载失败 + 重试」），自动重试会掩盖问题、
//   也让错误态测试变慢。重试交给用户在界面上点按钮，语义更清楚。

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/api_config.dart';

/// API 调用失败时抛出。页面用它区分「网络不通」与「后端返回业务错误」。
class ApiException implements Exception {
  ApiException(this.message, {this.statusCode, this.body, this.uri});

  /// 面向用户的中文短句（可直接显示在错误态里）。
  final String message;

  /// HTTP 状态码；网络层失败（连不上/超时）时为 null。
  final int? statusCode;

  /// 解析后的响应体（可能是 Map/List/String）。
  final Object? body;

  final Uri? uri;

  /// 是否为「连不上后端」这类传输层错误（错误态文案要区别对待）。
  bool get isNetworkError => statusCode == null;

  @override
  String toString() => 'ApiException($statusCode): $message';
}

class ApiClient {
  ApiClient({http.Client? client, String? baseUrl, Duration? timeout})
    : _client = client ?? http.Client(),
      _baseUrl = baseUrl ?? kApiBaseUrl,
      _timeout = timeout ?? kApiTimeout;

  final http.Client _client;
  final String _baseUrl;
  final Duration _timeout;

  Uri _uri(String path, [Map<String, String>? query]) {
    final normalized = path.startsWith('/') ? path : '/$path';
    final base = Uri.parse(_baseUrl);
    return base.replace(
      path: '${base.path}$normalized',
      queryParameters: (query == null || query.isEmpty) ? null : query,
    );
  }

  Future<Object?> get(String path, {Map<String, String>? query}) =>
      _send('GET', _uri(path, query));

  Future<Object?> post(
    String path, {
    Object? body,
    Map<String, String>? query,
  }) => _send('POST', _uri(path, query), body: body);

  Future<Object?> patch(
    String path, {
    Object? body,
    Map<String, String>? query,
  }) => _send('PATCH', _uri(path, query), body: body);

  Future<Object?> delete(
    String path, {
    Object? body,
    Map<String, String>? query,
  }) => _send('DELETE', _uri(path, query), body: body);

  Future<Object?> _send(String method, Uri uri, {Object? body}) async {
    final request = http.Request(method, uri);
    request.headers['Accept'] = 'application/json';
    final token = kApiToken;
    if (token != null && token.trim().isNotEmpty) {
      request.headers['Authorization'] = 'Bearer ${token.trim()}';
    }
    if (body != null) {
      request.headers['Content-Type'] = 'application/json; charset=utf-8';
      request.body = jsonEncode(body);
    }

    http.StreamedResponse streamed;
    try {
      streamed = await _client.send(request).timeout(_timeout);
    } on TimeoutException {
      throw ApiException('请求超时（${_timeout.inSeconds}s），请检查后端是否在运行', uri: uri);
    } catch (e) {
      // SocketException / ClientException 等传输层失败，statusCode 留 null
      throw ApiException('无法连接后端（$e）', uri: uri);
    }

    final raw = await streamed.stream.bytesToString();
    Object? decoded;
    if (raw.isNotEmpty) {
      try {
        decoded = jsonDecode(raw);
      } catch (_) {
        // 后端异常时可能返回非 JSON（如反向代理的 HTML 错误页），保留原文便于定位
        decoded = raw;
      }
    }

    if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
      final hint = (decoded is Map && decoded['error'] != null)
          ? '${decoded['error']}'
          : null;
      throw ApiException(
        hint == null
            ? '后端返回 ${streamed.statusCode}'
            : '后端返回 ${streamed.statusCode}（$hint）',
        statusCode: streamed.statusCode,
        body: decoded,
        uri: uri,
      );
    }

    return decoded;
  }

  void close() => _client.close();
}
