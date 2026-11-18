// FE-01 冒烟测试：验证首页看板能渲染出关键区块。
//
// 用 `CupertinoApp` 而不是测试模板默认的 `MaterialApp`，
// 与本项目实际根组件（lib/main.dart 的 TillRoadApp）保持一致。
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tillroad_app/config/api_config.dart';
import 'package:tillroad_app/main.dart';
void main() {
  // FE-03 联调后，列表/详情默认走真实 API。widget test 里没有后端，
  // 必须在每个用例前把开关拨回 mock，否则会真的发 HTTP 并超时 10s。
  // 用 setUp 而不是全局一次性赋值，是为了防未来某个用例把它改回去。
  setUp(() {
    kUseMock = true;
  });

  testWidgets('首页首屏：Tab 栏、大标题、倒计时与待验证任务', (WidgetTester tester) async {
    await tester.pumpWidget(const TillRoadApp());
    await tester.pumpAndSettle();

    // 底部 Tab 全部就位
    expect(find.text('首页'), findsOneWidget);
    expect(find.text('缺陷单'), findsOneWidget);
    expect(find.text('验证'), findsOneWidget);
    expect(find.text('模考'), findsOneWidget);
    expect(find.text('复盘'), findsOneWidget);

    // 大标题（largeTitle 与折叠后 middle 各一个，故用 findsWidgets）
    expect(find.text('题路'), findsWidgets);

    // 倒计时卡片：mock 里是「省考 · 行测」+ 47 天
    expect(find.text('省考 · 行测'), findsOneWidget);
    expect(find.text('47'), findsOneWidget);

    // 3 条 mock 验证任务（首屏可见部分）
    expect(find.text('判断推理 · 充分必要条件'), findsOneWidget);
  });

  testWidgets('首页向下滚动出现缺陷分布与快捷入口', (WidgetTester tester) async {
    await tester.pumpWidget(const TillRoadApp());
    await tester.pumpAndSettle();

    // 默认测试视口只有 800×600，缺陷分布与快捷入口在折叠线以下，
    // 必须显式滚动，否则 find 会报 "Found 0 widgets"。
    final Finder scrollable = find.byType(Scrollable).first;

    await tester.scrollUntilVisible(
      find.text('快捷入口'),
      200,
      scrollable: scrollable,
    );
    await tester.pumpAndSettle();

    // 滚动后顶部区块已被移出视口（Sliver 会回收），
    // 所以只断言此刻仍在视口内的内容。
    expect(find.text('缺陷分布'), findsOneWidget);
    expect(find.text('快捷入口'), findsOneWidget);

    // 四个快捷入口
    expect(find.text('建题'), findsOneWidget);
    expect(find.text('转缺陷单'), findsOneWidget);
    expect(find.text('开始模考'), findsOneWidget);
  });

  testWidgets('切换到缺陷单 Tab 显示列表（FE-03 替换了空状态）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const TillRoadApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('缺陷单'));
    await tester.pumpAndSettle();

    // FE-03 起这个 Tab 是真实列表，不再是空状态。
    // mock 第一条是 DRAFT 的「判断推理 · 类比推理」。
    expect(find.text('判断推理 · 类比推理'), findsWidgets);
    // 四个筛选 chip 都在（「待验证」同时是 ACTION_DONE 的状态徽标文案，
    // 所以这里用 findsWidgets 而不是 findsOneWidget）
    expect(find.text('全部'), findsOneWidget);
    expect(find.text('进行中'), findsOneWidget);
    expect(find.text('待验证'), findsWidgets);
    expect(find.text('已关闭'), findsWidgets);
  });

  testWidgets('缺陷单筛选条切到「已关闭」只剩 CLOSED 那条', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const TillRoadApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('缺陷单'));
    await tester.pumpAndSettle();

    // 点筛选 chip（chip 里的「已关闭」文字）
    await tester.tap(find.text('已关闭'));
    await tester.pumpAndSettle();

    // 只剩 dt-0008 这类 CLOSED 条目可见
    expect(find.text('资料分析 · 比重变化'), findsWidgets);
  });

  testWidgets('点击列表卡片进入详情页，展示六栏与三次验证', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const TillRoadApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('缺陷单'));
    await tester.pumpAndSettle();

    // 点第一条卡片进详情
    await tester.tap(find.text('判断推理 · 类比推理').first);
    await tester.pumpAndSettle();

    // 详情页的前三个分组（时间线在下方，需滚动）
    expect(find.text('基本信息'), findsOneWidget);
    expect(find.text('处理动作'), findsOneWidget);
    expect(find.text('三次验证'), findsOneWidget);

    // 三次验证的三个阶段
    expect(find.text('V1'), findsOneWidget);
    expect(find.text('V2'), findsOneWidget);
    expect(find.text('V3'), findsOneWidget);

    // 滚动到最底才看得到状态时间线
    await tester.scrollUntilVisible(
      find.text('状态时间线'),
      200,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();
    expect(find.text('状态时间线'), findsOneWidget);
  });
}
