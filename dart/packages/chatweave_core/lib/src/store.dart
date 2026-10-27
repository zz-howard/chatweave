import 'dart:async' as async;

import 'fold.dart';
import 'model.dart';

sealed class StoreEvent {
  const StoreEvent();
}

class ApplyStream extends StoreEvent {
  const ApplyStream(this.event);
  final StreamEvent event;
}

class SyncMessage extends StoreEvent {
  const SyncMessage(this.message);
  final Message message;
}

class ActionPatch extends StoreEvent {
  const ActionPatch(this.messageId, this.blockId, this.rev, this.patch);
  final String messageId;
  final String blockId;
  final int rev;
  final Json patch;
}

class StoreSnapshot {
  StoreSnapshot(Map<String, Message> messages, Map<String, int> cursors)
      : messages = Map.unmodifiable(messages),
        cursors = Map.unmodifiable(cursors);
  final Map<String, Message> messages;
  final Map<String, int> cursors;
}

class BlockStore {
  BlockStore({this.ringCapacity = 50});
  final int ringCapacity;
  final _folds = <String, FoldState>{};
  final _activity = <String, Json>{};
  final _ring = <Json>[];
  final _diagnostics = <String, Map<String, Json>>{};
  void recordDiagnostic(String kind, String id, Json metadata) {
    final safe = <String, Object?>{};
    for (final key in [
      'trigger',
      'round',
      'phase',
      'actionId',
      'blockId',
      'seq',
      'code'
    ]) {
      if (metadata.containsKey(key)) safe[key] = metadata[key];
    }
    _diagnostics.putIfAbsent(kind, () => <String, Json>{})[id] =
        object(freeze(safe));
  }

  final _changes = async.StreamController<StoreSnapshot>.broadcast(sync: true);
  StoreSnapshot _snapshot = StoreSnapshot({}, {});
  StoreSnapshot get snapshot => _snapshot;
  async.Stream<StoreSnapshot> get changes => _changes.stream;
  Json? activityFor(String id) => _activity[id];

  StoreSnapshot apply(StoreEvent event) {
    final messages = {..._snapshot.messages};
    final cursors = {..._snapshot.cursors};
    String id;
    String type;
    switch (event) {
      case ApplyStream(:final event):
        id = event.messageId;
        type = event.type;
        if (type == 'message.activity') {
          _activity[id] = object(freeze(event['activity']));
          _changes.add(_snapshot);
          return _snapshot;
        }
        if ((messages[id]?.rev ?? 0) > 0 &&
            type != 'block.patch' &&
            type != 'message.snapshot') return _snapshot;
        final state = _folds.putIfAbsent(id, FoldState.new);
        if (!state.apply(event)) return _snapshot;
        final candidate = state.message;
        if (cursors[id] == state.lastSeq &&
            jsonEquals(messages[id]?.json, candidate.json)) return _snapshot;
        messages[id] = candidate;
        cursors[id] = state.lastSeq;
        _activity.remove(id);
      case SyncMessage(:final message):
        id = message.id;
        type = 'sync';
        final old = messages[id];
        if (old != null &&
            (message.rev < old.rev ||
                (message.rev == 0 &&
                    (message['lastSeq'] as int? ?? 0) < (cursors[id] ?? 0))))
          return _snapshot;
        if (old != null && jsonEquals(old.json, message.json)) {
          return _snapshot;
        }
        messages[id] = message;
        final seq = message['lastSeq'] as int? ?? cursors[id];
        if (seq != null && seq > 0) {
          cursors[id] = seq;
          _folds[id] = FoldState()..restore(message, seq);
        }
        _activity.remove(id);
      case ActionPatch(
          :final messageId,
          :final blockId,
          :final rev,
          :final patch
        ):
        id = messageId;
        type = 'action.patch';
        final old = messages[id];
        if (old == null) throw const ProtocolError('unknown_message');
        if (rev <= old.rev) return _snapshot;
        if (rev != old.rev + 1) throw const ProtocolError('rev_gap');
        var found = false;
        final blocks = old.blocks.map((b) {
          if (b.id != blockId) return b.json;
          found = true;
          final updated = object(mergePatch(b.json, patch));
          return updated;
        }).toList();
        if (!found) throw const ProtocolError('unknown_block');
        final next =
            Message.fromJson({...old.json, 'rev': rev, 'blocks': blocks});
        const Limits().checkBytes(next.json, const Limits().maxMessageBytes);
        messages[id] = next;
        final seq = cursors[id];
        if (seq != null) _folds[id] = FoldState()..restore(next, seq);
    }
    _ring.add(object(freeze({
      'messageId': id,
      'type': type,
      'seq': cursors[id],
      'rev': messages[id]?.rev
    })));
    while (_ring.length > ringCapacity) {
      _ring.removeAt(0);
    }
    _snapshot = StoreSnapshot(messages, cursors);
    _changes.add(_snapshot);
    return _snapshot;
  }

  Json inspect({bool includeContent = false}) => object(freeze({
        'messages': snapshot.messages.values
            .map((m) => includeContent
                ? m.json
                : {
                    'id': m.id,
                    'status': m.status,
                    'rev': m.rev,
                    'seq': snapshot.cursors[m.id],
                    'blocks': m.blocks
                        .map((b) =>
                            {'id': b.id, 'type': b.type, 'status': b['status']})
                        .toList(),
                  })
            .toList(),
        'events': _ring,
        'diagnostics': _diagnostics,
      }));

  async.Future<void> dispose() => _changes.close();
}

/// Local display state survives widget recycling and is never serialized on wire.
class ProcessState {
  final _expanded = <String, bool>{};
  bool expanded(Message message, {String? stepId}) =>
      _expanded['${message.id}/${stepId ?? ''}'] ??
      (stepId == null &&
          (message.status == 'streaming' || message.status == 'paused'));
  void setExpanded(String messageId, bool value, {String? stepId}) {
    _expanded['$messageId/${stepId ?? ''}'] = value;
  }
}
