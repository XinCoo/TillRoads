// API 配置（FE-03 联调）。
//
// 两件事在这里集中：走不走真 API、后端地址是什么。
// 都放在常量里，页面与 api 层都不自己拼 URL。

import 'package:shared_preferences/shared_preferences.dart';

/// 是否使用本地 mock 数据。
///
/// 默认 false —— 即真实 API。保留 true 的用途：
///   · 后端没启动时仍能演示界面（离线演示 / 评审看 UI）
///   · 自动化测试注入 fake 数据
///
/// 为什么不是 `const`：widget test 需要在运行时把它翻成 true，
/// 否则测试会真的去连 10.0.2.2:3000（CI/本机无后端时必然超时）。
/// 生产代码路径仍然只读这个值，不写它。
bool kUseMock = false;

/// 联调用的演示用户 id，与 `scripts/seed-dev.mjs` 里的固定 UUID 一致。
///
/// 真实产品里这个值应来自登录态；本轮没有鉴权体系（见遗留项），
/// 所以先写死。它只影响「查哪个用户的缺陷单」，不影响任何写操作。
const String kDemoUserId = '11111111-1111-4111-8111-111111111111';

/// API base URL. Override for deployment with `--dart-define=API_BASE_URL=...`.
const String kRailwayApiBaseUrl = 'https://tillroads-production.up.railway.app';

/// 未清洗的原始 base URL（dart-define 优先）。
///
/// 为什么要清洗：`--dart-define=API_BASE_URL="https://x/"` 或手输带空格时，
/// 引号与空格会原样进入字符串，拼出来就是 `https://x//users/...`、
/// `"https://x"/users/...` 这类畸形 URL，报错信息里就会看到奇形字符。
String get kApiBaseUrlRaw {
  const configured = String.fromEnvironment('API_BASE_URL');
  return configured.isNotEmpty ? configured : kRailwayApiBaseUrl;
}

/// 清洗后的 base URL：去首尾空白、去引号、去尾部斜杠、校协议与 host。
///
/// 非法时返回 null（由调用方当成配置错误报给用户，而不是拼出一个坏 URL 去发请求）。
String? normalizeBaseUrl(String raw) {
  String s = raw.trim();
  // 半角/全角引号都剥掉：dart-define 或用户复制粘贴常带
  s = s.replaceAll('"', '').replaceAll("'", '').replaceAll('\u201C', '').replaceAll('\u201D', '').trim();
  if (s.isEmpty) return null;
  final Uri? uri = Uri.tryParse(s);
  if (uri == null) return null;
  if (uri.scheme != 'http' && uri.scheme != 'https') return null;
  if (uri.host.isEmpty) return null;
  // 去掉尾部斜杠（根路径本身就空），并丢掉 query/fragment——base URL 不该带这些
  String path = uri.path;
  while (path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  return uri.replace(path: path, query: null, fragment: null).toString();
}

/// 实际使用的 base URL（已清洗）。恒不以 `/` 结尾，可直接 `'$kApiBaseUrl$path'`。
///
/// 清洗失败时保留原始值，让请求处抛出带原文的配置错误（便于用户自查），
/// 而不是静默回落到官方地址连出一个「不该成功却成功」的结果。
String get kApiBaseUrl => normalizeBaseUrl(kApiBaseUrlRaw) ?? kApiBaseUrlRaw.trim();


/// API token supplied at build/run time, or entered once on first launch.
const String kApiTokenFromDefine = String.fromEnvironment('API_TOKEN');
String? _apiToken;

String? get kApiToken =>
    kApiTokenFromDefine.isNotEmpty ? kApiTokenFromDefine : _apiToken;

bool get hasApiToken => kApiTokenFromDefine.trim().isNotEmpty || (_apiToken ?? '').trim().isNotEmpty;
Future<void> initializeApiToken() async {
  if (kApiTokenFromDefine.isNotEmpty) {
    _apiToken = kApiTokenFromDefine;
    return;
  }
  final preferences = await SharedPreferences.getInstance();
  _apiToken = preferences.getString('api_token');
}

Future<void> saveApiToken(String token) async {
  final normalized = token.trim();
  final preferences = await SharedPreferences.getInstance();
  if (normalized.isEmpty) {
    await preferences.remove('api_token');
    _apiToken = null;
  } else {
    await preferences.setString('api_token', normalized);
    _apiToken = normalized;
  }
}

/// 单次请求超时。
const Duration kApiTimeout = Duration(seconds: 15);
