// 应用身份信息：版本号与展示名。
//
// 为什么硬编码而不引 `package_info_plus`：
//   本项目对新增依赖有硬约束（本轮只允许 share_plus），而版本号是**每次发版
//   必然手动改 pubspec 的东西**，硬编码一份的维护成本低于多一个插件依赖。
//
// ⚠️ 发版铁律：`kAppVersion` 必须与 `pubspec.yaml` 的 `version:` 逐字一致。
//    `flutter build` 不会帮我们同步常量，忘记改会导致导出日志里版本号失真，
//    反过来污染线上排查（这正是本功能存在的意义）。
const String kAppName = '题路 TillRoad';

/// 与 `pubspec.yaml` 的 `version:` 保持一致（`1.1.0+2` = 版本名 + 构建号）。
const String kAppVersion = '1.1.0+2';
