import 'dart:async' as async;
import 'dart:async' show StreamController;
import 'dart:convert';

import 'interaction_test.dart' as actions;

import 'package:chatweave_core/chatweave_core.dart';
import 'package:chatweave_core/testing.dart';
import 'package:test/test.dart';

import 'resume_test.dart' as fixtures;

class RefreshSequence implements AuthoritativeRefresh {
  RefreshSequence(this.fetch);
  final async.Future<Message?> Function(int) fetch;
  int calls = 0;
  @override
  async.Future<Message?> refresh(String id) => fetch(++calls);
}

class CountingInvalidJson {
  int calls = 0;
  Object toJson() {
    calls++;
    throw StateError('invalid revision');
  }
}

void main() {
  test('block_validation_caches_failure_per_immutable_revision', () {
    final probe = CountingInvalidJson();
    final first = Block.fromJson({
      'id': 'bad',
      'type': 'markdown',
      'schemaVersion': 1,
      'data': {'text': 'ok', 'probe': probe},
    });
    for (var i = 0; i < 10; i++) {
      expect(() => validateBlock(first.json), throwsA(anything));
    }
    expect(probe.calls, 1);
    final revised = Block.fromJson({
      ...first.json,
      'data': {...first.data, 'text': 'new'},
    });
    expect(() => validateBlock(revised.json), throwsA(anything));
    expect(probe.calls, 2);
  });
  test('public_core_and_dart_async_controller_names_do_not_conflict', () async {
    final events = StreamController<int>.broadcast();
    await events.close();
    expect(ChatWeaveStreamController, isNotNull);
    expect(MemoryStore(), isA<ChatWeaveStore>());
    expect(ScriptedTransport(connections: []), isA<StreamTransport>());
  });
  test('progress_at_150_seconds_allows_three_minute_generation', () async {
    var now = DateTime.utc(2026);
    final events = fixtures.streamFixture('01-markdown');
    async.Stream<List<int>> longStream() async* {
      for (final event in events.take(3)) {
        now = now.add(const Duration(seconds: 50));
        yield utf8.encode(
          'id: ${event['seq']}\nevent: ${event['type']}\n'
          'data: ${jsonEncode(event)}\n\n',
        );
      }
    }

    final transport = ScriptedTransport(
      connections: [
        (_, __) async => StreamConnection(
              status: 200,
              headers: {'ChatWeave-Protocol': '0.1'},
              bytes: longStream(),
            ),
        (_, cursor) async {
          expect(cursor, 3);
          now = now.add(const Duration(seconds: 30));
          return fixtures.connection(events.skip(3).toList());
        },
      ],
    );
    final store = BlockStore();
    final controller = ChatWeaveStreamController(
      store: store,
      persistence: MemoryStore(),
      transport: transport,
      authority: fixtures.Authority(null),
      caps: fixtures.caps,
      now: () => now,
      wait: (_) async {},
    );
    await controller.subscribe('msg_weather');
    expect(transport.opens.length, 2);
    expect(store.snapshot.messages['msg_weather']!.rev, 1);
    await controller.dispose();
  });

  test('six_disconnects_with_progress_all_resume', () async {
    final events = fixtures.streamFixture('02-weather-todo-mixed');
    final transport = ScriptedTransport(
      connections: [
        for (var i = 0; i < 6; i++)
          (_, __) async => fixtures.connection([events[i]]),
        (_, __) async => fixtures.connection(events.skip(6).toList()),
      ],
    );
    final store = BlockStore();
    final controller = ChatWeaveStreamController(
      store: store,
      persistence: MemoryStore(),
      transport: transport,
      authority: fixtures.Authority(null),
      caps: fixtures.caps,
      wait: (_) async {},
    );
    await controller.subscribe('msg_weather');
    expect(transport.opens.length, 7);
    expect(
      store.snapshot.messages['msg_weather']!.json,
      fold(events.map(StreamEvent.fromJson)).json,
    );
    await controller.dispose();
  });

  test('stop_keeps_live_connection_until_message_end', () async {
    final events = fixtures.streamFixture('01-markdown');
    final transport = MemoryTransport();
    final store = BlockStore();
    final poll = async.Completer<void>();
    final controller = ChatWeaveStreamController(
      store: store,
      persistence: MemoryStore(),
      transport: transport,
      authority: fixtures.Authority(null),
      caps: fixtures.caps,
      wait: (_) => poll.future,
    );
    transport.append(StreamEvent.fromJson(events.first));
    final flight = controller.subscribe('msg_weather');
    await async.Future<void>.delayed(Duration.zero);
    final stopping = controller.stop('msg_weather');
    await async.Future<void>.delayed(Duration.zero);
    for (final event in events.skip(1)) {
      transport.append(StreamEvent.fromJson(event));
    }
    await async.Future<void>.delayed(Duration.zero);
    expect(store.snapshot.messages['msg_weather']!.rev, 1);
    poll.complete();
    await async.Future.wait([flight, stopping]);
    expect(transport.opens.length, 1);
    await controller.dispose();
    await transport.dispose();
  });

  test('stop_refresh_retries_errors_and_provisional_until_final', () async {
    final events = fixtures.streamFixture('01-markdown');
    final provisional = fold(events.take(2).map(StreamEvent.fromJson));
    final finalMessage = fold(events.map(StreamEvent.fromJson));
    final authority = RefreshSequence((attempt) async {
      if (attempt == 1) throw StateError('offline');
      return attempt < 4 ? provisional : finalMessage;
    });
    final store = BlockStore()..apply(SyncMessage(provisional));
    final controller = ChatWeaveStreamController(
      store: store,
      persistence: MemoryStore(),
      transport: ScriptedTransport(connections: []),
      authority: authority,
      caps: fixtures.caps,
      wait: (_) async {},
    );
    await controller.stop('msg_weather');
    expect(authority.calls, 4);
    expect(store.snapshot.messages['msg_weather']!.rev, 1);
    await controller.dispose();
  });

  test('open_timeout_counts_as_failure_and_retries', () async {
    final events = fixtures.streamFixture('01-markdown');
    final transport = ScriptedTransport(
      connections: [
        (_, __) => async.Completer<StreamConnection>().future,
        (_, __) async => fixtures.connection(events),
      ],
    );
    final controller = ChatWeaveStreamController(
      store: BlockStore(),
      persistence: MemoryStore(),
      transport: transport,
      authority: fixtures.Authority(null),
      caps: fixtures.caps,
      policy: const ResumePolicy(openTimeout: Duration(milliseconds: 1)),
      wait: (_) async {},
    );
    await controller.subscribe('msg_weather');
    expect(transport.opens.length, 2);
    await controller.dispose();
  });

  test('final_sync_retires_subscription_while_open_is_pending', () async {
    final opening = async.Completer<StreamConnection>();
    final entered = async.Completer<void>();
    final transport = ScriptedTransport(
      connections: [
        (_, __) {
          entered.complete();
          return opening.future;
        },
      ],
    );
    final store = BlockStore();
    final controller = ChatWeaveStreamController(
      store: store,
      persistence: MemoryStore(),
      transport: transport,
      authority: fixtures.Authority(null),
      caps: fixtures.caps,
    );
    final flight = controller.subscribe('msg_weather');
    await entered.future;
    store.apply(
      SyncMessage(
        fold(fixtures.streamFixture('01-markdown').map(StreamEvent.fromJson)),
      ),
    );
    await flight.timeout(const Duration(seconds: 1));
    opening.complete(fixtures.connection([]));
    await controller.dispose();
  });

  test(
    'provisional_snapshot_cannot_replace_final_and_sync_retires_stream',
    () async {
      final events = fixtures.streamFixture('01-markdown');
      final transport = MemoryTransport();
      final store = BlockStore();
      transport.append(StreamEvent.fromJson(events.first));
      final controller = ChatWeaveStreamController(
        store: store,
        persistence: MemoryStore(),
        transport: transport,
        authority: fixtures.Authority(null),
        caps: fixtures.caps,
      );
      final flight = controller.subscribe('msg_weather');
      await async.Future<void>.delayed(Duration.zero);
      final finalMessage = fold(events.map(StreamEvent.fromJson));
      store.apply(SyncMessage(finalMessage));
      await flight.timeout(const Duration(seconds: 1));
      final previous = store.snapshot;
      store.apply(
        ApplyStream(
          StreamEvent.fromJson({
            'type': 'message.snapshot',
            'protocolVersion': '0.1',
            'messageId': 'msg_weather',
            'seq': 99,
            'message': {
              ...finalMessage.json,
              'rev': 0,
              'status': 'streaming',
              'lastSeq': 99,
            },
          }),
        ),
      );
      expect(identical(store.snapshot, previous), isTrue);
      await controller.dispose();
      await transport.dispose();
    },
  );

  for (final restore in [false, true]) {
    test(
      'uncertain_${restore ? 'restore' : 'submit'}_auto_retries_same_id_then_exposes_retry',
      () async {
        final store = BlockStore()..apply(SyncMessage(actions.seed()));
        final persistence = MemoryStore();
        final request = ActionRequest.fromJson({
          'id': 'intent',
          'protocolVersion': '0.1',
          'type': 'choice.select',
          'target': 'weather.select',
          'context': {'messageId': 'm', 'blockId': 'b1'},
          'payload': {
            'selected': ['bj'],
          },
        });
        if (restore)
          await persistence.saveClientState(
            'm',
            ClientState(intents: {'b1': request}),
          );
        final transport = ScriptedTransport(
          connections: [],
          actions: [
            for (var i = 0; i < 3; i++)
              (_) async => throw StateError('offline'),
            (_) async => const ActionSubmission.queued(),
          ],
        );
        final delays = <Duration>[];
        var ids = 0;
        final controller = InteractionController(
          store: store,
          persistence: persistence,
          transport: transport,
          nextId: () => ++ids == 1 ? 'intent' : 'intent_$ids',
          maxAutomaticRetries: 2,
          wait: (delay) async {
            delays.add(delay);
          },
          onRefresh: (_) async {},
        );
        if (restore) {
          await controller.restore('m');
        } else {
          await controller.submit('m', 'b1', {
            'selected': ['bj'],
          });
        }
        expect(transport.requests.length, 3);
        expect(delays.map((d) => d.inMilliseconds), [250, 500]);
        expect(
          controller.stateFor('m', 'b1').phase,
          InteractionPhase.retryable,
        );
        await controller.retry('m', 'b1');
        expect(controller.stateFor('m', 'b1').phase, InteractionPhase.queued);
        expect(transport.requests.map((r) => r.id).toSet(), {'intent'});
        expect(ids, restore ? 0 : 1);
        expect(
          transport.requests.map((r) => r['payload']).toList(),
          everyElement({
            'selected': ['bj'],
          }),
        );
        await controller.dispose();
      },
    );
  }

  for (final kind in ['markdown', 'depth', 'nodes']) {
    for (final route in ['snapshot', 'patch']) {
      test('consumer_${kind}_limit_is_block_local_via_$route', () {
        final base = actions.seed();
        final good = {
          'id': 'good',
          'type': 'markdown',
          'schemaVersion': 1,
          'data': {'text': '天气'},
        };
        Object? extra = true;
        for (var i = 0; i < 7; i++) {
          extra = {'nested': extra};
        }
        final bad = {
          'id': 'bad',
          'type': 'markdown',
          'schemaVersion': 1,
          'fallbackText': '内容过大',
          'data': {
            'text': kind == 'markdown' ? 'a' * 32769 : 'ok',
            if (kind == 'depth') 'extra': extra,
            if (kind == 'nodes') 'extra': List.filled(5001, 0),
          },
        };
        final store = BlockStore();
        final message = Message.fromJson({
          ...base.json,
          'blocks': [
            good,
            if (route == 'snapshot') bad else {...good, 'id': 'bad'},
          ],
        });
        if (route == 'snapshot') {
          store.apply(
            ApplyStream(
              StreamEvent.fromJson({
                'protocolVersion': '0.1',
                'type': 'message.snapshot',
                'messageId': 'm',
                'seq': 1,
                'message': message.json,
              }),
            ),
          );
        } else {
          store.apply(SyncMessage(message));
          store.apply(ActionPatch('m', 'bad', 2, bad));
        }
        final blocks = store.snapshot.messages['m']!.blocks;
        expect(() => validateBlock(blocks.first.json), returnsNormally);
        expect(
          () => validateBlock(blocks.last.json),
          throwsA(isA<ProtocolError>()),
        );
        expect(blocks.last['fallbackText'], '内容过大');
      });
    }
  }
  test('consumer_markdown_delta_crossing_32kb_keeps_stream_and_siblings', () {
    final state = FoldState();
    final events = fixtures.streamFixture('01-markdown');
    for (final event in events.take(2)) {
      state.apply(StreamEvent.fromJson(event));
    }
    final delta = events.firstWhere((e) => e['type'] == 'block.delta');
    for (var i = 0; i < 9; i++) {
      state.apply(
        StreamEvent.fromJson({
          ...delta,
          'seq': i + 3,
          'delta': {'text': 'a' * 4096},
        }),
      );
    }
    expect(state.lastSeq, 11);
    expect(
      () => validateBlock(state.message.blocks.single.json),
      throwsA(isA<ProtocolError>()),
    );
  });

  test(
    'uncertain_refresh_closed_block_clears_intent_without_resending',
    () async {
      final store = BlockStore()..apply(SyncMessage(actions.seed()));
      final persistence = MemoryStore();
      final transport = ScriptedTransport(
        connections: [],
        actions: [(_) async => throw StateError('lost response')],
      );
      final controller = InteractionController(
        store: store,
        persistence: persistence,
        transport: transport,
        nextId: () => 'same',
        wait: (_) async {},
        onRefresh: (_) async {
          store.apply(
            const ActionPatch('m', 'b1', 2, {
              'data': {
                'state': {
                  'status': 'resolved',
                  'selected': ['bj'],
                  'resolvedAt': '2026-10-26T09:31:00Z',
                },
              },
            }),
          );
        },
      );
      await controller.submit('m', 'b1', {
        'selected': ['bj'],
      });
      expect(transport.requests.length, 1);
      expect(controller.stateFor('m', 'b1').phase, InteractionPhase.accepted);
      expect((await persistence.loadClientState('m')).intents, isEmpty);
      await controller.dispose();
    },
  );

  test('uncertain_refresh_timeout_does_not_deadlock', () async {
    final store = BlockStore()..apply(SyncMessage(actions.seed()));
    final transport = ScriptedTransport(
      connections: [],
      actions: [
        (_) async => throw StateError('offline'),
        (_) async => const ActionSubmission.queued(),
      ],
    );
    final controller = InteractionController(
      store: store,
      persistence: MemoryStore(),
      transport: transport,
      nextId: () => 'same',
      wait: (_) async {},
      timeout: const Duration(milliseconds: 1),
      onRefresh: (_) => async.Completer<void>().future,
    );
    await controller.submit('m', 'b1', {
      'selected': ['bj'],
    });
    expect(controller.stateFor('m', 'b1').phase, InteractionPhase.queued);
    expect(transport.requests.map((r) => r.id).toList(), ['same', 'same']);
    await controller.dispose();
  });

  test('consecutive_failure_elapsed_window_uses_injected_clock', () async {
    var now = DateTime.utc(2026);
    final transport = ScriptedTransport(
      connections: [
        for (var i = 0; i < 10; i++)
          (_, __) async => throw StateError('offline'),
      ],
    );
    final controller = ChatWeaveStreamController(
      store: BlockStore(),
      persistence: MemoryStore(),
      transport: transport,
      authority: fixtures.Authority(null),
      caps: fixtures.caps,
      now: () => now,
      policy: const ResumePolicy(
        maxRounds: 10,
        maxElapsed: Duration(seconds: 15),
      ),
      wait: (_) async {
        now = now.add(const Duration(seconds: 10));
      },
    );
    await controller.subscribe('msg_weather');
    expect(transport.opens.length, 2);
    await controller.dispose();
  });

  test(
    'sse_rejects_unterminated_oversized_line_before_stream_closes',
    () async {
      final input = async.StreamController<List<int>>();
      final result = input.stream.transform(const SseDecoder()).toList();
      final check = expectLater(result, throwsA(isA<ProtocolError>()));
      input.add(List.filled(131072, 65));
      input.add([65]);
      await check;
      await input.close();
    },
  );
}
