// API 配置（FE-03 联调）。
//
// 两件事在这里集中：走不走真 API、后端地址是什么。
// 都放在常量里，页面与 api 层都不自己拼 URL。

import 'dart:io' show Platform;

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

/// 后端基址，按运行平台切换。
///
/// 为什么 Android 模拟器不能用 localhost：
///   模拟器里的 localhost 指向**模拟器自己**，宿主机在 10.0.2.2（AVD 的标准 NAT 网关）。
///   iOS 模拟器与 Windows 桌面直接跑在宿主机上，所以用 localhost。
///
/// 真机（非模拟器）调试时，需要把这里换成宿主机的局域网 IP，
/// 且后端已监听 0.0.0.0（scripts/dev-start.mjs 已这样做）。
String get kApiBaseUrl {
  if (Platform.isAndroid) return 'http://10.0.2.2:3000';
  return 'http://localhost:3000';
}

/// 单次请求超时。直播网/云库冷启动都可能慢，10s 是对用户可接受的上限。
const Duration kApiTimeout = Duration(seconds: 10);
