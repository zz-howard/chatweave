import 'dart:async' as async;
import 'package:chatweave_core/testing.dart';
import 'package:chatweave_flutter/chatweave_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Finder bodyText(String value) => find
    .byWidgetPredicate((w) => w is RichText && w.text.toPlainText() == value);

Widget app(Widget child) => MaterialApp(home: Scaffold(body: child));
Message message(String id,
        {List<Json> steps = const [],
        String status = 'streaming',
        String text = '天气晴朗',
        String blockStatus = 'complete'}) =>
    Message.fromJson({
      'id': id,
      'conversationId': 'c',
      'role': 'assistant',
      'createdAt': '2026-10-26T09:30:00Z',
      'protocolVersion': '0.1',
      'status': status,
      'rev': 0,
      'steps': steps,
      'fallbackText': text,
      'blocks': [
        {
          'id': 'body_$id',
          'type': 'markdown',
          'schemaVersion': 1,
          'status': blockStatus,
          'fallbackText': text,
          'data': {'text': text}
        }
      ],
    });
Block card({bool form = false}) => Block.fromJson({
      'id': 'card',
      'type': form ? 'form_intent' : 'choice',
      'schemaVersion': 1,
      'data': {
        'title': '待办',
        'prompt': '选择城市',
        'options': [
          {'id': 'city', 'label': '北京'},
          {'id': 'other_city', 'label': '上海'}
        ],
        'action': {
          'type': form ? 'form.submit' : 'choice.select',
          'target': 'todo'
        },
        if (form)
          'fields': [
            {'key': 'first', 'type': 'text', 'label': '第一项'},
            {'key': 'second', 'type': 'text', 'label': '第二项'},
          ],
      },
    });

void main() {
  testWidgets('recycled_widget_keeps_submitting_and_idempotency_key',
      (tester) async {
    final b = card();
    final store = BlockStore()
      ..apply(SyncMessage(Message.fromJson({
        ...message('m').json,
        'blocks': [b.json],
      })));
    final persistence = MemoryStore();
    final pending = async.Completer<ActionSubmission>();
    var ids = 0;
    final transport = ScriptedTransport(connections: [], actions: [
      (_) => pending.future,
      (_) async => throw StateError('offline'),
    ]);
    final interactions = InteractionController(
        maxAutomaticRetries: 0,
        store: store,
        persistence: persistence,
        nextId: () => 'intent_${++ids}',
        transport: transport);
    Widget view(String key) => app(BuiltinBlockView(
        key: ValueKey(key),
        block: b,
        messageId: 'm',
        interactions: interactions));
    await tester.pumpWidget(view('before'));
    await tester.tap(find.text('北京'));
    await tester.pump();
    final request = transport.requests.single;
    expect(find.text('提交中…'), findsOneWidget);
    await tester.pumpWidget(app(const SizedBox()));
    await tester.pumpWidget(view('after'));
    expect(find.text('提交中…'), findsOneWidget);
    await tester.tap(find.text('北京'));
    await tester.pump();
    expect(transport.requests.length, 1);
    expect((await persistence.loadClientState('m')).intents['card']!.json,
        request.json);
    pending.completeError(StateError('lost response'));
    await tester.pump();
    await interactions.retry('m', 'card');
    expect(transport.requests.last.json, request.json);
    expect(ids, 1);
    await tester.pumpWidget(app(const SizedBox()));
    await interactions.dispose();
    await persistence.dispose();
    await store.dispose();
  });

  testWidgets('first_field_error_receives_focus_in_field_order',
      (tester) async {
    final b = card(form: true);
    final store = BlockStore()
      ..apply(SyncMessage(Message.fromJson({
        ...message('m').json,
        'blocks': [b.json],
      })));
    final persistence = MemoryStore();
    final interactions = InteractionController(
        maxAutomaticRetries: 0,
        store: store,
        persistence: persistence,
        nextId: () => 'intent',
        transport: ScriptedTransport(connections: [], actions: [
          (_) async => ActionSubmission.result(ActionResult.fromJson({
                'status': 'rejected',
                'error': {
                  'code': 'validation_failed',
                  'fieldErrors': {'second': '第二项错误', 'first': '第一项错误'}
                },
              })),
        ]));
    await tester.pumpWidget(app(BuiltinBlockView(
        block: b, messageId: 'm', interactions: interactions)));
    await tester.tap(find.text('提交'));
    await tester.pump();
    await tester.pump();
    final fields =
        tester.widgetList<TextField>(find.byType(TextField)).toList();
    expect(fields.first.focusNode!.hasFocus, isTrue);
    expect(fields.last.focusNode!.hasFocus, isFalse);
    expect(find.text('第一项错误'), findsOneWidget);
    await tester.pumpWidget(app(const SizedBox()));
    await interactions.dispose();
    await persistence.dispose();
    await store.dispose();
  });

  testWidgets('announcements_only_at_block_end_pause_and_end', (tester) async {
    final labels = <String>[];
    Future<void> show(Message m) async {
      await tester.pumpWidget(app(MessageAnnouncements(message: m)));
      final semantics = tester.widget<Semantics>(find.descendant(
          of: find.byType(MessageAnnouncements),
          matching: find.byType(Semantics)));
      labels.add(semantics.properties.label ?? '');
    }

    await show(message('m', blockStatus: 'pending', text: '天'));
    await show(message('m', blockStatus: 'pending', text: '天气'));
    await show(message('m', blockStatus: 'pending', text: '天气晴', steps: [
      {'id': 's', 'label': '查天气', 'state': 'succeeded'},
    ]));
    expect(labels, ['', '', '']);
    await show(message('m', text: '块结束'));
    expect(labels.last, '块结束');
    await show(message('m', status: 'paused', text: '删除待办？'));
    expect(labels.last, contains('删除待办？'));
    final paused = labels.last;
    await show(message('m', text: '继续'));
    expect(labels.last, paused);
    await show(message('m', status: 'complete', text: '消息完成'));
    expect(labels.last, contains('消息完成'));
  });

  testWidgets('list_coalesces_updates_at_most_once_per_frame', (tester) async {
    final store = BlockStore()..apply(SyncMessage(message('m')));
    var builds = 0;
    await tester.pumpWidget(app(ChatWeaveList(
        store: store,
        registry: BlockRegistry.withDefaults(),
        conversationId: 'c',
        messageFrameBuilder: (_, __, child) {
          builds++;
          return child;
        })));
    builds = 0;
    for (var i = 0; i < 100; i++) {
      store.apply(SyncMessage(message('m', text: '天气 $i')));
    }
    expect(builds, 0);
    await tester.pump();
    expect(builds, lessThanOrEqualTo(1));
    await tester.pump();
    expect(builds, 1);
    expect(bodyText('天气 99'), findsOneWidget);
    await tester.pumpWidget(app(const SizedBox()));
    await store.dispose();
  });

  testWidgets('process_growth_and_manual_collapse_preserve_scroll_anchor',
      (tester) async {
    final store = BlockStore();
    Message target(int count) => message('target', text: '锚点天气', steps: [
          for (var i = 0; i < count; i++)
            {'id': 's$i', 'label': '读取天气 $i', 'state': 'succeeded'},
        ]);
    for (var i = 0; i < 20; i++) {
      if (i == 10) store.apply(SyncMessage(target(1)));
      store.apply(SyncMessage(message('m$i', text: '天气 $i\n' * 3)));
    }
    await tester.pumpWidget(app(ChatWeaveList(
        store: store,
        registry: BlockRegistry.withDefaults(),
        conversationId: 'c')));
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 200));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(bodyText('锚点天气'), 150,
        scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    final before = tester.getTopLeft(bodyText('锚点天气'));
    store.apply(SyncMessage(target(3)));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(tester.getTopLeft(bodyText('锚点天气')).dy, closeTo(before.dy, 1));
    final strip =
        find.ancestor(of: bodyText('锚点天气'), matching: find.byType(MessageView));
    final toggle =
        find.descendant(of: strip, matching: find.byType(TextButton)).first;
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    // A manual toggle keeps the control under the user's finger in place;
    // the content below it may move (only automatic changes keep the body).
    final collapseBefore = tester.getTopLeft(toggle);
    await tester.tap(toggle);
    await tester.pump();
    await tester.pump();
    final toggleAfter =
        find.descendant(of: strip, matching: find.byType(TextButton)).first;
    expect(tester.getTopLeft(toggleAfter).dy, closeTo(collapseBefore.dy, 1));
    await tester.pumpWidget(app(const SizedBox()));
    await store.dispose();
  });

  testWidgets('real_scroll_up_disables_follow_and_counts_new_messages',
      (tester) async {
    final store = BlockStore();
    for (var i = 0; i < 30; i++) {
      store.apply(SyncMessage(message('m$i', text: '天气 $i\n' * 5)));
    }
    await tester.pumpWidget(app(ChatWeaveList(
        store: store,
        registry: BlockRegistry.withDefaults(),
        conversationId: 'c')));
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 400));
    await tester.pumpAndSettle();
    final scrollable =
        tester.state<ScrollableState>(find.byType(Scrollable).first);
    final before = scrollable.position.pixels;
    expect(before, greaterThan(24));
    store.apply(SyncMessage(message('new', text: '新的天气')));
    await tester.pump();
    await tester.pump();
    expect(scrollable.position.pixels, greaterThan(24));
    expect(find.text('有 1 条新内容'), findsOneWidget);
    store.apply(SyncMessage(message('new', text: '新的天气又增加')));
    await tester.pump();
    await tester.pump();
    expect(find.text('有 1 条新内容'), findsOneWidget);
    await tester.tap(find.text('有 1 条新内容'));
    await tester.pumpAndSettle();
    expect(scrollable.position.pixels, 0);
    expect(find.text('有 1 条新内容'), findsNothing);
    await tester.pumpWidget(app(const SizedBox()));
    await store.dispose();
  });
}
