import 'dart:async';

import 'model.dart';

class ClientState {
  ClientState(
      {this.stopRequested = false,
      Map<String, ActionRequest> intents = const {}})
      : intents = Map.unmodifiable(intents);
  final bool stopRequested;
  final Map<String, ActionRequest> intents;
  ClientState copyWith(
          {bool? stopRequested, Map<String, ActionRequest>? intents}) =>
      ClientState(
          stopRequested: stopRequested ?? this.stopRequested,
          intents: intents ?? this.intents);
}

abstract interface class ChatWeaveStore {
  Stream<List<Message>> watchConversation(String conversationId);
  Future<Message?> load(String messageId);
  Future<void> saveProvisional(Message message, {required int lastSeq});
  Future<void> saveFinal(Message message);
  Future<int?> lastSeq(String messageId);
  Future<ClientState> loadClientState(String messageId);
  Future<void> saveClientState(String messageId, ClientState state);
  Future<void> clear();
}

abstract interface class AuthoritativeRefresh {
  /// Must contact the authoritative synchronization source, not read a cache.
  Future<Message?> refresh(String messageId);
}

class StreamConnection {
  const StreamConnection(
      {required this.status, required this.headers, required this.bytes});
  final int status;
  final Map<String, String> headers;
  final Stream<List<int>> bytes;
}

class StopResult extends WireModel {
  StopResult.fromJson(super.json);
}

class ActiveMessage extends WireModel {
  ActiveMessage.fromJson(super.json);
  String get id => json['messageId'] as String;
}

abstract interface class StreamTransport {
  Future<StreamConnection> open(
    String messageId, {
    int? afterSeq,
    required ClientCapabilities caps,
  });
  Future<StopResult> stop(String messageId);
  Future<List<ActiveMessage>> activeMessages(String conversationId);
}

class ActionSubmission {
  const ActionSubmission.result(this.result) : queued = false;
  const ActionSubmission.queued()
      : queued = true,
        result = null;
  final bool queued;
  final ActionResult? result;
}

abstract interface class ActionTransport {
  Future<ActionSubmission> submit(ActionRequest request);
}

abstract interface class DraftPort {
  String get text;
  set text(String value);
  void focus();
}

class MemoryStore implements ChatWeaveStore {
  final _messages = <String, Message>{};
  final _cursors = <String, int>{};
  final _clients = <String, ClientState>{};
  final _changes = StreamController<void>.broadcast(sync: true);
  @override
  Stream<List<Message>> watchConversation(String conversationId) =>
      Stream<List<Message>>.multi((sink) {
        List<Message> select() => _messages.values
            .where(
              (m) => m['conversationId'] == conversationId,
            )
            .toList();
        final subscription = _changes.stream.listen((_) {
          sink.add(select());
        });
        sink.add(select());
        sink.onCancel = subscription.cancel;
      });
  @override
  Future<Message?> load(String messageId) async => _messages[messageId];
  @override
  Future<int?> lastSeq(String messageId) async => _cursors[messageId];
  @override
  Future<ClientState> loadClientState(String messageId) async =>
      _clients[messageId] ?? ClientState();
  @override
  Future<void> saveClientState(String messageId, ClientState state) async {
    _clients[messageId] = state;
  }

  @override
  Future<void> saveProvisional(Message message, {required int lastSeq}) async {
    final old = _messages[message.id];
    if ((old?.rev ?? 0) > 0 || (_cursors[message.id] ?? 0) > lastSeq) return;
    _messages[message.id] = message;
    _cursors[message.id] = lastSeq;
    _changes.add(null);
  }

  @override
  Future<void> saveFinal(Message message) async {
    if (message.rev < 1) throw const ProtocolError('invalid_rev');
    if ((_messages[message.id]?.rev ?? 0) > message.rev) return;
    _messages[message.id] = message;
    _changes.add(null);
  }

  @override
  Future<void> clear() async {
    _messages.clear();
    _cursors.clear();
    _clients.clear();
    _changes.add(null);
  }

  Future<void> dispose() => _changes.close();
}

/// Deterministic byte scripts, including metadata and transport failures.
class ScriptedTransport implements StreamTransport, ActionTransport {
  ScriptedTransport({required this.connections, this.actions = const []});
  final List<Future<StreamConnection> Function(String, int?)> connections;
  final List<Future<ActionSubmission> Function(ActionRequest)> actions;
  final opens = <(String, int?)>[];
  final requests = <ActionRequest>[];
  final stops = <String>[];
  List<ActiveMessage> active = [];
  @override
  Future<StreamConnection> open(
    String messageId, {
    int? afterSeq,
    required ClientCapabilities caps,
  }) {
    final index = opens.length;
    opens.add((messageId, afterSeq));
    return connections[index](messageId, afterSeq);
  }

  @override
  Future<ActionSubmission> submit(ActionRequest request) {
    final index = requests.length;
    requests.add(request);
    return actions[index](request);
  }

  @override
  Future<StopResult> stop(String messageId) async {
    stops.add(messageId);
    return StopResult.fromJson({'messageId': messageId, 'status': 'stopping'});
  }

  @override
  Future<List<ActiveMessage>> activeMessages(String conversationId) async =>
      active;
}

final _clientTransactions = Expando<Map<String, Future<void>>>();

/// Serializes library read/modify/write operations per adapter and message,
/// including stop markers and actions on different blocks.
Future<void> updateClientState(ChatWeaveStore store, String messageId,
    ClientState Function(ClientState) update) {
  final transactions = _clientTransactions[store] ??= <String, Future<void>>{};
  final previous = transactions[messageId] ?? Future<void>.value();
  final next = previous.then((_) async {
    final current = await store.loadClientState(messageId);
    await store.saveClientState(messageId, update(current));
  });
  // Keep a non-failing queue tail so a persistence error does not poison retries.
  final tail = next.catchError((Object _) {});
  transactions[messageId] = tail;
  tail.whenComplete(() {
    if (identical(transactions[messageId], tail))
      transactions.remove(messageId);
  });
  return next;
}
