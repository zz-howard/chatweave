import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:chatweave_core/chatweave_core.dart';
import 'package:test/test.dart';

List<StreamEvent> weather() => File(
      '../../../fixtures/conformance/streams/02-weather-todo-mixed.events.jsonl',
    )
        .readAsLinesSync()
        .map((s) => StreamEvent.fromJson(object(jsonDecode(s))))
        .toList();

void main() {
  test('wire_roundtrip_preserves_unknown_absent_null', () {
    final original = <String, Object?>{
      'future': [
        null,
        {'x': 3}
      ],
      'explicit': null
    };
    final model = WireModel(original);
    original['future'] = 9;
    expect(model.json, {
      'future': [
        null,
        {'x': 3}
      ],
      'explicit': null
    });
    expect(() => model.json['future'] = 9, throwsUnsupportedError);
    expect(model.json.containsKey('absent'), isFalse);
  });
  test('duplicate_event_preserves_identity_and_notification_count', () {
    final store = BlockStore();
    var notifications = 0;
    store.changes.listen((_) => notifications++);
    final event = weather().first;
    final first = store.apply(ApplyStream(event));
    expect(identical(store.apply(ApplyStream(event)), first), isTrue);
    expect(notifications, 1);
  });
  test('resume_seeded_duplicate_schedules_match_expected', () {
    final events = weather();
    final expected = fold(events).json;
    for (var seed = 0; seed < 100; seed++) {
      final random = Random(seed);
      final store = BlockStore();
      for (final event in events) {
        store.apply(ApplyStream(event));
        for (var n = random.nextInt(4); n > 0; n--) {
          store.apply(ApplyStream(event));
        }
      }
      expect(store.snapshot.messages[events.first.messageId]!.json, expected,
          reason: 'seed=$seed');
    }
  });
  test('invalid_apply_is_atomic', () {
    final state = FoldState()..apply(weather().first);
    final before = state.message.json;
    expect(() => state.apply(weather()[2]), throwsA(isA<ProtocolError>()));
    expect(state.message.json, before);
    expect(state.lastSeq, 1);
  });
  test('debug_export_redacts_all_content_fields', () {
    final store = BlockStore();
    for (final event in weather()) {
      store.apply(ApplyStream(event));
    }
    final before = store.snapshot;
    final export = jsonEncode(store.inspect());
    expect(export, isNot(contains('天气晴朗')));
    expect(export, isNot(contains('浇花')));
    expect(export, isNot(contains('fallbackText')));
    expect(identical(before, store.snapshot), isTrue);
  });
  for (final event in [ViewportEvent.historyPrepend, ViewportEvent.resize]) {
    test('viewport_${event.name}_keeps_anchor', () {
      final result = ViewportController.reduce(
        const ViewportState(follow: false, anchorId: 'b', anchorOffset: 12),
        event,
        const ViewportMeasurements(
            pixels: 50, anchorBefore: 12, anchorAfter: 92),
      );
      expect(result.scrollTo, 130);
      expect(result.state.anchorOffset, 12);
    });
  }
  test('stream_growth_does_not_increment_new_count', () {
    final result = ViewportController.reduce(const ViewportState(follow: false),
        ViewportEvent.streamGrowth, const ViewportMeasurements(pixels: 80));
    expect(result.state.newMessages, 0);
    expect(result.scrollTo, isNull);
  });
  test('apply_is_atomic_and_shares_unaffected_objects', () {
    final store = BlockStore();
    final events = weather();
    final data = events.indexWhere((e) => e.type == 'block.data');
    for (final event in events.take(data)) {
      store.apply(ApplyStream(event));
    }
    final previous = store.snapshot.messages.values.single.blocks.first.json;
    store.apply(ApplyStream(events[data]));
    expect(
        identical(
            previous, store.snapshot.messages.values.single.blocks.first.json),
        isTrue);
  });
  test('optimistic_user_reconciles_by_id', () {
    final store = BlockStore();
    final optimistic = Message.fromJson({
      'id': 'user',
      'role': 'user',
      'status': 'complete',
      'rev': 0,
      'blocks': [],
      'fallbackText': '查天气'
    });
    store.apply(SyncMessage(optimistic));
    store.apply(SyncMessage(Message.fromJson({...optimistic.json, 'rev': 1})));
    expect(store.snapshot.messages.length, 1);
    expect(store.snapshot.messages['user']!.rev, 1);
  });
  test('activity_is_ephemeral_and_does_not_advance_cursor', () {
    final store = BlockStore()..apply(ApplyStream(weather().first));
    final before = store.snapshot.messages.values.single.json;
    store.apply(ApplyStream(StreamEvent.fromJson({
      'protocolVersion': '0.1',
      'type': 'message.activity',
      'messageId': 'msg_weather',
      'activity': {'phase': 'working', 'label': '正在查天气'}
    })));
    expect(store.snapshot.cursors['msg_weather'], 1);
    expect(store.snapshot.messages.values.single.json, before);
    expect(store.activityFor('msg_weather')?['label'], '正在查天气');
    store.apply(ApplyStream(weather()[1]));
    expect(store.activityFor('msg_weather'), isNull);
  });
  test('limits_only_tighten_and_utf8_bytes_are_not_rune_counts', () {
    expect(
        () => const Limits(maxEvents: 5001).validateConfiguration(),
        throwsA(isA<ProtocolError>()
            .having((e) => e.code, 'code', 'invalid_limits')));
    const limits = Limits(maxMarkdownBytes: 3);
    limits.checkBlock({
      'type': 'markdown',
      'data': {'text': '晴'}
    });
    expect(
        () => limits.checkBlock({
              'type': 'markdown',
              'data': {'text': '晴天'}
            }),
        throwsA(isA<ProtocolError>()
            .having((e) => e.code, 'code', 'limit_exceeded')));
  });
}
