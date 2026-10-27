import 'dart:async' as async;

import 'model.dart';
import 'ports.dart';
import 'sse.dart';
import 'store.dart';

enum ResumeTrigger {
  conversation,
  foreground,
  online,
  heartbeat,
  action,
  activeChanged,
  checkpoint
}

class ResumePolicy {
  const ResumePolicy(
      {this.maxRounds = 5,
      this.maxElapsed = const Duration(minutes: 2),
      this.heartbeatTimeout = const Duration(seconds: 45)});
  final int maxRounds;
  final Duration maxElapsed;
  final Duration heartbeatTimeout;
  Duration delay(int round) =>
      Duration(milliseconds: 250 * (1 << round.clamp(0, 6).toInt()));
}

class StreamController {
  StreamController(
      {required this.store,
      required this.persistence,
      required this.transport,
      required this.authority,
      required this.caps,
      this.policy = const ResumePolicy(),
      async.Future<void> Function(Duration)? wait,
      DateTime Function()? now})
      : _wait = wait ?? async.Future<void>.delayed,
        _now = now ?? DateTime.now;
  final BlockStore store;
  final ChatWeaveStore persistence;
  final StreamTransport transport;
  final AuthoritativeRefresh authority;
  final ClientCapabilities caps;
  final ResumePolicy policy;
  final async.Future<void> Function(Duration) _wait;
  final DateTime Function() _now;
  final _flights = <String, async.Future<void>>{};
  final _epochs = <String, int>{};
  final _subscriptions = <String, async.StreamSubscription<StreamEvent>>{};
  final _completions = <String, async.Completer<void>>{};
  bool _disposed = false;

  async.Future<void> subscribe(
    String messageId, {
    ResumeTrigger trigger = ResumeTrigger.conversation,
  }) {
    if (_disposed) return async.Future.value();
    return _flights.putIfAbsent(messageId, () {
      // A microtask ensures the flight is installed before any adapter runs.
      final flight =
          async.Future<void>.microtask(() => _run(messageId, trigger));
      return flight.whenComplete(() {
        _flights.remove(messageId);
      });
    });
  }

  async.Future<void> refresh(String id) async {
    final message = await authority.refresh(id);
    if (message != null) {
      store.apply(SyncMessage(message));
      if (message.rev > 0) {
        await persistence.saveFinal(message);
      } else {
        await persistence.saveProvisional(message,
            lastSeq: message['lastSeq'] as int? ?? 0);
      }
    }
  }

  async.Future<void> _run(String id, ResumeTrigger trigger) async {
    store.recordDiagnostic('resume', id, {
      'trigger': trigger.name,
      'phase': 'checking',
      'seq': store.snapshot.cursors[id]
    });
    final client = await persistence.loadClientState(id);
    if (client.stopRequested) {
      await refresh(id);
      return;
    }
    if (store.snapshot.messages[id] == null) {
      final cached = await persistence.load(id);
      if (cached != null) store.apply(SyncMessage(cached));
    }
    final initial = store.snapshot.messages[id];
    if ((initial?.rev ?? 0) > 0) return;
    if (initial?.status == 'paused' &&
        !const {
          ResumeTrigger.action,
          ResumeTrigger.activeChanged,
          ResumeTrigger.checkpoint,
        }.contains(trigger)) return;
    final epoch = (_epochs[id] ?? 0) + 1;
    _epochs[id] = epoch;
    final began = _now();
    for (var round = 0; round < policy.maxRounds; round++) {
      if (_disposed || _epochs[id] != epoch) return;
      if ((await persistence.loadClientState(id)).stopRequested) return;
      try {
        store.recordDiagnostic('resume', id, {
          'trigger': trigger.name,
          'round': round + 1,
          'phase': 'connecting',
          'seq': store.snapshot.cursors[id]
        });
        final connection = await transport.open(id,
            afterSeq: store.snapshot.cursors[id], caps: caps);
        final headers =
            connection.headers.map((k, v) => MapEntry(k.toLowerCase(), v));
        if (connection.status == 204 ||
            connection.status != 200 ||
            headers['chatweave-protocol'] != '0.1') {
          await refresh(id);
          return;
        }
        // Timeout is measured on raw bytes, so SSE heartbeat comments count.
        final events = connection.bytes
            .timeout(policy.heartbeatTimeout)
            .transform(const SseDecoder())
            .map(const EventParser().parse);
        final done = async.Completer<void>();
        _completions[id] = done;
        final sub = events.listen((event) {
          if (_disposed || _epochs[id] != epoch || done.isCompleted) return;
          try {
            if (event.messageId != id)
              throw const ProtocolError('message_mismatch');
            // A replayed pause/end must not retire the new connection.
            if (event.type != 'message.snapshot' &&
                event.seq != null &&
                event.seq! <= (store.snapshot.cursors[id] ?? 0)) return;
            store.apply(ApplyStream(event));
            if (event.type == 'error' &&
                object(event['error'])['code'] == 'resume_unavailable') {
              throw const ProtocolError('resume_unavailable');
            }
            if (event.type == 'message.paused' || event.type == 'message.end') {
              done.complete();
            }
          } catch (error, stack) {
            done.completeError(error, stack);
          }
        }, onError: (Object error, StackTrace stack) {
          if (!done.isCompleted) done.completeError(error, stack);
        }, onDone: () {
          if (!done.isCompleted) done.complete();
        });
        _subscriptions[id] = sub;
        try {
          await done.future;
        } finally {
          await sub.cancel();
          if (identical(_completions[id], done)) _completions.remove(id);
          if (identical(_subscriptions[id], sub)) _subscriptions.remove(id);
        }
        final message = store.snapshot.messages[id];
        if (message != null) {
          if (_disposed || _epochs[id] != epoch) return;
          if (message.rev > 0) {
            store.recordDiagnostic('resume', id, {
              'trigger': trigger.name,
              'round': round + 1,
              'phase': message.status,
              'seq': store.snapshot.cursors[id]
            });
            await persistence.saveFinal(message);
            return;
          }
          await persistence.saveProvisional(message,
              lastSeq: store.snapshot.cursors[id] ?? 0);
          if (message.status == 'paused') {
            store.recordDiagnostic('resume', id, {
              'trigger': trigger.name,
              'round': round + 1,
              'phase': 'paused',
              'seq': store.snapshot.cursors[id]
            });
            return;
          }
        }
      } on ProtocolError catch (error) {
        store.recordDiagnostic('resume', id, {
          'trigger': trigger.name,
          'round': round + 1,
          'phase': 'error',
          'code': error.code,
          'seq': store.snapshot.cursors[id]
        });
        if (const {'resume_unavailable', 'rev_gap', 'unsupported_protocol'}
            .contains(error.code)) {
          await refresh(id);
          return;
        }
      } catch (_) {
        // Transport uncertainty resumes only from the last successfully applied seq.
      }
      if (_now().difference(began) >= policy.maxElapsed) break;
      await _wait(policy.delay(round));
    }
    if (!_disposed && _epochs[id] == epoch) await refresh(id);
  }

  async.Future<void> stop(String id) async {
    await updateClientState(
        persistence, id, (state) => state.copyWith(stopRequested: true));
    _epochs[id] = (_epochs[id] ?? 0) + 1;
    final done = _completions.remove(id);
    if (done != null && !done.isCompleted) done.complete();
    await _subscriptions.remove(id)?.cancel();
    await transport.stop(id);
    await refresh(id);
  }

  async.Future<void> acceptCheckpoint(Message message) async {
    final previous = store.snapshot.messages[message.id];
    final cursor = store.snapshot.cursors[message.id] ?? 0;
    store.apply(SyncMessage(message));
    if (previous?.status == 'paused' &&
        message.rev == 0 &&
        (message['lastSeq'] as int? ?? 0) > cursor) {
      await subscribe(message.id, trigger: ResumeTrigger.checkpoint);
    }
  }

  async.Future<void> recoverConversation(String conversationId) async {
    final activeMessages = await transport.activeMessages(conversationId);
    await async.Future.wait(activeMessages.map((active) {
      final local = store.snapshot.messages[active.id];
      final changed = local?.status == 'paused' && active['status'] != 'paused';
      return subscribe(active.id,
          trigger: changed
              ? ResumeTrigger.activeChanged
              : ResumeTrigger.conversation);
    }));
  }

  async.Future<void> dispose() async {
    _disposed = true;
    for (final done in _completions.values) {
      if (!done.isCompleted) done.complete();
    }
    _completions.clear();
    for (final sub in _subscriptions.values) {
      await sub.cancel();
    }
    _subscriptions.clear();
  }
}
