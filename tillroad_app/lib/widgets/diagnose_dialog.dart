// 「连接诊断」弹窗（FE 网络排查）。
//
// 为什么要在 App 里做这个入口：
//   release APK 出网络问题时，用户只能看到一句
//   `ClientException with SocketException: Failed host lookup ...`
//   —— 那行错误既看不出是缺权限、DNS、TLS 还是后端没起，
//   也没法在手机上抓 logcat。把同样的判断搬到界面上，
//   用户点一下就能把「哪一层断了」截图发过来，排查成本从一轮 CI 降到一句话。
//
// 结论分档与 `diagnose()` 里的 DiagnoseStage 一一对应：
//   配置错误 / DNS 解析失败 / HTTPS 握手失败 / 请求超时 / HTTP 异常 / 网络不可达 / 通过

import 'package:flutter/cupertino.dart';

import '../api/api_client.dart';
import '../theme/app_theme.dart';

/// 弹出诊断对话框。直接 `await` 到用户关掉为止。
Future<void> showDiagnoseDialog(BuildContext context) {
  return showCupertinoDialog<void>(
    context: context,
    builder: (BuildContext ctx) => CupertinoAlertDialog(
      title: _dialogTitle(),
      // CupertinoAlertDialog 把 title/content/action 的字体硬编码成
      // 'CupertinoSystemText'，且不暴露 textStyle 参数 —— 所以正文里
      // 每个 Text 都要自己带 fontFamily，否则中文字会回落到系统黑体。
      content: const _DiagnoseBody(),
      actions: <Widget>[
        CupertinoDialogAction(
          isDefaultAction: true,
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text(
            '关闭',
            style: TextStyle(
              fontFamily: kFontFamily,
              fontSize: 17,
              color: AppColors.accent,
            ),
          ),
        ),
      ],
    ),
  );
}

Widget _dialogTitle() => const Text(
  '连接诊断',
  style: TextStyle(
    fontFamily: kFontFamily,
    fontSize: 17,
    fontWeight: FontWeight.w600,
    color: AppColors.label,
  ),
);

class _DiagnoseBody extends StatefulWidget {
  const _DiagnoseBody();

  @override
  State<_DiagnoseBody> createState() => _DiagnoseBodyState();
}

class _DiagnoseBodyState extends State<_DiagnoseBody> {
  DiagnoseResult? _result;
  int _attempt = 0;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    final int attempt = ++_attempt;
    final DiagnoseResult result = await diagnose();
    // 连续点「重试」时，只认最后一次的结果，避免旧结果把新结果盖掉
    if (!mounted || attempt != _attempt) return;
    setState(() => _result = result);
  }

  Color get _stageColor {
    switch (_result?.stage) {
      case DiagnoseStage.ok:
        return AppColors.normal;
      case DiagnoseStage.invalidBaseUrl:
      case DiagnoseStage.dns:
      case DiagnoseStage.tls:
        return AppColors.overdue;
      case DiagnoseStage.timeout:
      case DiagnoseStage.network:
      case DiagnoseStage.http:
        return AppColors.dueSoon;
      case null:
        return AppColors.secondaryLabel;
    }
  }

  @override
  Widget build(BuildContext context) {
    final DiagnoseResult? result = _result;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (result == null)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const CupertinoActivityIndicator(radius: 7),
              const SizedBox(width: 8),
              const Flexible(
                child: Text(
                  '正在检查网络…',
                  style: TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 13,
                    color: AppColors.label,
                  ),
                ),
              ),
            ],
          )
        else ...<Widget>[
          // 结论：色点 + 分档标签，扫一眼就知道断在哪层
          Row(
            children: <Widget>[
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: _stageColor,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  result.stage.label,
                  style: TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: _stageColor,
                  ),
                ),
              ),
              Text(
                '${result.elapsed.inMilliseconds}ms',
                style: const TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 12,
                  color: AppColors.secondaryLabel,
                  fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            result.message,
            style: const TextStyle(
              fontFamily: kFontFamily,
              fontSize: 12,
              color: AppColors.label,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 10),
          _row('地址', result.baseUrl),
          if (result.uri != null) _row('请求', result.uri.toString()),
          if (result.statusCode != null) _row('状态码', '${result.statusCode}'),
          if (result.rawError != null) _row('原始错误', result.rawError!),
          const SizedBox(height: 10),
          Center(
            child: CupertinoButton(
              padding: EdgeInsets.zero,
              minimumSize: Size.zero,
              onPressed: () {
                setState(() => _result = null);
                _run();
              },
              child: const Text(
                '重试',
                style: TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppColors.accent,
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  /// 一行「标签 / 值」。值用等宽数字 + 允许换行，长 URL 不会被截断。
  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 56,
            child: Text(
              label,
              style: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: 12,
                color: AppColors.secondaryLabel,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: 12,
                color: AppColors.label,
                height: 1.3,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 供非弹窗场景（如设置页）复用的纯文本摘要。
String diagnoseSummary(DiagnoseResult result) {
  final StringBuffer buffer = StringBuffer()
    ..writeln('${result.stage.label}（${result.elapsed.inMilliseconds}ms）')
    ..writeln(result.message)
    ..writeln('地址：${result.baseUrl}');
  if (result.uri != null) buffer.writeln('请求：${result.uri}');
  if (result.statusCode != null) buffer.writeln('状态码：${result.statusCode}');
  if (result.rawError != null) buffer.writeln('原始错误：${result.rawError}');
  return buffer.toString();
}

/// 诊断入口的图标与无障碍标签（首页导航栏用）。
const IconData kDiagnoseIcon = CupertinoIcons.wifi;
const String kDiagnoseLabel = '连接诊断';
