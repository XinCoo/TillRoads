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
import '../logging/app_logger.dart';
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

  /// 拼请求 URL。
  ///
  /// 为什么不直接 `Uri.parse(baseUrl).resolve(path)`：
  /// `resolve('/users/1')` 会把 base 自带的路径整体丢掉（`https://h/api` +
  /// `resolve('/users')` → `https://h/users`）。将来若把后端挂在子路径上，
  /// 那样会静默请求到错误位置。这里改成「保留 base 路径 + 拼子路径 + 折叠重复斜杠」，
  /// 既能防 `https://h//users/1`，也能支持 `https://h/api/users/1`。
  Uri _uri(String path, [Map<String, String>? query]) =>
      buildApiUri(_baseUrl, path, query);

  /// 当前使用的 base URL（诊断页展示用）。
  String get baseUrl => _baseUrl;

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

  /// 发请求并记日志（任务 B2/B3）。
  ///
  /// 日志三处埋点都在这一个方法里，因为全项目所有 HTTP 都从这里出：
  ///   ① 请求前：`[API] GET /users/1111****/defect-tickets`（URL 已脱敏）；
  ///   ② 响应后：`[API] 200 OK 342ms` / `[API] 500 ERROR 1200ms code=xxx`；
  ///   ③ 抛 `ApiException` 前：完整 statusCode / body / url（任务 B3）。
  Future<Object?> _send(String method, Uri uri, {Object? body}) async {
    // 相对路径（不含 host）更短也更好读；host 在启动日志里已经记过一次。
    final String where = '${uri.path}${uri.hasQuery ? '?${uri.query}' : ''}';
    AppLogger.instance.info('API', '$method $where');
    final Stopwatch watch = Stopwatch()..start();

    final request = http.Request(method, uri);
    request.headers['Accept'] = 'application/json';
    final token = kApiToken;
    if (token != null && token.trim().isNotEmpty) {
      // Authorization 头的**原值永不入日志**（任务 C3）：这里只可能是布尔摘要。
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
      watch.stop();
      // 超时是最常被误报成「App 卡住」的情形，必须带超时值直接落盘。
      AppLogger.instance.error(
        'API',
        '$method $where Timeout ${_timeout.inMilliseconds}ms',
      );
      throw ApiException('请求超时（${_timeout.inSeconds}s），请检查后端是否在运行', uri: uri);
    } catch (e) {
      watch.stop();
      // SocketException / ClientException 等传输层失败，statusCode 留 null
      AppLogger.instance.error(
        'API',
        '$method $where 网络失败 ${watch.elapsedMilliseconds}ms：$e',
      );
      throw ApiException('无法连接后端（$e）', uri: uri);
    }

    final raw = await streamed.stream.bytesToString();
    watch.stop();
    final int cost = watch.elapsedMilliseconds;
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
      // 任务 B3：抛出前把完整信息记一条 error，含状态码 / 业务码 / URL / 响应体摘要。
      // 响应体可能是题干等用户输入，因此只截前 200 字符 —— 排查足够，又不会把
      // 整页题目写进日志（硬约束：用户输入不写入日志）。
      AppLogger.instance.error(
        'API',
        '$method $where ${streamed.statusCode} ERROR ${cost}ms'
        '${hint == null ? '' : ' code=$hint'}'
        '${raw.isEmpty ? '' : ' body=${_clipBody(raw)}'}',
      );
      throw ApiException(
        hint == null
            ? '后端返回 ${streamed.statusCode}'
            : '后端返回 ${streamed.statusCode}（$hint）',
        statusCode: streamed.statusCode,
        body: decoded,
        uri: uri,
      );
    }

    // 2xx：GET 记 info；写操作记 info 也合适（次数少，且写入失败会走上面的 error 分支）。
    AppLogger.instance.info(
      'API',
      '$method $where ${streamed.statusCode} OK ${cost}ms',
    );

    return decoded;
  }
  void close() => _client.close();
}

/// 拼请求 URL：保留 base 自带的路径 + 拼子路径 + 折叠重复斜杠。
///
/// 为什么不直接 `Uri.parse(baseUrl).resolve(path)`：
/// `resolve('/users/1')` 会把 base 自带的路径整体丢掉（`https://h/api` +
/// `resolve('/users')` → `https://h/users`）。将来若把后端挂在子路径上，
/// 那样会静默请求到错误位置。
Uri buildApiUri(String baseUrl, String path, [Map<String, String>? query]) {
  final String normalized = path.startsWith('/') ? path : '/$path';
  final Uri base = Uri.parse(baseUrl);
  final String joined = '${base.path}$normalized'.replaceAll(RegExp(r'/+'), '/');
  return base.replace(
    path: joined,
    queryParameters: (query == null || query.isEmpty) ? null : query,
  );
}

/// 诊断失败的环节。用户报错时能直接看出是「配置错 / DNS / TLS / HTTP / 超时」。
enum DiagnoseStage {
  ok('通过'),
  invalidBaseUrl('配置错误'),
  dns('DNS 解析失败'),
  tls('HTTPS 握手失败'),
  timeout('请求超时'),
  http('HTTP 异常'),
  network('网络不可达');

  const DiagnoseStage(this.label);

  final String label;
}

/// 一次连接诊断的结构化结果。
class DiagnoseResult {
  const DiagnoseResult({
    required this.stage,
    required this.baseUrl,
    required this.message,
    this.uri,
    this.statusCode,
    this.elapsed = Duration.zero,
    this.rawError,
  });

  final DiagnoseStage stage;

  /// 实际参与诊断的 base URL（已清洗）。
  final String baseUrl;

  /// 面向用户的一句话结论。
  final String message;

  final Uri? uri;
  final int? statusCode;
  final Duration elapsed;

  /// 原始异常文本（排查时贴给开发者最有用的就是它）。
  final String? rawError;

  bool get ok => stage == DiagnoseStage.ok;
}

/// 不经过业务层直接打一次 `GET /health`，把失败环节分类。
///
/// 单独建 `http.Client` 并在结束时 `close()`：诊断可能反复点，
/// 复用页面持有的连接池没好处，反而会把失败连接拖到业务请求上。
/// 注意：这里的输出**不含 token**，诊断结果可以放心截图给开发者。
Future<DiagnoseResult> diagnose({
  String? baseUrl,
  Duration timeout = const Duration(seconds: 10),
  http.Client? client,
}) async {
  final DiagnoseResult result = await _runDiagnose(
    baseUrl: baseUrl,
    timeout: timeout,
    client: client,
  );
  // 任务 B5：诊断结果写入日志。这是用户报障时最有价值的一条 ——
  // 它把「配置错 / DNS / TLS / HTTP / 超时」直接定性，不用再猜。
  // 注意 `result.baseUrl` 已不含 token（diagnose 内部只处理 base URL）。
  final String detail =
      '${result.stage.label} ${result.elapsed.inMilliseconds}ms'
      '${result.statusCode == null ? '' : ' status=${result.statusCode}'}'
      ' base=${result.baseUrl}'
      '${result.rawError == null ? '' : ' raw=${_clip(result.rawError!)}'}';
  if (result.ok) {
    AppLogger.instance.info('DIAG', detail);
  } else {
    AppLogger.instance.warn('DIAG', '$detail — ${result.message}');
  }
  return result;
}

/// 诊断的实际实现（不记日志，避免与对外入口重复）。
Future<DiagnoseResult> _runDiagnose({
  String? baseUrl,
  Duration timeout = const Duration(seconds: 10),
  http.Client? client,
}) async {
  final String raw = baseUrl ?? kApiBaseUrlRaw;
  final String? normalized = normalizeBaseUrl(raw);
  final Stopwatch watch = Stopwatch()..start();

  if (normalized == null) {
    watch.stop();
    return DiagnoseResult(
      stage: DiagnoseStage.invalidBaseUrl,
      baseUrl: raw,
      message: '地址不合法：需要形如 https://example.com 的 http(s) 地址，当前值不可解析。',
      elapsed: watch.elapsed,
    );
  }

  final Uri uri = buildApiUri(normalized, '/health');
  final http.Client ownClient = client ?? http.Client();
  final bool owned = client == null;

  try {
    final http.Request request = http.Request('GET', uri);
    request.headers['Accept'] = 'application/json';
    final String? token = kApiToken;
    if (token != null && token.trim().isNotEmpty) {
      request.headers['Authorization'] = 'Bearer ${token.trim()}';
    }

    final http.StreamedResponse response = await ownClient
        .send(request)
        .timeout(timeout);
    final String body = await response.stream.bytesToString();
    watch.stop();

    if (response.statusCode == 200) {
      return DiagnoseResult(
        stage: DiagnoseStage.ok,
        baseUrl: normalized,
        message: '连接正常：GET /health 返回 200。',
        uri: uri,
        statusCode: response.statusCode,
        elapsed: watch.elapsed,
      );
    }

    return DiagnoseResult(
      stage: DiagnoseStage.http,
      baseUrl: normalized,
      message:
          '网络与服务器都可连通，但返回 HTTP ${response.statusCode}'
          '${body.isEmpty ? '' : '：${_clip(body)}'}',
      uri: uri,
      statusCode: response.statusCode,
      elapsed: watch.elapsed,
      rawError: body.isEmpty ? null : _clip(body),
    );
  } on TimeoutException {
    watch.stop();
    return DiagnoseResult(
      stage: DiagnoseStage.timeout,
      baseUrl: normalized,
      message: '${timeout.inSeconds}s 内无响应。DNS/TLS 可能卡住，或后端在冷启动。',
      uri: uri,
      elapsed: watch.elapsed,
    );
  } catch (e) {
    watch.stop();
    final String text = e.toString();
    final DiagnoseStage stage = _classify(text);
    return DiagnoseResult(
      stage: stage,
      baseUrl: normalized,
      message: _adviceFor(stage),
      uri: uri,
      elapsed: watch.elapsed,
      rawError: text,
    );
  } finally {
    if (owned) ownClient.close();
  }
}

/// 把异常文本归到具体环节。
///
/// 用字符串匹配而不是 `dart:io` 的异常类型：
/// ① `package:http` 在不同平台把底层 SocketException 包成 ClientException；
/// ② 不引 `dart:io` 才能让这个文件在 web/测试里照样编译。
DiagnoseStage _classify(String text) {
  final String t = text.toLowerCase();
  if (t.contains('failed host lookup') ||
      t.contains('no address associated with hostname') ||
      t.contains('nodename nor servname')) {
    return DiagnoseStage.dns;
  }
  if (t.contains('handshakeexception') ||
      t.contains('certificate') ||
      t.contains('tls') ||
      t.contains('ssl')) {
    return DiagnoseStage.tls;
  }
  if (t.contains('connection refused') ||
      t.contains('network is unreachable') ||
      t.contains('no route to host') ||
      t.contains('connection reset')) {
    return DiagnoseStage.network;
  }
  return DiagnoseStage.network;
}
String _adviceFor(DiagnoseStage stage) {
  switch (stage) {
    case DiagnoseStage.dns:
      return '域名解析不了。常见原因：Android 缺少 INTERNET 权限（release 包）、'
          '手机开了私人 DNS / VPN、或 App 被系统的联网控制开关禁用。';
    case DiagnoseStage.tls:
      return '域名能解析但 TLS 握手失败。常见原因：系统时间不准、'
          '中间人代理证书不被信任、或网络环境阻断 443。';
    case DiagnoseStage.network:
      return '解析成功但连不上服务器。常见原因：端口被屏蔽、'
          '后端未运行、或 WiFi/流量不可用。';
    case DiagnoseStage.timeout:
      return '请求超时。常见原因：后端冷启动、弱网、或 DNS 卡住。';
    case DiagnoseStage.http:
      return '能连通但 HTTP 返回非 200，看上方状态码与响应体。';
    case DiagnoseStage.invalidBaseUrl:
      return 'API 地址配置有误。';
    case DiagnoseStage.ok:
      return '连接正常。';
  }
}

String _clip(String text) {
  final String single = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  return single.length <= 200 ? single : '${single.substring(0, 200)}…';
}

/// 响应体摘要：压空白 + 截断。避免把整屏题干写进日志。
String _clipBody(String raw) => _clip(raw);
