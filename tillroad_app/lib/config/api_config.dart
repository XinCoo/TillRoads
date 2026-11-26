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

/// 当前用户 id 的默认值（`scripts/seed-dev.mjs` 里的固定演示 UUID）。
///
/// 只有在「还没拿到真实用户」时才会用到这个值。
const String kDefaultUserId = '11111111-1111-4111-8111-111111111111';

/// 当前用户 id 在 shared_preferences 里的键名。
const String kCurrentUserIdPrefsKey = 'current_user_id';

/// 运行时可变的当前用户 id。
///
/// ── 为什么从 const 变成 getter ───────────────────────────────────────────
/// 以前它是写死的常量，于是**所有账号**在「我的」页都显示 `1111****`。
/// 现在它由 `GET /me` 返回的真实 id 驱动（切换 Token 成功后写入）。
///
/// ── 注意：它传给 API 时其实无所谓 ───────────────────────────────────────
/// 后端会把 `/users/<任意 id>` 的第 2 段改写成 token 对应用户，
/// 所以调用点传什么 id 都能拿到自己的数据。这个值的实际价值是
/// **让「我的」页显示真实用户 id**（以及作为「复制完整 ID」的来源）。
/// 因此把它改成 getter 后，全工程 50+ 处调用点一行都不用动。
String _currentUserId = kDefaultUserId;

/// 当前用户 id（默认是演示 id，登录后会被真实 id 覆盖）。
String get kDemoUserId => _currentUserId;

/// 设置当前用户 id（只改内存值；落盘请用 [persistCurrentUserId]）。
void setCurrentUserId(String id) {
  final String normalized = id.trim();
  if (normalized.isEmpty) return;
  _currentUserId = normalized;
}

/// 设置并**落盘**当前用户 id（shared_preferences 的 `current_user_id`）。
///
/// 切换 Token 成功后调用：这样下次冷启动时「我的」页还能显示同一个用户。
Future<void> persistCurrentUserId(String id) async {
  final String normalized = id.trim();
  if (normalized.isEmpty) return;
  setCurrentUserId(normalized);
  final preferences = await SharedPreferences.getInstance();
  await preferences.setString(kCurrentUserIdPrefsKey, normalized);
}

/// 启动时恢复上次登录用户的 id。
///
/// 没有缓存时保持默认演示 id（不写盘，等真正拿到 `/me` 再更新）。
Future<void> initializeCurrentUserId() async {
  try {
    final preferences = await SharedPreferences.getInstance();
    final String? cached = preferences.getString(kCurrentUserIdPrefsKey);
    if (cached != null && cached.trim().isNotEmpty) {
      _currentUserId = cached.trim();
    }
  } catch (e) {
    // 读失败不影响启动：保持默认 id 即可（只是「我的」页暂时显示演示 id）。
  }
}

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

/// 用户是否在 App 里手动保存过 Token。
///
/// 为什么要这个标志：`kApiToken` 原本是「构建期 --dart-define 的 token 优先」。
/// 那是给分发用的（一个 APK 发所有人，构建时不带 token；带 token 的包只给开发者）。
/// 但如果用户真在「我的 → 切换 Token」里换了 token，就必须**立刻生效**，
/// 否则会退化成「点了没反应」的静默失败（A3 明确禁止）。
/// 所以：只要用户手动保存过，就以用户保存的为准，构建期的 define 让位。
bool _tokenOverriddenByUser = false;

String? get kApiToken {
  if (_tokenOverriddenByUser) return _apiToken;
  return kApiTokenFromDefine.isNotEmpty ? kApiTokenFromDefine : _apiToken;
}

bool get hasApiToken => (kApiToken ?? '').trim().isNotEmpty;
Future<void> initializeApiToken() async {
  // 顺带恢复上次登录的用户 id —— 这样 main.dart 不需要额外加一行调用
  // （两者都是「启动时读一次本地缓存」的初始化，放在一起最省事）。
  await initializeCurrentUserId();
  final preferences = await SharedPreferences.getInstance();
  final String? saved = preferences.getString('api_token');
  if (saved != null && saved.trim().isNotEmpty) {
    // 本机保存过 token（用户手动输入或切换过）→ 以它为准。
    _apiToken = saved.trim();
    _tokenOverriddenByUser = true;
    return;
  }
  if (kApiTokenFromDefine.isNotEmpty) {
    // 只是在开发/内部分发包里带了 token，且用户还没自己保存过 → 用构建期的。
    _apiToken = kApiTokenFromDefine;
  }
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
