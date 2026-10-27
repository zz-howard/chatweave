import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'acceptance_test.dart' as acceptance;
import 'golden_matrix_test.dart' as fixtures;

import 'package:chatweave_core/testing.dart';
import 'package:chatweave_flutter/chatweave_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markdown/markdown.dart' as md;

import 'rendering_test.dart' as rendering;
import 'flutter_test_config.dart' as fonts;

void main() {
  test('test_font_hash_mismatch_fails_before_loading', () async {
    final directory = Directory.systemTemp.createTempSync('cw-font-');
    try {
      File('${directory.path}/manifest.json')
          .writeAsStringSync(jsonEncode({'outputSha256': 'wrong'}));
      File('${directory.path}/ChatWeaveTestSans.otf')
          .writeAsBytesSync([1, 2, 3]);
      await expectLater(
        fonts.loadVerifiedTestFont(fontDirectory: directory.path),
        throwsStateError,
      );
    } finally {
      directory.deleteSync(recursive: true);
    }
  });
  test(
    'line_chart_small_range_uses_full_height_and_zero_range_is_symmetric',
    () {
      final range = lineChartRange([0.1, 0.2, 0.4]);
      expect(range.low, 0.1);
      expect(range.high, 0.4);
      expect((0.4 - range.low) / (range.high - range.low), 1);
      final zero = lineChartRange([0, 0]);
      expect(zero.low, -zero.high);
      expect(zero.high, greaterThan(0));
    },
  );
  for (final type in ['choice', 'confirmation', 'form_intent']) {
    testWidgets('registry_override_${type}_version_and_error_boundary', (
      tester,
    ) async {
      var reports = 0;
      final registry = BlockRegistry.withDefaults(
        onBlockRenderError: (_, __) {
          reports++;
        },
      );
      final original = fixtures.fixture(type);
      final block = Block.fromJson({...original.json, 'schemaVersion': 2});
      Message message() => Message.fromJson({
            ...acceptance.message('m').json,
            'blocks': [block.json],
          });
      registry.override(
        type,
        BlockRegistration(
          maxSchemaVersion: 2,
          build: (_, __) => const Text('宿主覆盖'),
        ),
      );
      await tester.pumpWidget(
        rendering.app(
          MessageView(
            message: message(),
            registry: registry,
            processState: ProcessState(),
          ),
        ),
      );
      expect(find.text('宿主覆盖'), findsOneWidget);
      registry.override(
        type,
        BlockRegistration(
          maxSchemaVersion: 2,
          build: (_, __) => throw StateError('builder'),
        ),
      );
      await tester.pumpWidget(
        rendering.app(
          MessageView(
            message: message(),
            registry: registry,
            processState: ProcessState(),
          ),
        ),
      );
      expect(find.text('宿主覆盖'), findsNothing);
      expect(reports, 1);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('line_chart_small_range_paints_high_point_at_top', (
    tester,
  ) async {
    await tester.pumpWidget(
      rendering.app(
        const LineChartView(
          summary: '天气',
          data: {
            'series': [
              {
                'label': '气温',
                'points': [
                  {'x': 0, 'y': 0.1},
                  {'x': 1, 'y': 0.4},
                ],
              },
            ],
          },
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
    await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      chart.painter!.paint(ui.Canvas(recorder), const Size(200, 180));
      final picture = recorder.endRecording();
      final image = await picture.toImage(200, 180);
      final pixels = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      expect(pixels!.getUint8((8 * 200 + 192) * 4 + 3), greaterThan(0));
      image.dispose();
      picture.dispose();
    });
  });

  testWidgets('default_interaction_through_registry_can_submit', (
    tester,
  ) async {
    final block = fixtures.fixture('choice');
    final message = Message.fromJson({
      ...acceptance.message('m').json,
      'blocks': [block.json],
    });
    final store = BlockStore()..apply(SyncMessage(message));
    final transport = ScriptedTransport(
      connections: [],
      actions: [(_) async => const ActionSubmission.queued()],
    );
    final interactions = InteractionController(
      store: store,
      persistence: MemoryStore(),
      transport: transport,
      nextId: () => 'one',
    );
    await tester.pumpWidget(
      rendering.app(
        MessageView(
          message: message,
          interactions: interactions,
          registry: BlockRegistry.withDefaults(),
          processState: ProcessState(),
        ),
      ),
    );
    final label = objects(block.data['options']).first['label'] as String;
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
    expect(transport.requests.length, 1);
    expect(transport.requests.single.id, 'one');
    await tester.pumpWidget(rendering.app(const SizedBox()));
    await interactions.dispose();
  });

  testWidgets('default_descendant_format_exception_degrades_entire_block', (
    tester,
  ) async {
    var reports = 0;
    final registry = BlockRegistry.withDefaults(
      onBlockRenderError: (_, __) {
        reports++;
      },
    );
    // Validation succeeds for the documented maximumFractionDigits, but the
    // formatter may still throw; work executes in MetricTile's own boundary.
    registry.override(
      'metric',
      BlockRegistration(
        build: (_, b) => MetricTile(
          data: {
            ...b.data,
            'format': {'maximumFractionDigits': 10000},
            'value': 0.25,
          },
        ),
      ),
    );
    final b = fixtures.fixture('metric');
    await tester.pumpWidget(
      rendering.app(
        Column(
          children: [
            registry.render(
              Block.fromJson({...b.json, 'fallbackText': '单块降级'}),
            ),
            const Text('兄弟块正常'),
          ],
        ),
      ),
    );
    await tester.pump();
    expect(find.text('单块降级'), findsOneWidget);
    expect(find.text('兄弟块正常'), findsOneWidget);
    expect(reports, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('retryable_card_exposes_same_intent_retry_button', (
    tester,
  ) async {
    final block = fixtures.fixture('choice');
    final message = Message.fromJson({
      ...acceptance.message('m').json,
      'blocks': [block.json],
    });
    final store = BlockStore()..apply(SyncMessage(message));
    final transport = ScriptedTransport(
      connections: [],
      actions: [
        (_) async => throw StateError('offline'),
        (_) async => const ActionSubmission.queued(),
      ],
    );
    final interactions = InteractionController(
      store: store,
      persistence: MemoryStore(),
      transport: transport,
      nextId: () => 'same',
      maxAutomaticRetries: 0,
    );
    await interactions.submit('m', block.id, {
      'selected': ['bj'],
    });
    await tester.pumpWidget(
      rendering.app(
        MessageView(
          message: message,
          interactions: interactions,
          registry: BlockRegistry.withDefaults(),
          processState: ProcessState(),
        ),
      ),
    );
    expect(find.text('重试'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(transport.requests.map((r) => r.id).toList(), ['same', 'same']);
    expect(find.text('已排队，联网后提交'), findsOneWidget);
    await tester.pumpWidget(rendering.app(const SizedBox()));
    await interactions.dispose();
  });

  testWidgets('stop_in_list_disables_button_and_shows_stopping', (
    tester,
  ) async {
    final store = BlockStore()
      ..apply(
        SyncMessage(
          Message.fromJson({
            ...acceptance.message('m').json,
            'status': 'streaming',
            'rev': 0,
            'lastSeq': 1,
          }),
        ),
      );
    var stops = 0;
    await tester.pumpWidget(
      rendering.app(
        ChatWeaveList(
          store: store,
          registry: BlockRegistry.withDefaults(),
          conversationId: 'c',
          onStop: (_) {
            stops++;
          },
        ),
      ),
    );
    await tester.tap(find.text('停止'));
    await tester.pump();
    expect(find.text('正在停止…'), findsOneWidget);
    final button = tester.widget<TextButton>(
      find.ancestor(of: find.text('正在停止…'), matching: find.byType(TextButton)),
    );
    expect(button.onPressed, isNull);
    expect(stops, 1);
  });

  testWidgets('delegate_row_toggle_keeps_tapped_row_anchor', (tester) async {
    final store = BlockStore();
    for (var i = 0; i < 20; i++) {
      if (i == 10) {
        store.apply(
          SyncMessage(
            acceptance.message(
              'target',
              steps: [
                {
                  'id': 'delegate',
                  'kind': 'delegate',
                  'label': '委派天气',
                  'state': 'succeeded',
                },
                {
                  'id': 'child',
                  'parentStepId': 'delegate',
                  'label': '子步骤天气',
                  'state': 'succeeded',
                },
              ],
            ),
          ),
        );
      }
      store.apply(SyncMessage(acceptance.message('m$i', text: '天气 $i\n' * 3)));
    }
    await tester.pumpWidget(
      rendering.app(
        ChatWeaveList(
          store: store,
          registry: BlockRegistry.withDefaults(),
          conversationId: 'c',
        ),
      ),
    );
    final row = find.textContaining('委派天气');
    await tester.scrollUntilVisible(
      row,
      150,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    for (var i = 0; i < 2; i++) {
      final before = tester.getTopLeft(row).dy;
      await tester.tap(row);
      await tester.pump();
      await tester.pump();
      expect(tester.getTopLeft(row).dy, closeTo(before, 1));
    }
    await tester.pumpWidget(rendering.app(const SizedBox()));
    await store.dispose();
  });

  testWidgets('composer_input_has_no_live_region_ancestor', (tester) async {
    final store = BlockStore();
    final actions = InteractionController(
      store: store,
      persistence: MemoryStore(),
      nextId: () => 'id',
    );
    final controller = InterruptComposerController(
      store: store,
      interactions: actions,
      conversationId: 'c',
    );
    final draft = TextEditingController();
    await tester.pumpWidget(
      rendering.app(
        ChatWeaveComposer(controller: controller, draft: draft, onSend: (_) {}),
      ),
    );
    final regions = tester.widgetList<Semantics>(
      find.ancestor(
        of: find.byType(TextField),
        matching: find.byType(Semantics),
      ),
    );
    expect(regions.where((s) => s.properties.liveRegion == true), isEmpty);
    expect(
        find.byWidgetPredicate(
            (w) => w is Icon && w.icon?.fontFamily == 'MaterialIcons'),
        findsNothing);
    await tester.pumpWidget(rendering.app(const SizedBox()));
    draft.dispose();
    // Stream close completion is real asynchronous cleanup, outside the fake
    // widget clock (there are no frames left to pump after unmounting).
    await tester.runAsync(() async {
      await controller.dispose();
      await actions.dispose();
    });
  });

  testWidgets('incremental_tail_displays_every_token_between_parses', (
    tester,
  ) async {
    for (var i = 0; i < 10; i++) {
      final text = '天气${'晴' * (i + 1)}';
      await tester.pumpWidget(
        rendering.app(MarkdownBlockView(text: text, complete: false)),
      );
      final visible = tester
          .widgetList<RichText>(find.byType(RichText))
          .map((w) => w.text.toPlainText())
          .join();
      expect(visible, contains(text));
      expect(tester.takeException(), isNull);
    }
  });

  test('incremental_markdown_geometric_cost_and_exact_loose_lists_references',
      () {
    final document = IncrementalDocument();
    var source = '普通段落\n\n';
    for (var i = 0; i < 2000; i++) {
      source += '字';
      document.update(source);
    }
    expect(document.parsedCharacters, lessThan(source.length * 4));
    expect(document.tailParseCount, lessThan(20));
    source += '\n\n- 第一项\n\n- 第二项 [天气][city]\n\n[city]: https://example.org\n';
    document.update(source, complete: true);
    String tree(md.Node n) => n is md.Element
        ? '<${n.tag}:${n.attributes}>${(n.children ?? []).map(tree).join()}</${n.tag}>'
        : n.textContent;
    expect(
      [
        ...document.stableNodes.expand((n) => n),
        ...document.tailNodes,
      ].map(tree).join(),
      parseSafeMarkdown(source).map(tree).join(),
    );
    expect(document.fullParseCount, lessThan(10));
  });

  for (final kind in ['bytes', 'depth', 'nodes']) {
    testWidgets('consumer_${kind}_limit_fallback_preserves_sibling', (
      tester,
    ) async {
      Object? extra = true;
      for (var i = 0; i < 7; i++) {
        extra = {'nested': extra};
      }
      final bad = Block.fromJson({
        'id': 'bad',
        'type': 'markdown',
        'schemaVersion': 1,
        'fallbackText': '单块超限',
        'data': {
          'text': kind == 'bytes' ? 'a' * 32769 : 'ok',
          if (kind == 'depth') 'extra': extra,
          if (kind == 'nodes') 'extra': List.filled(5001, 0),
        },
      });
      final registry = BlockRegistry.withDefaults();
      await tester.pumpWidget(
        rendering.app(
          Column(children: [registry.render(bad), const Text('正常天气')]),
        ),
      );
      expect(find.text('单块超限'), findsOneWidget);
      expect(find.text('正常天气'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
