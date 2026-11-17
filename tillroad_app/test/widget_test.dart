// FE-01 冒烟测试：验证首页看板能渲染出关键区块。
//
// 用 `CupertinoApp` 而不是测试模板默认的 `MaterialApp`，
// 与本项目实际根组件（lib/main.dart 的 TillRoadApp）保持一致。
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tillroad_app/main.dart';

void main() {
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

  testWidgets('切换到缺陷单 Tab 显示空状态', (WidgetTester tester) async {
    await tester.pumpWidget(const TillRoadApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('缺陷单'));
    await tester.pumpAndSettle();

    expect(find.text('还没有缺陷单'), findsOneWidget);
    expect(find.text('暂无数据，从一次模考或错题开始'), findsOneWidget);
  });
}
