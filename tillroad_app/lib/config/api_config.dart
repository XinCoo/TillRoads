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

String get kApiBaseUrl {
  const configured = String.fromEnvironment('API_BASE_URL');
  if (configured.isNotEmpty) return configured;
  return kRailwayApiBaseUrl;
}

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
