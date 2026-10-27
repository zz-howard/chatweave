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
