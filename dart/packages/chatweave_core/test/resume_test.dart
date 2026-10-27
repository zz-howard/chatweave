import 'dart:async' as async;
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:chatweave_core/chatweave_core.dart';
import 'package:chatweave_core/testing.dart';
import 'package:test/test.dart';

List<Json> streamFixture(String name) => File(
      '../../../fixtures/conformance/streams/$name.events.jsonl',
    )
        .readAsLinesSync()
        .where((line) => line.isNotEmpty)
        .map((line) => object(jsonDecode(line)))
        .toList();

StreamConnection connection(List<Json> events) => StreamConnection(
    status: 200,
    headers: const {'ChatWeave-Protocol': '0.1'},
    bytes: async.Stream.fromIterable([
      for (final event in events)
        utf8.encode(
            'id: ${event['seq']}\nevent: ${event['type']}\ndata: ${jsonEncode(event)}\n\n'),
    ]));

class Authority implements AuthoritativeRefresh {
  Authority(this.message);
  final Message? message;
  int calls = 0;
  @override
  async.Future<Message?> refresh(String messageId) async {
    calls++;
    return message;
  }
}

ClientCapabilities get caps => ClientCapabilities.fromJson({
      'protocolVersions': ['0.1'],
      'blocks': {}
    });

void main() {
  test('resume_concurrent_triggers_open_once', () async {
    final events = streamFixture('01-markdown');
    final transport =
        ScriptedTransport(connections: [(_, __) async => connection(events)]);
    final controller = ChatWeaveStreamController(
        store: BlockStore(),
        persistence: MemoryStore(),
        transport: transport,
        authority: Authority(null),
        caps: caps);
    await async.Future.wait([
      for (final trigger in ResumeTrigger.values)
        controller.subscribe('msg_weather', trigger: trigger)
    ]);
    expect(transport.opens.length, 1);
    await controller.dispose();
  });
  test('resume_seeded_schedules_match_expected', () async {
    final events = streamFixture('02-weather-todo-mixed');
    final expected = fold(events.map(StreamEvent.fromJson)).json;
    for (var seed = 0; seed < 50; seed++) {
      final random = Random(seed);
      final cut = 1 + random.nextInt(events.length - 2);
      final first = events.take(cut).toList();
      // Deliver an out-of-order event: recovery must replay the missing event.
      if (random.nextBool()) first.add(events[cut + 1]);
      final transport = ScriptedTransport(connections: [
        (_, __) async => connection(first),
        (_, cursor) async {
          expect(cursor, cut, reason: 'seed=$seed');
          return connection([events[cut - 1], ...events.skip(cut)]);
        },
      ]);
      final store = BlockStore();
      final controller = ChatWeaveStreamController(
          store: store,
          persistence: MemoryStore(),
          transport: transport,
          authority: Authority(null),
          caps: caps,
          wait: (_) async {});
      await controller.subscribe('msg_weather');
      expect(store.snapshot.messages['msg_weather']!.json, expected,
          reason: 'seed=$seed');
      expect(transport.opens.length, 2, reason: 'seed=$seed');
      await controller.dispose();
    }
  });
  test('snapshot_handoff_continues_at_next_seq', () async {
    final events = streamFixture('02-weather-todo-mixed');
    final cut = events.length ~/ 2;
    final checkpoint = fold(events.take(cut).map(StreamEvent.fromJson));
    final snapshot = <String, Object?>{
      'protocolVersion': '0.1',
      'messageId': checkpoint.id,
      'type': 'message.snapshot',
      'seq': cut,
      'message': checkpoint.json
    };
    final transport = ScriptedTransport(connections: [
      (_, __) async => connection([snapshot]),
      (_, cursor) async {
        expect(cursor, cut);
        return connection(events.skip(cut).toList());
      },
    ]);
    final store = BlockStore();
    final controller = ChatWeaveStreamController(
        store: store,
        persistence: MemoryStore(),
        transport: transport,
        authority: Authority(null),
        caps: caps,
        wait: (_) async {});
    await controller.subscribe('msg_weather');
    expect(store.snapshot.messages['msg_weather']!.json,
        fold(events.map(StreamEvent.fromJson)).json);
    await controller.dispose();
  });
  test('stop_requested_blocks_all_auto_resume_across_restart', () async {
    final persistence = MemoryStore();
    await persistence.saveClientState(
        'msg_weather', ClientState(stopRequested: true));
    final transport = ScriptedTransport(connections: []);
    final authority =
        Authority(fold(streamFixture('01-markdown').map(StreamEvent.fromJson)));
    final controller = ChatWeaveStreamController(
        store: BlockStore(),
        persistence: persistence,
        transport: transport,
        authority: authority,
        caps: caps);
    for (final trigger in ResumeTrigger.values) {
      await controller.subscribe('msg_weather', trigger: trigger);
    }
    expect(transport.opens, isEmpty);
    expect(authority.calls, 1);
    await controller.dispose();
  });
  test('paused_requires_explicit_resume_condition', () async {
    final paused =
        fold(streamFixture('24-interrupt-paused').map(StreamEvent.fromJson));
    final store = BlockStore()..apply(SyncMessage(paused));
    final transport = ScriptedTransport(connections: []);
    final controller = ChatWeaveStreamController(
        store: store,
        persistence: MemoryStore(),
        transport: transport,
        authority: Authority(null),
        caps: caps);
    for (final trigger in [
      ResumeTrigger.conversation,
      ResumeTrigger.foreground,
      ResumeTrigger.online,
      ResumeTrigger.heartbeat
    ]) {
      await controller.subscribe('msg_weather', trigger: trigger);
    }
    expect(transport.opens, isEmpty);
    await controller.dispose();
  });
  test('unknown_protocol_header_refreshes_before_decoding', () async {
    final authority = Authority(null);
    final transport = ScriptedTransport(connections: [
      (_, __) async => StreamConnection(
          status: 200,
          headers: const {'ChatWeave-Protocol': '9.0'},
          bytes: async.Stream.error(StateError('must not read body')))
    ]);
    final controller = ChatWeaveStreamController(
        store: BlockStore(),
        persistence: MemoryStore(),
        transport: transport,
        authority: authority,
        caps: caps);
    await controller.subscribe('msg_weather');
    expect(authority.calls, 1);
    await controller.dispose();
  });
  test('unknown_paused_message_loads_once_and_action_resumes_applied_seq',
      () async {
    final pausedEvents = streamFixture('24-interrupt-paused');
    final continued = streamFixture('25-interrupt-resumed');
    final transport = ScriptedTransport(connections: [
      (_, cursor) async {
        expect(cursor, isNull);
        return connection(pausedEvents);
      },
      (_, cursor) async {
        expect(cursor, pausedEvents.last['seq']);
        return connection(continued);
      },
    ]);
    final store = BlockStore();
    final controller = ChatWeaveStreamController(
        store: store,
        persistence: MemoryStore(),
        transport: transport,
        authority: Authority(null),
        caps: caps);
    await controller.subscribe('msg_weather');
    expect(store.snapshot.messages['msg_weather']!.status, 'paused');
    await controller.subscribe('msg_weather',
        trigger: ResumeTrigger.foreground);
    expect(transport.opens.length, 1);
    await controller.subscribe('msg_weather', trigger: ResumeTrigger.action);
    expect(store.snapshot.messages['msg_weather']!.json,
        fold(continued.map(StreamEvent.fromJson)).json);
    expect(transport.opens.length, 2);
    await controller.dispose();
  });
  test('active_advertised_seq_never_replaces_applied_cursor', () async {
    final pausedEvents = streamFixture('24-interrupt-paused');
    final continued = streamFixture('25-interrupt-resumed');
    final store = BlockStore();
    for (final event in pausedEvents) {
      store.apply(ApplyStream(StreamEvent.fromJson(event)));
    }
    final transport = ScriptedTransport(connections: [
      (_, cursor) async {
        expect(cursor, 6);
        return connection(continued.skip(6).toList());
      },
    ]);
    transport.active = [
      ActiveMessage.fromJson({
        'messageId': 'msg_weather',
        'status': 'streaming',
        'lastSeq': 999,
      })
    ];
    final controller = ChatWeaveStreamController(
        store: store,
        persistence: MemoryStore(),
        transport: transport,
        authority: Authority(null),
        caps: caps);
    await controller.recoverConversation('conv_weather');
    expect(store.snapshot.messages['msg_weather']!.json,
        fold(continued.map(StreamEvent.fromJson)).json);
    expect(transport.opens.single.$2, 6);
    await controller.dispose();
  });
  test('resume_backoff_round_budget_is_bounded', () async {
    final delays = <Duration>[];
    final authority = Authority(null);
    final transport = ScriptedTransport(connections: [
      for (var i = 0; i < 3; i++) (_, __) async => throw StateError('offline'),
    ]);
    final controller = ChatWeaveStreamController(
        store: BlockStore(),
        persistence: MemoryStore(),
        transport: transport,
        authority: authority,
        caps: caps,
        policy: const ResumePolicy(maxRounds: 3),
        wait: (delay) async {
          delays.add(delay);
        });
    await controller.subscribe('msg_weather');
    expect(transport.opens.length, 3);
    expect(delays.map((d) => d.inMilliseconds), [250, 500, 1000]);
    expect(authority.calls, 1);
    await controller.dispose();
  });

  test('retired_connection_cannot_mutate_store', () async {
    final events = streamFixture('01-markdown');
    final old = async.StreamController<List<int>>();
    List<int> encode(Json event) => utf8.encode(
        'id: ${event['seq']}\nevent: ${event['type']}\ndata: ${jsonEncode(event)}\n\n');
    final transport = ScriptedTransport(connections: [
      (_, __) async {
        async.scheduleMicrotask(() {
          old.add(encode(events[0]));
          old.add(encode(events[1]));
          old.add(
              encode(events[3])); // seq 3 is missing, retire this connection.
        });
        return StreamConnection(
            status: 200,
            headers: const {'ChatWeave-Protocol': '0.1'},
            bytes: old.stream);
      },
      (_, cursor) async {
        expect(cursor, 2);
        old.add(encode({
          ...events[2],
          'delta': {'text': '不应出现'}
        }));
        return connection(events.skip(2).toList());
      },
    ]);
    final store = BlockStore();
    final controller = ChatWeaveStreamController(
        store: store,
        persistence: MemoryStore(),
        transport: transport,
        authority: Authority(null),
        caps: caps,
        wait: (_) async {});
    await controller.subscribe('msg_weather');
    expect(store.snapshot.messages['msg_weather']!.json,
        fold(events.map(StreamEvent.fromJson)).json);
    expect(jsonEncode(store.snapshot.messages['msg_weather']!.json),
        isNot(contains('不应出现')));
    await old.close();
    await controller.dispose();
  });
}
