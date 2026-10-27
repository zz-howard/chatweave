import 'package:chatweave_flutter/chatweave_flutter.dart' hide StreamController;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' as rendering;
import 'package:flutter_test/flutter_test.dart';
import 'package:markdown/markdown.dart' as md;

Block block(String type, {String id = 'b'}) => Block.fromJson({
      'id': id,
      'type': type,
      'schemaVersion': 1,
      'fallbackText': '降级文字',
      'data': {'text': '正文'},
    });
Widget app(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('consumer_bad_blocks_degrade_without_losing_siblings',
      (tester) async {
    final store = BlockStore();
    final registry = BlockRegistry.withDefaults();
    final message = Message.fromJson({
      'id': 'm',
      'conversationId': 'c',
      'role': 'assistant',
      'createdAt': '2026-10-26T09:30:00Z',
      'status': 'complete',
      'rev': 1,
      'blocks': [
        block('markdown', id: 'good').json,
        {
          'id': 'bad',
          'type': 'metric',
          'schemaVersion': 1,
          'fallbackText': '天气暂不可用',
          'data': true,
        },
        {
          'id': 'no_fallback',
          'type': 'confirmation',
          'schemaVersion': 1,
          'fallbackText': false,
          'data': {'label': true},
        },
        {
          'type': false,
          'fallbackText': '无效块',
          'data': <String, Object?>{},
        },
      ],
    });
    store.apply(SyncMessage(message));
    await tester.pumpWidget(app(MessageView(
        message: store.snapshot.messages['m']!,
        registry: registry,
        processState: ProcessState())));
    expect(tester.takeException(), isNull);
    expect(find.byType(FallbackNote), findsNWidgets(3));
    expect(find.text('天气暂不可用'), findsOneWidget);
    expect(find.text('此内容无法显示'), findsOneWidget);
    expect(find.byType(MarkdownBlockView), findsOneWidget);
    store.apply(const ActionPatch('m', 'bad', 2, {
      'data': {'value': false},
    }));
    await tester.pumpWidget(app(MessageView(
        message: store.snapshot.messages['m']!,
        registry: registry,
        processState: ProcessState())));
    expect(tester.takeException(), isNull);
    expect(find.byType(FallbackNote), findsNWidgets(3));
    expect(find.byType(MarkdownBlockView), findsOneWidget);
    await tester.pumpWidget(app(const SizedBox()));
    await store.dispose();
  });
  testWidgets('body_text_has_no_selection_control', (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      await tester.pumpWidget(app(Column(children: [
        const MarkdownBlockView(text: '天气晴朗'),
        FallbackNote(block: block('x-test.unknown')),
      ])));
      expect(find.byType(SelectableText), findsNothing);
      expect(find.byType(TextField), findsNothing);
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    } finally {
      semantics.dispose();
    }
  });
  testWidgets('default_strings_support_english_and_injection', (tester) async {
    await tester.pumpWidget(app(const ChatWeaveLocalizations(
        locale: 'en',
        child:
            Column(children: [BlockSkeleton(type: 'metric'), Text('天气晴朗')]))));
    expect(find.text('Generating…'), findsOneWidget);
    expect(find.text('天气晴朗'), findsOneWidget);
    await tester.pumpWidget(app(ChatWeaveLocalizations(
        locale: 'en',
        resolve: (key, fallback) =>
            key == '正在生成…' ? 'Loading weather' : fallback,
        child: const BlockSkeleton(type: 'metric'))));
    expect(find.text('Loading weather'), findsOneWidget);
  });
  test('builtin_requires_override', () {
    expect(
        () => BlockRegistry.withDefaults().register(
            'metric', BlockRegistration(build: (_, __) => const Text('bad'))),
        throwsArgumentError);
  });
  test('markdown_safe_subset', () {
    final result =
        safeMarkdown('<script>x</script> ![天气](https://example.com/a.png) '
            '[bad](javascript:alert)\n- [x] task\n[^footnote]');
    expect(result, isNot(contains('<script>')));
    expect(result, isNot(contains('![')));
    expect(result, isNot(contains('](javascript:')));
    expect(result, contains(r'\[x\]'));
    expect(safeMarkdown('`<script> ![x](file:a)`'),
        contains('`<script> ![x](file:a)`'));
    expect(allowedLink('data:text/html,x'), isFalse);
    expect(allowedLink('file:/secret', (_) => true), isFalse);
  });
  test('markdown_parser_removes_reference_images_and_unsafe_reference_links',
      () {
    final nodes = parseSafeMarkdown('![天气][image] [点击][link]\n\n'
        '[image]: https://example.com/pixel.png\n[link]: javascript:alert');
    final elements = <md.Element>[];
    void visit(md.Node node) {
      if (node is md.Element) {
        elements.add(node);
        for (final child in node.children ?? <md.Node>[]) {
          visit(child);
        }
      }
    }

    for (final node in nodes) {
      visit(node);
    }
    expect(elements.where((e) => e.tag == 'img'), isEmpty);
    expect(
        elements.where(
            (e) => e.tag == 'a' && !allowedLink(e.attributes['href'] ?? '')),
        isEmpty);
  });
  testWidgets('markdown_single_newline_is_break', (tester) async {
    await tester.pumpWidget(app(const MarkdownBlockView(text: '第一行\n第二行')));
    final text = tester
        .widgetList<RichText>(find.byType(RichText))
        .map((w) => w.text.toPlainText())
        .join();
    expect(text, contains('第一行\n第二行'));
  });
  test('markdown_delta_reparses_tail_only', () {
    final document = IncrementalDocument()..update('稳定段落\n\n活动');
    final sealed = document.stable.first;
    final stableCount = document.stableParseCount;
    for (var i = 0; i < 100; i++) {
      document.update('稳定段落\n\n活动${'字' * (i + 1)}');
    }
    expect(document.stableParseCount, stableCount);
    expect(identical(document.stable.first, sealed), isTrue);
    expect(document.tailParseCount, 101);
  });
  for (final phase in [
    'unknown',
    'version',
    'parse',
    'build',
    'layout',
    'paint'
  ]) {
    testWidgets('fallback_isolates_$phase', (tester) async {
      var reports = 0;
      final registry = BlockRegistry.markdownOnly(onBlockRenderError: (_, __) {
        reports++;
      });
      final b = phase == 'version'
          ? Block.fromJson({...block('x-test.bad').json, 'schemaVersion': 2})
          : block('x-test.bad');
      if (phase != 'unknown') {
        registry.register(
            'x-test.bad',
            BlockRegistration(parse: (_) {
              if (phase == 'parse') throw StateError('parse');
            }, build: (_, __) {
              if (phase == 'build') throw StateError('build');
              return _Throws(phase);
            }));
      }
      await tester.pumpWidget(app(Column(children: [
        registry.render(b),
        registry.render(block('markdown', id: 'sibling'))
      ])));
      await tester.pump();
      await tester.pump();
      expect(find.text('降级文字'), findsOneWidget);
      expect(
          find.byWidgetPredicate(
              (w) => w is RichText && w.text.toPlainText() == '正文'),
          findsOneWidget);
      expect(reports, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(app(Column(children: [
        registry.render(b),
        registry.render(block('markdown', id: 'sibling'))
      ])));
      await tester.pump();
      expect(reports, 1);
    });
  }
  testWidgets('scoped_element_cannot_intercept_independent_descendant_rebuild',
      (tester) async {
    final trigger = ValueNotifier(false);
    var scopedErrors = 0;
    final original = ErrorWidget.builder;
    await tester.pumpWidget(app(SizedBox(
        height: 100,
        child: _ScopedBuildProbe(
            onError: () {
              scopedErrors++;
            },
            child: ValueListenableBuilder<bool>(
                valueListenable: trigger,
                builder: (_, fail, __) {
                  if (fail) throw StateError('independent descendant rebuild');
                  return const Text('initial child');
                })))));
    expect(ErrorWidget.builder, same(original));
    trigger.value = true;
    await tester.pump();
    expect(tester.takeException(), isA<StateError>());
    expect(scopedErrors, 0);
    expect(find.byType(ErrorWidget), findsOneWidget);
    expect(ErrorWidget.builder, same(original));
    await tester.pumpWidget(app(const SizedBox()));
    trigger.dispose();
  });
  testWidgets('descendant_build_error_current_limitation', (tester) async {
    final registry = BlockRegistry.markdownOnly();
    registry.register('x-test.descendant',
        BlockRegistration(build: (_, __) => const _BuildThrows()));
    await tester.pumpWidget(app(Column(children: [
      SizedBox(height: 100, child: registry.render(block('x-test.descendant'))),
      const Text('兄弟块保留'),
    ])));
    expect(tester.takeException(), isA<StateError>());
    expect(find.text('兄弟块保留'), findsOneWidget);
    // The framework replaces the descendant with ErrorWidget; this is a
    // documented limitation, not evidence that per-block fallback succeeded.
    expect(find.text('降级文字'), findsNothing);
    expect(find.byType(ErrorWidget), findsOneWidget);
  });
  test('cancelled_with_reason_does_not_invent_missing_answer', () {
    final b = Block.fromJson({
      'id': 'b',
      'type': 'confirmation',
      'schemaVersion': 1,
      'fallbackText': '删除待办？',
      'data': {
        'title': '删除待办？',
        'severity': 'normal',
        'action': {'type': 'confirmation.respond', 'target': 'todo.delete'},
        'state': {
          'status': 'cancelled',
          'reason': {'code': 'stopped', 'text': '生成已停止，但操作已执行'}
        }
      }
    });
    expect(interactionSummary(b), contains('操作已执行'));
    expect(interactionSummary(b), isNot(contains('没有等到回答')));
  });
  test('stop_wins_without_explanation_uses_default', () {
    final b = Block.fromJson({
      'id': 'b',
      'type': 'confirmation',
      'schemaVersion': 1,
      'fallbackText': '删除待办？',
      'data': {
        'title': '删除待办？',
        'severity': 'normal',
        'action': {'type': 'confirmation.respond', 'target': 'todo.delete'},
        'state': {
          'status': 'cancelled',
          'reason': {'code': 'stopped'}
        }
      }
    });
    expect(interactionSummary(b), '已停止，没有等到回答');
  });
  test('answer_wins_then_stop_keeps_resolved_answer', () {
    final b = Block.fromJson({
      'id': 'b',
      'type': 'confirmation',
      'schemaVersion': 1,
      'fallbackText': '删除待办？',
      'data': {
        'title': '删除待办？',
        'severity': 'normal',
        'action': {'type': 'confirmation.respond', 'target': 'todo.delete'},
        'state': {
          'status': 'resolved',
          'outcome': 'confirm',
          'resolvedAt': '2026-10-26T09:31:00Z',
        }
      }
    });
    expect(interactionSummary(b), '你已确认');
  });
  test('neutral_themes_have_accessible_contrast', () {
    for (final theme in [
      ChatWeaveThemeData.neutralLight(),
      ChatWeaveThemeData.neutralDark()
    ]) {
      expect(contrastRatio(theme.onSurface, theme.surface),
          greaterThanOrEqualTo(4.5));
      expect(
          contrastRatio(theme.muted, theme.surface), greaterThanOrEqualTo(4.5));
      expect(contrastRatio(theme.accent, theme.surface),
          greaterThanOrEqualTo(4.5));
    }
  });
}

class _Throws extends LeafRenderObjectWidget {
  const _Throws(this.phase);
  final String phase;
  @override
  rendering.RenderObject createRenderObject(BuildContext context) =>
      _ThrowBox(phase);
}

class _ThrowBox extends rendering.RenderBox {
  _ThrowBox(this.phase);
  final String phase;
  @override
  void performLayout() {
    if (phase == 'layout') throw StateError('layout');
    size = constraints.constrain(const Size(100, 50));
  }

  @override
  void paint(rendering.PaintingContext context, Offset offset) {
    if (phase == 'paint') throw StateError('paint');
  }
}

class _BuildThrows extends StatelessWidget {
  const _BuildThrows();
  @override
  Widget build(BuildContext context) => throw StateError('descendant build');
}

/// Technical probe: this scope covers mounting, but a dirty descendant is rebuilt
/// directly by BuildOwner and never enters its ancestor's performRebuild.
class _ScopedBuildProbe extends StatelessWidget {
  const _ScopedBuildProbe({required this.child, required this.onError});
  final Widget child;
  final VoidCallback onError;
  @override
  Widget build(BuildContext context) => child;
  @override
  StatelessElement createElement() => _ScopedProbeElement(this);
}

class _ScopedProbeElement extends StatelessElement {
  _ScopedProbeElement(_ScopedBuildProbe super.widget);
  @override
  void performRebuild() {
    final previous = ErrorWidget.builder;
    ErrorWidget.builder = (details) {
      (widget as _ScopedBuildProbe).onError();
      return const SizedBox.shrink();
    };
    try {
      super.performRebuild();
    } finally {
      ErrorWidget.builder = previous;
    }
  }
}
