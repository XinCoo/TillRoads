// 本地优先架构的开关（docs/local-first-design.md）。
//
// 与 `api_config.dart` 里的 `kUseMock` 放在同一层：都是「影响全局数据来源」的开关，
// 页面与数据层只读它，不各自判断平台。

/// 是否启用「本地优先」数据读取。
///
/// **R2 起为 true**：首页 / 缺陷单 / 验证 / 我的 四个页面先读本地库、
/// 云端降级为后台刷新与写入通道。改回 `false` 即可整体回退到「每页直连云端」
/// 的旧行为（四个页面都保留了那条分支，没有删）。
///
/// 为什么不是 `const`（任务书 A2 写的是 `const bool`）：
///   任务书 D2 要求「初始化失败时把 kLocalFirstEnabled 强制降为 false」。
///   `const` 变量无法赋值，D2 就做不到。这里沿用 `kUseMock` 的既有做法
///   （可变顶层变量 + 注释说明），既能被启动流程降级，也能被 widget test 改写。
///
/// 为什么不在这个文件里 `Platform.isAndroid || Platform.isIOS`：
///   R2 才需要「桌面回退直连」的分支；R1 若引入平台判断，会让
///   `flutter test`（宿主是桌面）拿不到确定值，测试反而更难写。
///   平台收窄放到 R2 的同步引擎入口处，此处只保留一个纯开关。
bool kLocalFirstEnabled = true;

/// 本地库是否**真的能用**（与 [kLocalFirstEnabled] 分开）。
///
/// R4b 修缺口时发现的问题：`kLocalFirstEnabled` 是个「一票否决」的全局开关——
/// 只要 `_initLocalDb()` 抛过一次异常，它就被置成 false，**整个 App（含写操作）
/// 静默退回直连云端**，用户看到的是「提交成功」但其实请求打到了云端、
/// 断网时直接失败，而且没有任何提示。
///
/// 现在拆成两个开关：
///   · [kLocalDbReady] —— 本地库能不能用（只由 `_initLocalDb()` 设置）；
///   · [kLocalFirstEnabled] —— 要不要走「本地优先」这条读路径。
/// 写操作只要 [kLocalDbReady] 为 true 就走写队列；读路径仍受 [kLocalFirstEnabled]
/// 控制，方便一行回退。
bool kLocalDbReady = false;

/// 本地库不可用时的降级原因（给设置页与启动横幅展示）。
String? kLocalDbUnavailableReason;
const String kLocalDbFileName = 'tillroad_local.db';
