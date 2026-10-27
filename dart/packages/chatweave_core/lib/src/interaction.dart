import 'dart:async';

import 'model.dart';
import 'ports.dart';
import 'store.dart';
import 'validation.dart';

bool _validBlock(Block? block) {
  if (block == null) return false;
  try {
    validateBlock(block.json);
    return true;
  } catch (_) {
    return false;
  }
}

enum InteractionPhase {
  idle,
  submitting,
  queued,
  confirming,
  rejected,
  accepted
}

class InteractionState {
  const InteractionState(
      {this.phase = InteractionPhase.idle,
      this.request,
      this.error,
      this.fieldErrors = const {},
      this.resumeAccepted = false});
  final InteractionPhase phase;
  final ActionRequest? request;
  final String? error;
  final Json fieldErrors;
  final bool resumeAccepted;
  bool get locked =>
      phase != InteractionPhase.idle && phase != InteractionPhase.rejected;
}

class InteractionController {
  InteractionController(
      {required this.store,
      required this.persistence,
      required this.nextId,
      this.transport,
      this.onResume,
      this.onFollowUp,
      this.onRefresh,
      this.timeout = const Duration(seconds: 30)});
  final BlockStore store;
  final ChatWeaveStore persistence;
  final String Function() nextId;
  final ActionTransport? transport;
  final Future<void> Function(String)? onResume;
  final Future<void> Function(String)? onFollowUp;
  final Future<void> Function(String)? onRefresh;
  final Duration timeout;
  final _states = <String, InteractionState>{};
  final _flights = <String, Future<void>>{};
  final _changes = StreamController<void>.broadcast(sync: true);
  Stream<void> get changes => _changes.stream;
  String _key(String messageId, String blockId) => '$messageId/$blockId';
  InteractionState stateFor(String messageId, String blockId) =>
      _states[_key(messageId, blockId)] ?? const InteractionState();
  void _set(String key, InteractionState state) {
    _states[key] = state;
    store.recordDiagnostic('actions', key,
        {'phase': state.phase.name, 'actionId': state.request?['id']});
    _changes.add(null);
  }

  Future<void> restore(String messageId) async {
    final saved = await persistence.loadClientState(messageId);
    for (final entry in saved.intents.entries) {
      _set(
          _key(messageId, entry.key),
          InteractionState(
              phase: InteractionPhase.confirming, request: entry.value));
    }
  }

  Future<void> submit(
    String messageId,
    String blockId,
    Json payload, {
    bool canAnswer = true,
  }) {
    if (transport == null || !canAnswer) return Future.value();
    final key = _key(messageId, blockId);
    if (stateFor(messageId, blockId).locked)
      return _flights[key] ?? Future.value();
    final message = store.snapshot.messages[messageId];
    final block = message?.blocks.where((b) => b.id == blockId).firstOrNull;
    if (block == null) throw const ProtocolError('unknown_block');
    if (object(block.data['state'] ?? <String, Object?>{})['status'] != null &&
        object(block.data['state'])['status'] != 'open') return Future.value();
    final spec = object(block.data['action']);
    final frozenPayload = object(freeze(payload));
    // Lock synchronously; durable recovery happens before allocating a new ID.
    _set(key, const InteractionState(phase: InteractionPhase.submitting));
    return _single(key, () async {
      ActionRequest? request;
      await updateClientState(persistence, messageId, (saved) {
        request = saved.intents[blockId] ??
            ActionRequest.fromJson({
              'id': nextId(),
              'protocolVersion': '0.1',
              'type': spec['type'],
              'target': spec['target'],
              'payload': frozenPayload,
              'context': {
                'conversationId': message!['conversationId'],
                'messageId': messageId,
                'blockId': blockId
              },
            });
        return saved.copyWith(intents: {...saved.intents, blockId: request!});
      });
      _set(
          key,
          InteractionState(
              phase: InteractionPhase.submitting, request: request));
      await _send(messageId, blockId, request!);
    });
  }

  Future<void> _single(String key, Future<void> Function() work) {
    final existing = _flights[key];
    if (existing != null) return existing;
    final future = Future<void>.microtask(work).whenComplete(() {
      _flights.remove(key);
    });
    _flights[key] = future;
    return future;
  }

  Future<void> retry(String messageId, String blockId) async {
    if (transport == null) return;
    final key = _key(messageId, blockId);
    final request = stateFor(messageId, blockId).request ??
        (await persistence.loadClientState(messageId)).intents[blockId];
    if (request == null) return;
    await _single(key, () => _send(messageId, blockId, request));
  }

  Future<void> retryPending(String messageId) async {
    final saved = await persistence.loadClientState(messageId);
    await Future.wait(
        saved.intents.keys.map((blockId) => retry(messageId, blockId)));
  }

  Future<void> _send(
      String messageId, String blockId, ActionRequest request) async {
    final key = _key(messageId, blockId);
    try {
      final submission = await transport!.submit(request).timeout(timeout);
      if (submission.queued) {
        _set(key,
            InteractionState(phase: InteractionPhase.queued, request: request));
        return;
      }
      final result = submission.result!;
      final error = result['error'];
      if (error is Map<Object?, Object?> && error['code'] == 'unavailable') {
        await _uncertain(key, messageId, request);
        return;
      }
      for (final patch in objects(result['patches'])) {
        store.apply(ActionPatch(
            patch['messageId'] as String,
            patch['blockId'] as String,
            patch['rev'] as int,
            object(patch['patch'])));
      }
      final rejected =
          result['status'] == 'rejected' || result['status'] == 'failed';
      _set(
          key,
          InteractionState(
              phase: rejected
                  ? InteractionPhase.rejected
                  : InteractionPhase.accepted,
              request: request,
              error: error is Map<Object?, Object?>
                  ? error['message'] as String?
                  : null,
              fieldErrors: error is Map<Object?, Object?>
                  ? object(error['fieldErrors'] ?? <String, Object?>{})
                  : {}));
      store.recordDiagnostic('actions', key, {
        'phase': rejected ? 'rejected' : 'accepted',
        'actionId': request.id,
        if (error is Map<Object?, Object?>) 'code': error['code']
      });
      if (result['resume'] is Map<Object?, Object?>) {
        await onResume?.call(object(result['resume'])['messageId'] as String);
      }
      if (result['followUp'] is Map<Object?, Object?>) {
        await onFollowUp
            ?.call(object(result['followUp'])['messageId'] as String);
      }
      // accepted+resume remains submitting until the authoritative stream patch.
      if (result['status'] == 'accepted' && result['resume'] != null) {
        _set(
            key,
            InteractionState(
                phase: InteractionPhase.submitting,
                request: request,
                resumeAccepted: true));
      } else {
        await updateClientState(persistence, messageId, (saved) {
          final intents = {...saved.intents}..remove(blockId);
          return saved.copyWith(intents: intents);
        });
      }
    } catch (_) {
      await _uncertain(key, messageId, request);
    }
  }

  Future<void> _uncertain(
      String key, String messageId, ActionRequest request) async {
    _set(key,
        InteractionState(phase: InteractionPhase.confirming, request: request));
    await onRefresh?.call(messageId);
  }

  Future<void> dispose() => _changes.close();
}

enum ComposerMode { free, locked, answering, submitting }

enum ComposerLockPolicy { answerers, everyone, never }

class InterruptComposerState {
  const InterruptComposerState(
      {this.mode = ComposerMode.free,
      this.message,
      this.block,
      this.queued = false,
      this.error,
      this.closedReason});
  final ComposerMode mode;
  final Message? message;
  final Block? block;
  final bool queued;
  final String? error;
  final String? closedReason;
  String get question => (block?.data['prompt'] ??
      block?.data['title'] ??
      block?.data['purpose'] ??
      '') as String;
}

class InterruptComposerController {
  InterruptComposerController(
      {required this.store,
      required this.interactions,
      required this.conversationId,
      this.lockPolicy = ComposerLockPolicy.answerers,
      bool Function(Message, Block)? canAnswer,
      this.selectInterrupt,
      this.onReveal})
      : canAnswer = canAnswer ?? ((_, __) => true) {
    _storeSub = store.changes.listen((_) => reconcile());
    _actionSub = interactions.changes.listen((_) => reconcile());
    reconcile();
  }
  final BlockStore store;
  final InteractionController interactions;
  final String conversationId;
  final ComposerLockPolicy lockPolicy;
  final bool Function(Message, Block) canAnswer;
  final Message? Function(List<Message>)? selectInterrupt;
  final void Function(String, String)? onReveal;
  late final StreamSubscription<StoreSnapshot> _storeSub;
  late final StreamSubscription<void> _actionSub;
  final _changes =
      StreamController<InterruptComposerState>.broadcast(sync: true);
  DraftPort? _draft;
  InterruptComposerState state = const InterruptComposerState();
  Stream<InterruptComposerState> get changes => _changes.stream;
  void attachDraft(DraftPort draft) {
    _draft = draft;
  }

  void _set(InterruptComposerState next) {
    state = next;
    _changes.add(next);
  }

  void reconcile() {
    final candidates = store.snapshot.messages.values
        .where((m) =>
            m['conversationId'] == conversationId && m.status == 'paused')
        .toList()
      ..sort((a, b) {
        final time =
            (b['createdAt'] as String).compareTo(a['createdAt'] as String);
        return time == 0 ? b.id.compareTo(a.id) : time;
      });
    final message = selectInterrupt?.call(List.unmodifiable(candidates)) ??
        candidates.firstOrNull;
    final interrupt = message?['interrupt'];
    final block = message?.blocks
        .where((b) => b.id == object(interrupt)['blockId'])
        .firstOrNull;
    final open = block != null &&
        _validBlock(block) &&
        (object(block.data['state'] ?? <String, Object?>{})['status'] ??
                'open') ==
            'open';
    if (block == null || !open || message == null) {
      final wasActive = state.mode != ComposerMode.free;
      final previous = store.snapshot.messages[state.message?.id];
      final previousBlock =
          previous?.blocks.where((b) => b.id == state.block?.id).firstOrNull;
      final closed = _validBlock(previousBlock)
          ? object(previousBlock!.data['state'] ?? <String, Object?>{})
          : <String, Object?>{};
      final reason = object(closed['reason'] ?? <String, Object?>{});
      final closedReason = closed['status'] == 'expired'
          ? 'expired'
          : reason['code'] == 'stopped'
              ? 'stopped'
              : const ['cancelled', 'superseded'].contains(closed['status'])
                  ? 'withdrawn'
                  : previous?.status == 'interrupted'
                      ? 'stopped'
                      : 'answered_elsewhere';
      _set(InterruptComposerState(
          closedReason: wasActive ? closedReason : state.closedReason));
      return;
    }
    final eligible =
        interactions.transport != null && canAnswer(message, block);
    final local = interactions.stateFor(message.id, block.id);
    final mode = local.resumeAccepted
        ? ComposerMode.free
        : local.locked
            ? ComposerMode.submitting
            : (state.mode == ComposerMode.answering &&
                    state.message?.id == message.id)
                ? ComposerMode.answering
                : (lockPolicy == ComposerLockPolicy.everyone ||
                        (lockPolicy == ComposerLockPolicy.answerers &&
                            eligible))
                    ? ComposerMode.locked
                    : ComposerMode.free;
    _set(InterruptComposerState(
        mode: mode,
        message: message,
        block: block,
        queued: local.phase == InteractionPhase.queued,
        error: local.error));
  }

  void beginOtherInput() {
    final message = state.message;
    final block = state.block;
    if (message == null ||
        block == null ||
        interactions.transport == null ||
        !canAnswer(message, block) ||
        object(message['interrupt'])['otherInput'] == false) return;
    _set(InterruptComposerState(
        mode: ComposerMode.answering, message: message, block: block));
    _draft?.focus();
  }

  void cancelOtherInput() {
    _set(InterruptComposerState(
        mode: ComposerMode.locked, message: state.message, block: state.block));
  }

  void revealInterrupt() {
    if (state.message != null && state.block != null) {
      onReveal?.call(state.message!.id, state.block!.id);
    }
  }

  Future<void> submitOtherInput(String text) async {
    if (state.mode != ComposerMode.answering ||
        text.trim().isEmpty ||
        text.runes.length > 500) return;
    final message = state.message!;
    final block = state.block!;
    await interactions.submit(message.id, block.id, {'freeText': text});
    final local = interactions.stateFor(message.id, block.id);
    if (local.phase == InteractionPhase.rejected) {
      _draft?.text = text;
      _set(InterruptComposerState(
          mode: ComposerMode.answering,
          message: message,
          block: block,
          error: local.error));
    } else if (local.resumeAccepted ||
        store.snapshot.messages[message.id]?.status != 'paused') {
      _draft?.text = '';
      reconcile();
    }
  }

  Future<void> dispose() async {
    await _storeSub.cancel();
    await _actionSub.cancel();
    await _changes.close();
  }
}
