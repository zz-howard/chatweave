import 'dart:async';
import 'dart:convert';

import 'model.dart';
import 'ports.dart';

/// In-process replay transport for integration tests. The producer explicitly
/// supplies protocol events and checkpoints; disconnecting does not stop it.
class MemoryTransport implements StreamTransport, ActionTransport {
  final _logs = <String, List<StreamEvent>>{};
  final _broadcasts = <String, StreamController<StreamEvent>>{};
  final _checkpoints = <String, Message>{};
  final opens = <(String, int?)>[];
  final requests = <ActionRequest>[];
  final stops = <String>[];
  Future<ActionSubmission> Function(ActionRequest)? onAction;
  Future<StopResult> Function(String)? onStop;
  void append(StreamEvent event) {
    if (event.type != 'message.activity') {
      _logs.putIfAbsent(event.messageId, () => []).add(event);
    }
    _broadcasts
        .putIfAbsent(event.messageId,
            () => StreamController<StreamEvent>.broadcast(sync: true))
        .add(event);
  }

  void checkpoint(Message message) {
    _checkpoints[message.id] = message;
  }

  void clearLog(String messageId) {
    _logs.remove(messageId);
  }

  Future<void> disconnect(String messageId) async {
    await _broadcasts.remove(messageId)?.close();
  }

  List<int> _encode(StreamEvent event) => utf8.encode(
      '${event.seq == null ? '' : 'id: ${event.seq}\n'}event: ${event.type}\ndata: ${jsonEncode(event.json)}\n\n');
  @override
  Future<StreamConnection> open(
    String messageId, {
    int? afterSeq,
    required ClientCapabilities caps,
  }) async {
    opens.add((messageId, afterSeq));
    final broadcast = _broadcasts.putIfAbsent(
        messageId, () => StreamController<StreamEvent>.broadcast(sync: true));
    final bytes = Stream<List<int>>.multi((sink) {
      var cursor = afterSeq ?? 0;
      // Install the listener before reading the retained log.
      final queued = <StreamEvent>[];
      var replaying = true;
      var terminal = false;
      void deliver(StreamEvent event) {
        if (terminal) return;
        if (event.seq != null && event.seq! <= cursor) return;
        if (event.seq != null) cursor = event.seq!;
        sink.add(_encode(event));
        if (event.type == 'message.end' ||
            event.type == 'message.paused' ||
            (event.type == 'message.snapshot' &&
                object(event['message'])['status'] != 'streaming')) {
          terminal = true;
          sink.close();
        }
      }

      final subscription = broadcast.stream.listen((event) {
        if (replaying) {
          queued.add(event);
        } else {
          deliver(event);
        }
      }, onDone: sink.close);
      sink.onCancel = subscription.cancel;
      final log = List<StreamEvent>.of(_logs[messageId] ?? const []);
      final checkpoint = _checkpoints[messageId];
      if (log.isEmpty && checkpoint != null) {
        deliver(StreamEvent.fromJson({
          'protocolVersion': '0.1',
          'type': 'message.snapshot',
          'messageId': messageId,
          'seq': checkpoint['lastSeq'] ?? cursor,
          'message': checkpoint.json
        }));
      } else {
        for (final event in log) {
          deliver(event);
        }
      }
      replaying = false;
      for (final event in queued) {
        deliver(event);
      }
    });
    return StreamConnection(
        status: 200,
        headers: const {'ChatWeave-Protocol': '0.1'},
        bytes: bytes);
  }

  @override
  Future<StopResult> stop(String messageId) async {
    stops.add(messageId);
    if (onStop != null) return await onStop!(messageId);
    return StopResult.fromJson({'messageId': messageId, 'status': 'stopping'});
  }

  @override
  Future<List<ActiveMessage>> activeMessages(String conversationId) async => [
        for (final message in _checkpoints.values)
          if (message['conversationId'] == conversationId &&
              const ['streaming', 'paused'].contains(message.status))
            ActiveMessage.fromJson({
              'messageId': message.id,
              'status': message.status,
              'lastSeq': message['lastSeq']
            }),
      ];
  @override
  Future<ActionSubmission> submit(ActionRequest request) async {
    requests.add(request);
    if (onAction != null) return await onAction!(request);
    return const ActionSubmission.queued();
  }

  Future<void> dispose() async {
    for (final broadcast in _broadcasts.values) {
      await broadcast.close();
    }
    _broadcasts.clear();
  }
}
