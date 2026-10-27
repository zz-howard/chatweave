import 'dart:convert';
import 'dart:io';
import 'package:chatweave_flutter/chatweave_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

List<StreamEvent> events() => File(
      '../../../fixtures/conformance/streams/02-weather-todo-mixed.events.jsonl',
    )
        .readAsLinesSync()
        .map((s) => StreamEvent.fromJson(object(jsonDecode(s))))
        .toList();

void main() {
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
