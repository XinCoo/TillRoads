// 本地优先架构的开关（docs/local-first-design.md）。
//
// 与 `api_config.dart` 里的 `kUseMock` 放在同一层：都是「影响全局数据来源」的开关，
// 页面与数据层只读它，不各自判断平台。

/// 是否启用「本地优先」数据读取。
///
/// **R1 阶段恒为 false**：本轮只建库、建表、封装 DAO，没有任何页面或 api 层
/// 读这个开关，所以 App 行为与 R1 之前完全一致。R2 接页面时才把它翻成 true。
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
bool kLocalFirstEnabled = false;

/// 本地 SQLite 数据库文件名（sqflite 会放在平台标准目录下）。
const String kLocalDbFileName = 'tillroad_local.db';
