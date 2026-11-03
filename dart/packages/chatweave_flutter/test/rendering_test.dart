import 'package:chatweave_flutter/chatweave_flutter.dart';
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
  group('markdown_blockquote', () {
    List<md.Element> quotes(List<md.Node> nodes) {
      final found = <md.Element>[];
      void walk(md.Node node) {
        if (node is! md.Element) return;
        if (node.tag == 'blockquote') found.add(node);
        node.children?.forEach(walk);
      }

      nodes.forEach(walk);
      return found;
    }

    test('leading marker becomes a blockquote', () {
      final nodes = parseSafeMarkdown('> quote\n\nafter');
      expect(quotes(nodes), hasLength(1));
      expect(quotes(nodes).single.textContent.trim(), 'quote');
      expect(quotes(parseSafeMarkdown('   >quote')), hasLength(1));
      expect(quotes(parseSafeMarkdown('    > code')), isEmpty);
    });
    test('nested markers nest', () {
      final nodes = parseSafeMarkdown('> a\n> > b');
      expect(quotes(nodes), hasLength(2));
    });
    test('mid-line and angle-bracket text stays plain', () {
      for (final text in ['a > b', '<\u91d1\u989d>', '1 < 2 > 0', '<b>x</b>']) {
        final nodes = parseSafeMarkdown(text);
        expect(quotes(nodes), isEmpty, reason: text);
        expect(nodes.map((n) => n.textContent).join(), text, reason: text);
      }
      final inQuote = safeMarkdown('> pay <amount> a > b');
      expect(inQuote, startsWith('> pay &lt;amount&gt; a &gt; b'));
      expect(safeMarkdown('<script>'), contains('&lt;script&gt;'));
    });
    test('raw html after the marker is still escaped', () {
      final result = safeMarkdown('> <script>x</script>');
      expect(result, startsWith('> &lt;script&gt;'));
      expect(result, isNot(contains('<script>')));
    });
    test('code keeps > literally', () {
      expect(safeMarkdown('`> x`'), contains('`> x`'));
      expect(safeMarkdown('```\n> x\n<y>\n```'), contains('> x\n<y>'));
      final fenced = parseSafeMarkdown('```\n> x\n```');
      expect(quotes(fenced), isEmpty);
      expect(fenced.single.textContent, contains('> x'));
      final quotedFence = safeMarkdown('> ```\n> <y>\n> ```\n<z>');
      expect(quotedFence, contains('> <y>'));
      expect(quotedFence, contains('&lt;z&gt;'));
    });
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
    expect(document.tailParseCount, lessThan(10));
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
      expect(contrastRatio(theme.answerForeground, theme.answerBackground),
          greaterThanOrEqualTo(4.5));
    }
  });
  test('answer_capsule_tokens_default_by_brightness_and_can_be_mapped', () {
    final light = ChatWeaveThemeData.neutralLight();
    final dark = ChatWeaveThemeData.neutralDark();
    expect(light.answerBackground, const Color(0xFFEDEFF2));
    expect(light.answerForeground, const Color(0xFF17191C));
    expect(dark.answerBackground, const Color(0xFF2A3038));
    expect(dark.answerForeground, const Color(0xFFF2F3F5));
    expect(light.answer.fontWeight, isNull);
    const mapped = ChatWeaveThemeData(
      brightness: Brightness.light,
      surface: Color(0xFFFFFFFF),
      onSurface: Color(0xFF000000),
      muted: Color(0xFF444444),
      outline: Color(0xFF666666),
      accent: Color(0xFF0000AA),
      onAccent: Color(0xFFFFFFFF),
      warning: Color(0xFF664400),
      critical: Color(0xFF990000),
      chartPalette: [Color(0xFF0000AA)],
      answerBackground: Color(0xFFFFF2B3),
      answerForeground: Color(0xFF3D2E00),
    );
    expect(mapped.answerBackground, const Color(0xFFFFF2B3));
    expect(mapped.answerForeground, const Color(0xFF3D2E00));
  });
  Block answeredChoice(Map<String, Object?> state) {
    const options = [
      {'id': 'bj', 'label': '北京'},
      {'id': 'sh', 'label': '上海'},
    ];
    return Block.fromJson({
      'id': 'b1',
      'type': 'choice',
      'schemaVersion': 1,
      'fallbackText': '请选择北京或上海',
      'data': {
        'prompt': '查哪个城市？',
        'options': options,
        'selection': 'single',
        'action': {'type': 'choice.select', 'target': 'weather.select'},
        'state': state,
      },
    });
  }

  testWidgets('form_fields_are_separated_by_field_gap', (tester) async {
    final b = Block.fromJson({
      'id': 'f1',
      'type': 'form_intent',
      'schemaVersion': 1,
      'fallbackText': '新建待办',
      'data': {
        'title': '新建待办',
        'fields': [
          {'key': 'title', 'label': '事项', 'type': 'text'},
          {'key': 'note', 'label': '备注', 'type': 'text'},
        ],
        'action': {'type': 'form.submit', 'target': 'todo.create'},
        'state': {'status': 'open'},
      },
    });
    validateBlock(b.json);
    for (final gap in [12.0, 20.0]) {
      final base = ChatWeaveThemeData.neutralLight();
      await tester.pumpWidget(app(ChatWeaveTheme(
        data: ChatWeaveThemeData(
          brightness: base.brightness,
          surface: base.surface,
          onSurface: base.onSurface,
          muted: base.muted,
          outline: base.outline,
          accent: base.accent,
          onAccent: base.onAccent,
          warning: base.warning,
          critical: base.critical,
          chartPalette: base.chartPalette,
          fieldGap: gap,
        ),
        child: BuiltinBlockView(key: ValueKey(gap), block: b),
      )));
      final fields = find.byType(TextFormField);
      expect(fields, findsNWidgets(2));
      // Without a transport the card is read-only, so the '仅可查看' line
      // is the text right above the first field.
      final above = tester.getRect(find.text('仅可查看'));
      final first = tester.getRect(fields.at(0));
      final second = tester.getRect(fields.at(1));
      final submit = tester.getRect(find.byType(ChatWeaveTextButton));
      expect(first.top - above.bottom, gap, reason: 'text → field');
      expect(second.top - first.bottom, gap, reason: 'field → field');
      expect(submit.top - second.bottom, gap, reason: 'field → submit');
    }
    expect(ChatWeaveThemeData.neutralLight().fieldGap, 12);
  });
  testWidgets('interaction_padding_is_a_theme_token', (tester) async {
    final b = Block.fromJson({
      'id': 'f2',
      'type': 'form_intent',
      'schemaVersion': 1,
      'fallbackText': '新建待办',
      'data': {
        'title': '新建待办',
        'fields': [
          {'key': 'title', 'label': '事项', 'type': 'text'},
        ],
        'action': {'type': 'form.submit', 'target': 'todo.create'},
        'state': {'status': 'open'},
      },
    });
    final base = ChatWeaveThemeData.neutralLight();
    expect(base.interactionPadding, const EdgeInsets.all(12));
    for (final inset in [12.0, 0.0]) {
      await tester.pumpWidget(app(ChatWeaveTheme(
        data: ChatWeaveThemeData(
          brightness: base.brightness,
          surface: base.surface,
          onSurface: base.onSurface,
          muted: base.muted,
          outline: base.outline,
          accent: base.accent,
          onAccent: base.onAccent,
          warning: base.warning,
          critical: base.critical,
          chartPalette: base.chartPalette,
          interactionPadding: EdgeInsets.symmetric(horizontal: inset),
        ),
        child: Align(
          alignment: Alignment.topLeft,
          child: BuiltinBlockView(key: ValueKey(inset), block: b),
        ),
      )));
      expect(tester.getRect(find.text('新建待办')).left, inset);
      expect(tester.getRect(find.text('新建待办')).top, 0);
    }
  });
  testWidgets('answered_choice_shows_only_the_picked_option', (tester) async {
    final semantics = tester.ensureSemantics();
    final b = answeredChoice({
      'status': 'resolved',
      'resolvedAt': '2026-10-26T09:31:00Z',
      'selected': ['bj'],
    });
    validateBlock(b.json);
    await tester.pumpWidget(app(BuiltinBlockView(block: b)));
    expect(find.byType(AnswerCapsule), findsOneWidget);
    expect(find.byKey(const ValueKey('chatweave-answer-bj')), findsOneWidget);
    expect(find.text('上海'), findsNothing);
    expect(find.byType(ChatWeaveTextButton), findsNothing);
    expect(find.text('已回答：北京'), findsNothing);
    expect(find.bySemanticsLabel('已回答：北京'), findsOneWidget);
    semantics.dispose();
  });
  testWidgets('answered_choice_with_unknown_ids_keeps_summary_line',
      (tester) async {
    final b = answeredChoice({
      'status': 'resolved',
      'resolvedAt': '2026-10-26T09:31:00Z',
      'selected': ['gone'],
    });
    await tester.pumpWidget(app(BuiltinBlockView(block: b)));
    expect(find.byType(AnswerCapsule), findsNothing);
    expect(find.text(interactionSummary(b)), findsOneWidget);
    expect(find.text('北京'), findsOneWidget);
    expect(find.text('上海'), findsOneWidget);
  });
  testWidgets('free_text_answer_is_one_capsule_without_summary_line',
      (tester) async {
    final semantics = tester.ensureSemantics();
    final b = answeredChoice({
      'status': 'resolved',
      'resolvedAt': '2026-10-26T09:31:00Z',
      'freeText': '先保留这条待办',
    });
    validateBlock(b.json);
    await tester.pumpWidget(app(BuiltinBlockView(block: b)));
    expect(find.byType(AnswerCapsule), findsOneWidget);
    expect(find.text('先保留这条待办'), findsOneWidget);
    expect(find.text('你的回答：先保留这条待办'), findsNothing);
    expect(find.text('北京'), findsNothing);
    expect(find.text('上海'), findsNothing);
    expect(find.bySemanticsLabel('你的回答：先保留这条待办'), findsOneWidget);
    semantics.dispose();
  });
  testWidgets('unanswered_endings_keep_summary_and_options', (tester) async {
    for (final state in [
      {'status': 'expired'},
      {
        'status': 'cancelled',
        'reason': {'code': 'stopped'},
      },
    ]) {
      final b = answeredChoice(state);
      validateBlock(b.json);
      await tester.pumpWidget(app(BuiltinBlockView(block: b)));
      expect(find.byType(AnswerCapsule), findsNothing);
      expect(find.text(interactionSummary(b)), findsOneWidget);
      expect(find.text('北京'), findsOneWidget);
      expect(find.text('上海'), findsOneWidget);
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
