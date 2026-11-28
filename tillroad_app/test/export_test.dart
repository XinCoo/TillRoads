// test/export_test.dart
// 题路 TillRoad · m32406：题库导出（纯函数与本地化文案）单元测试
//
// 为什么只测这些：
//   * `ExportService.exportQuestions()` 与 `ExportLocation.pickAndSaveDirectory()`
//     都依赖平台插件（SAF / 目录选择器），在 `flutter test` 的 headless 环境里
//     没有真实实现，强行 mock 只能证明 mock 能跑，证明不了导出链路。
//   * 但文件名生成 / 体积文案 / 目录名解码 / 三态结果这四个是**纯函数**，
//     也正是用户直接看到的那些字符串，最值得锁死。
//
// 真库链路（GET /export/questions + 50 题体积）由 `server/routes/export.integration.test.mjs`
// 与 m32406 的 E4 证据脚本覆盖。

import 'dart:io' show Platform;

import 'package:flutter_test/flutter_test.dart';
import 'package:tillroad_app/services/export_location.dart';
import 'package:tillroad_app/services/export_service.dart';

void main() {
  group('ExportService.buildFileName', () {
    test('格式：tillroad-export-{userId前8位}-{YYYYMMDD-HHmmss}.tillroad', () {
      final String name = ExportService.buildFileName(
        '11111111-1111-4111-8111-111111111111',
        now: DateTime(2026, 11, 28, 12, 15, 30),
      );
      expect(name, 'tillroad-export-11111111-20261128-121530.tillroad');
    });

    test('月份/日/时/分/秒都补零到两位', () {
      final String name = ExportService.buildFileName(
        'abcdefgh-0000-0000-0000-000000000000',
        now: DateTime(2026, 1, 2, 3, 4, 5),
      );
      // 1 月 2 日 3:04:05 → 0102-030405
      expect(name, 'tillroad-export-abcdefgh-20260102-030405.tillroad');
    });

    test('userId 不足 8 位时原样使用（不补空格、不抛越界）', () {
      final String name = ExportService.buildFileName(
        'abc',
        now: DateTime(2026, 11, 28, 1, 2, 3),
      );
      expect(name, 'tillroad-export-abc-20261128-010203.tillroad');
    });

    test('恰好 8 位时取全 8 位', () {
      final String name = ExportService.buildFileName(
        '12345678',
        now: DateTime(2026, 11, 28, 0, 0, 0),
      );
      expect(name, 'tillroad-export-12345678-20261128-000000.tillroad');
    });

    test('后缀常量固定为 .tillroad（导入端按它识别）', () {
      expect(kExportFileSuffix, '.tillroad');
      final String name = ExportService.buildFileName('11111111');
      expect(name.endsWith(kExportFileSuffix), isTrue);
      expect(name.startsWith('tillroad-export-'), isTrue);
    });
  });

  group('ExportResult.sizeLabel', () {
    ExportResult withSize(int size) => ExportResult(
          path: '主存储/Download/TillRoad/x.tillroad',
          size: size,
          questionCount: 1,
          fileName: 'x.tillroad',
        );

    test('小于 1 KB 用字节', () {
      expect(withSize(0).sizeLabel, '0 B');
      expect(withSize(512).sizeLabel, '512 B');
      expect(withSize(1023).sizeLabel, '1023 B');
    });

    test('1 KB ~ 1024 KB 用一位小数的 KB', () {
      expect(withSize(1024).sizeLabel, '1.0 KB');
      expect(withSize(3094).sizeLabel, '3.0 KB');
      expect(withSize(153600).sizeLabel, '150.0 KB');
    });

    test('超过 1024 KB 用两位小数的 MB', () {
      expect(withSize(1024 * 1024).sizeLabel, '1.00 MB');
      expect(withSize(3 * 1024 * 1024 + 512 * 1024).sizeLabel, '3.50 MB');
    });
  });

  group('ExportException', () {
    test('toString 带上分档名与消息（日志里能直接看出是哪一档）', () {
      final ExportException e =
          ExportException(ExportFailureKind.location, '导出失败：目录不可写');
      expect(e.kind, ExportFailureKind.location);
      expect(e.message, '导出失败：目录不可写');
      expect(e.toString(), 'ExportException(location): 导出失败：目录不可写');
    });

    test('四档枚举齐全（任务书 C3 要求分档）', () {
      expect(ExportFailureKind.values.length, 4);
      expect(
        ExportFailureKind.values.map((ExportFailureKind k) => k.name).toList(),
        <String>['network', 'location', 'compress', 'other'],
      );
    });
  });

  group('ExportPickResult 三态', () {
    test('picked：有 token，不是取消也不是失败', () {
      final ExportPickResult r = ExportPickResult.picked('content://tree/x');
      expect(r.token, 'content://tree/x');
      expect(r.cancelled, isFalse);
      expect(r.isPicked, isTrue);
      expect(r.isFailed, isFalse);
      expect(r.error, isNull);
    });

    test('cancelled：没有 token、没有错误 —— 调用方不该弹错误提示', () {
      final ExportPickResult r = ExportPickResult.cancelled();
      expect(r.token, isNull);
      expect(r.cancelled, isTrue);
      expect(r.isPicked, isFalse);
      expect(r.isFailed, isFalse);
      expect(r.error, isNull);
    });

    test('failed：有错误文案、不是取消', () {
      final ExportPickResult r = ExportPickResult.failed('无法获得该目录的长期写入权限');
      expect(r.isFailed, isTrue);
      expect(r.error, '无法获得该目录的长期写入权限');
      expect(r.cancelled, isFalse);
      expect(r.isPicked, isFalse);
    });
  });

  group('ExportLocation.describeToken', () {
    test('null / 空串 → 未设置文案', () {
      expect(ExportLocation.describeToken(null), '未设置，导出时选择');
      expect(ExportLocation.describeToken(''), '未设置，导出时选择');
      expect(ExportLocation.describeToken('   '), '未设置，导出时选择');
    });

    test('Android SAF 的 primary: 树 URI → 主存储/...', () {
      // 真实的 ACTION_OPEN_DOCUMENT_TREE 返回形态（%3A 是冒号、%2F 是斜杠）
      const String uri =
          'content://com.android.externalstorage.documents/tree/primary%3ADownload%2FTillRoad';
      expect(ExportLocation.describeToken(uri), '主存储/Download/TillRoad');
    });

    test('Android SAF 的 home: 树 URI → 文档/...', () {
      const String uri =
          'content://com.android.externalstorage.documents/tree/home%3ADocuments%2FTillRoad';
      expect(ExportLocation.describeToken(uri), '文档/Documents/TillRoad');
    });

    test('带 documentId 后缀（#）时截掉', () {
      const String uri =
          'content://com.android.externalstorage.documents/tree/primary%3ADownload%2FTillRoad#primary:Download/TillRoad';
      expect(ExportLocation.describeToken(uri), '主存储/Download/TillRoad');
    });

    test('file:// URI（Windows/Linux 的 token）→ 本地路径', () {
      if (Platform.isWindows) {
        expect(
          ExportLocation.describeToken('file:///C:/Users/me/Desktop'),
          'C:\\Users\\me\\Desktop',
        );
      } else {
        expect(
          ExportLocation.describeToken('file:///home/me/Desktop'),
          '/home/me/Desktop',
        );
      }
    });

    test('认不出的非 URI 串：iOS/macOS 显示通用文案，其它平台原样返回', () {
      const String bookmark = 'Ym9va21hcms==';
      final String description = ExportLocation.describeToken(bookmark);
      if (Platform.isIOS || Platform.isMacOS) {
        expect(description, '已选择的文件夹');
      } else {
        expect(description, bookmark);
      }
    });
  });
}
