import 'package:chatweave_flutter/chatweave_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'acceptance_test.dart' as acceptance;
import 'golden_matrix_test.dart' as fixtures;
import 'rendering_test.dart' as rendering;

void main() {
  testWidgets('normal_time_series_paints_three_points_and_two_segments', (
    tester,
  ) async {
    final block = fixtures.fixture('time_series');
    await tester.pumpWidget(
      rendering.app(
        LineChartView(
          data: block.data,
          summary: block['fallbackText'] as String,
        ),
      ),
    );
    final chart = tester.widget<CustomPaint>(
      find.byWidgetPredicate(
        (w) =>
            w is CustomPaint &&
            w.painter.runtimeType.toString() == '_LinePainter',
      ),
    );
    expect(
        (Canvas canvas) => chart.painter!.paint(canvas, const Size(200, 180)),
        paintsExactlyCountTimes(#drawCircle, 3));
    expect(
        (Canvas canvas) => chart.painter!.paint(canvas, const Size(200, 180)),
        paintsExactlyCountTimes(#drawLine, 2));
  });

  testWidgets('process_expansion_and_zero_counts_are_not_visible_text', (
    tester,
  ) async {
    final message = acceptance.message(
      'm',
      steps: [
        {
          'id': 'delegate',
          'kind': 'delegate',
          'label': '天气',
          'state': 'running',
        },
        {
          'id': 'child',
          'parentStepId': 'delegate',
          'label': '天气',
          'state': 'awaiting_user',
          'blockId': 'card',
        },
      ],
    );
    final paused = Message.fromJson({
      ...message.json,
      'status': 'paused',
      'rev': 0,
      'blocks': [
        {...fixtures.fixture('confirmation').json, 'id': 'card'},
      ],
    });
    final state = ProcessState();
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      rendering.app(ProcessStrip(message: paused, state: state)),
    );
    for (var i = 0; i < 2; i++) {
      final text = tester
          .widgetList<Text>(find.byType(Text))
          .map((w) => w.data ?? '')
          .join();
      expect(text, isNot(contains('已展开')));
      expect(text, isNot(contains('已收起')));
      expect(text, isNot(contains('你确认了 0')));
      expect(text, isNot(contains('0 步')));
      expect(
        find.byWidgetPredicate(
          (w) => w is Semantics && w.properties.expanded != null,
        ),
        findsWidgets,
      );
      await tester.tap(find.textContaining('过程：'));
      await tester.pump();
    }
    semantics.dispose();
  });

  for (final dark in [false, true]) {
    testWidgets('semantic_control_colors_${dark ? 'dark' : 'light'}', (
      tester,
    ) async {
      final theme = dark
          ? ChatWeaveThemeData.neutralDark()
          : ChatWeaveThemeData.neutralLight();
      await tester.pumpWidget(
        rendering.app(
          ChatWeaveTheme(
            data: theme,
            child: Column(
              children: [
                ChatWeaveTextButton(onPressed: () {}, child: const Text('提交')),
                const ChatWeaveTextButton(onPressed: null, child: Text('取消')),
                const StatusView(
                  data: {
                    'label': '天气',
                    'state': 'running',
                    'progress': {'current': 1, 'total': 2},
                  },
                ),
              ],
            ),
          ),
        ),
      );
      for (final button in tester.widgetList<TextButton>(
        find.byType(TextButton),
      )) {
        for (final states in [
          <WidgetState>{},
          {WidgetState.disabled},
        ]) {
          final fg = button.style!.foregroundColor!.resolve(states)!;
          final bg = button.style!.backgroundColor!.resolve(states)!;
          expect(contrastRatio(fg, bg), greaterThanOrEqualTo(4.5));
        }
      }
      expect(
        contrastRatio(theme.critical, theme.surface),
        greaterThanOrEqualTo(4.5),
      );
      final progress = tester.widget<Text>(find.textContaining('1 / 2'));
      expect(
        contrastRatio(progress.style!.color!, theme.surface),
        greaterThanOrEqualTo(4.5),
      );
    });
  }
}
