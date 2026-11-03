import 'dart:convert';
import 'dart:io';
import 'package:chatweave_flutter/chatweave_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

List<StreamEvent> events() => File(
      '../../../fixtures/conformance/streams/02-weather-todo-mixed.events.jsonl',
    )
        .readAsLinesSync()
        .map((s) => StreamEvent.fromJson(object(jsonDecode(s))))
        .toList();

void main() {
  testWidgets(
    'long_press_selects_markdown_but_not_choice_text',
    (tester) async {
      String? clipboard;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard =
              (call.arguments as Map<Object?, Object?>)['text'] as String?;
        }
        return null;
      });
      final choice = Block.fromJson({
        'id': 'choice',
        'type': 'choice',
        'schemaVersion': 1,
        'fallbackText': 'Choose a city',
        'data': {
          'prompt': 'Choose a city',
          'options': [
            {'id': 'one', 'label': 'Choice button'},
            {'id': 'two', 'label': 'Other button'},
          ],
          'action': {'type': 'choice.select', 'target': 'city.select'},
          'state': {'status': 'open'},
        },
      });
      final selectable = Message.fromJson({
        'id': 'selection',
        'conversationId': 'c',
        'role': 'assistant',
        'createdAt': '2026-10-26T09:30:00Z',
        'status': 'complete',
        'rev': 1,
        'fallbackText': 'selectable word',
        'blocks': [
          {
            'id': 'body',
            'type': 'markdown',
            'schemaVersion': 1,
            'fallbackText': 'selectable word',
            'data': {'text': 'selectable word'},
          },
          choice.json,
        ],
      });
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MessageView(
            message: selectable,
            registry: BlockRegistry.withDefaults(),
            processState: ProcessState(),
          ),
        ),
      ));

      await tester.longPress(find.text('selectable word'));
      await tester.pump();
      final area = tester.state<SelectionAreaState>(find.byType(SelectionArea));
      final copy = area.selectableRegion.contextMenuButtonItems.singleWhere(
        (item) => item.type == ContextMenuButtonType.copy,
      );
      copy.onPressed!();
      await tester.pump();
      expect(clipboard, contains('selectable'));

      await tester.pumpWidget(const SizedBox());
      final choiceOnly = Message.fromJson({
        ...selectable.json,
        'id': 'choice-only',
        'blocks': [choice.json],
      });
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MessageView(
            message: choiceOnly,
            registry: BlockRegistry.withDefaults(),
            processState: ProcessState(),
          ),
        ),
      ));
      clipboard = null;
      await tester.longPress(find.text('Choice button'));
      await tester.pump();
      final choiceArea =
          tester.state<SelectionAreaState>(find.byType(SelectionArea));
      expect(
        choiceArea.selectableRegion.contextMenuButtonItems
            .where((item) => item.type == ContextMenuButtonType.copy),
        isEmpty,
      );
      expect(clipboard, isNull);
    },
  );

  testWidgets('default_copy_uses_whole_message_plain_text', (tester) async {
    String? clipboard;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboard =
            (call.arguments as Map<Object?, Object?>)['text'] as String?;
      }
      return null;
    });
    final message = Message.fromJson({
      'id': 'copy',
      'conversationId': 'c',
      'role': 'assistant',
      'createdAt': '2026-10-26T09:30:00Z',
      'status': 'complete',
      'rev': 1,
      'fallbackText': 'fallback',
      'blocks': [
        {
          'id': 'body',
          'type': 'markdown',
          'schemaVersion': 1,
          'fallbackText': 'ignored',
          'data': {'text': '- **first**\n- second'},
        },
        {
          'id': 'extra',
          'type': 'x-test.extra',
          'schemaVersion': 1,
          'fallbackText': 'component fallback',
          'data': <String, Object?>{},
        },
      ],
    });
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MessageView(
          message: message,
          registry: BlockRegistry.withDefaults(),
          processState: ProcessState(),
        ),
      ),
    ));
    await tester.tap(find.text('复制'));
    await tester.pump();
    expect(clipboard, '\u2022 first\n\u2022 second\n\ncomponent fallback');
  });

  testWidgets('component_fill_preserves_text_top_left', (tester) async {
    final store = BlockStore();
    final stream = events();
    final data = stream.indexWhere((e) => e.type == 'block.data');
    for (final e in stream.take(data)) {
      store.apply(ApplyStream(e));
    }
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: MessageView(
                message: store.snapshot.messages.values.single,
                registry: BlockRegistry.withDefaults(),
                processState: ProcessState()))));
    final before = tester.getTopLeft(find.byKey(const ValueKey('b1')));
    store.apply(ApplyStream(stream[data]));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: MessageView(
                message: store.snapshot.messages.values.single,
                registry: BlockRegistry.withDefaults(),
                processState: ProcessState()))));
    expect(tester.getTopLeft(find.byKey(const ValueKey('b1'))), before);
    expect(tester.takeException(), isNull);
  });
  testWidgets('unfinished_message_hides_actions', (tester) async {
    final store = BlockStore();
    store.apply(ApplyStream(events().first));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: MessageView(
                message: store.snapshot.messages.values.single,
                registry: BlockRegistry.withDefaults(),
                processState: ProcessState()))));
    expect(find.text('复制'), findsNothing);
  });
  testWidgets('debug_overlay_does_not_change_events_or_requests',
      (tester) async {
    final store = BlockStore();
    for (final e in events()) {
      store.apply(ApplyStream(e));
    }
    final before = jsonEncode(store.inspect());
    final snapshot = store.snapshot;
    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: ChatWeaveDebugOverlay(store: store))));
    await tester.pump();
    expect(jsonEncode(store.inspect()), before);
    expect(identical(store.snapshot, snapshot), isTrue);
    await tester.pumpWidget(const SizedBox());
    expect(jsonEncode(store.inspect()), before);
  });
  testWidgets('running_steps_suppress_activity', (tester) async {
    final store = BlockStore();
    for (final e in events()) {
      store.apply(ApplyStream(e));
    }
    final message = Message.fromJson({
      ...store.snapshot.messages.values.single.json,
      'status': 'streaming',
      'rev': 0,
      'steps': [
        {'id': 's', 'label': '读取天气', 'state': 'running'}
      ]
    });
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: MessageView(
                    message: message,
                    registry: BlockRegistry.withDefaults(),
                    processState: ProcessState(),
                    activity: const {'label': '临时提示'})))));
    expect(find.text('临时提示'), findsNothing);
  });
}
