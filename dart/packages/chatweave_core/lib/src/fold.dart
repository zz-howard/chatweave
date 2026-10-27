import 'model.dart';
import 'validation.dart';

bool _active(Object? state) => state == 'running' || state == 'awaiting_user';
Never _fail(String code) => throw ProtocolError(code);

/// Atomic, independent client fold. Unchanged blocks retain their identity.
class FoldState {
  FoldState({
    this.limits = const Limits(),
    this.legacySteps = false,
    this.strictBlocks = false,
  });

  /// Producer conformance mode; consumers retain bad blocks for local fallback.
  final bool strictBlocks;
  final Limits limits;
  final bool legacySteps;
  Json? _message;
  int lastSeq = 0;
  Set<String> _interruptIds = <String>{};
  (int, String)? _answer;

  Message get message {
    final current = _message ?? _fail('missing_start');
    return Message.fromJson({
      ...current,
      if (current['status'] == 'streaming' || current['status'] == 'paused')
        'lastSeq': lastSeq,
    });
  }

  void restore(Message checkpoint, int seq) {
    if (seq < 1 || seq > limits.maxEvents) _fail('invalid_checkpoint');
    if (checkpoint['lastSeq'] != null && checkpoint['lastSeq'] != seq) {
      _fail('snapshot_seq');
    }
    if (strictBlocks) {
      validateMessage(checkpoint.json,
          limits: limits, legacySteps: legacySteps);
    } else {
      limits.checkBytes(checkpoint.json, limits.maxMessageBytes);
    }
    if (!strictBlocks) checkConsumerBlocks(checkpoint, limits: limits);
    _message = {...checkpoint.json}..remove('lastSeq');
    lastSeq = seq;
    _answer = null;
    final interrupt = _message!['interrupt'];
    if (interrupt is Map<Object?, Object?>)
      _interruptIds.add(interrupt['id'] as String);
  }

  bool apply(StreamEvent event) {
    final e = event.json;
    final type = event.type;
    if (type == 'message.activity') {
      limits.checkEvent(e, checkBlockData: strictBlocks);
      if (e.containsKey('seq')) _fail('invalid_event');
      return false;
    }
    final seq = event.seq ?? _fail('missing_seq');
    if (seq < 1) _fail('missing_seq');
    if (type == 'message.snapshot') {
      if (seq < lastSeq) return false;
      final checkpoint = Message.fromJson(object(e['message']));
      if (checkpoint.id != event.messageId) _fail('message_mismatch');
      limits.checkEvent(e, checkBlockData: strictBlocks);
      restore(checkpoint, seq);
      if (legacySteps) _message = {..._message!}..remove('steps');
      return true;
    }
    if (seq <= lastSeq) return false;
    if (seq != lastSeq + 1) _fail('seq_gap');
    if (seq > limits.maxEvents) _fail('limit_exceeded');
    limits.checkEvent(e, checkBlockData: strictBlocks);
    final m = <String, Object?>{...?_message};
    final ids = {..._interruptIds};
    (int, String)? answer;
    if (_message != null && m['id'] != event.messageId) {
      _fail('message_mismatch');
    }
    final blocks = objects(m['blocks']);
    final steps = objects(m['steps']);
    int blockIndex(Object? id) {
      final i = blocks.indexWhere((b) => b['id'] == id);
      return i < 0 ? _fail('unknown_block') : i;
    }

    int stepIndex(Object? id) {
      final i = steps.indexWhere((s) => s['id'] == id);
      return i < 0 ? _fail('unknown_step') : i;
    }

    Json block(Object? id) => blocks[blockIndex(id)];
    Json step(Object? id) => steps[stepIndex(id)];
    final status = m['status'];
    if (type != 'message.start' && _message == null) _fail('missing_start');
    if (status == 'paused') {
      final interrupt = object(m['interrupt']);
      final state =
          object(object(block(interrupt['blockId'])['data'])['state']);
      final allowed = switch (type) {
        'block.patch' => e['blockId'] == interrupt['blockId'] &&
            !e.containsKey('rev') &&
            state['status'] == 'open' &&
            const ['resolved', 'cancelled', 'expired'].contains(
              object(object(object(e['patch'])['data'])['state'])['status'],
            ),
        'message.resumed' => state['status'] == 'resolved',
        'step.finished' => e['state'] == 'cancelled' &&
            const ['cancelled', 'expired'].contains(state['status']),
        'message.end' => e['status'] == 'interrupted' &&
            const ['cancelled', 'expired'].contains(state['status']),
        _ => false,
      };
      if (!allowed) _fail('paused_event');
    }
    if (_message != null &&
        status != 'streaming' &&
        status != 'paused' &&
        type != 'block.patch') _fail('message_ended');
    if (legacySteps && (type == 'step.started' || type == 'step.finished')) {
      lastSeq = seq;
      _answer = null;
      return true;
    }
    switch (type) {
      case 'message.start':
        if (_message != null) _fail('duplicate_start');
        m.addAll(object(e['message']));
        if (m['id'] != event.messageId) _fail('message_mismatch');
        m.addAll({
          'protocolVersion': e['protocolVersion'],
          'status': 'streaming',
          'rev': 0,
          'fallbackText': '',
          'blocks': <Object?>[]
        });
      case 'block.start':
        if (blocks.any((b) => b['id'] == e['blockId'])) {
          _fail('duplicate_block_id');
        }
        if (e['index'] != blocks.length) _fail('block_index');
        if (e['blockType'] == 'markdown' &&
            blocks.any(
              (b) => b['type'] == 'markdown' && b['status'] == 'pending',
            )) _fail('multiple_markdown');
        blocks.add({
          'id': e['blockId'],
          'type': e['blockType'],
          'schemaVersion': e['schemaVersion'],
          'status': 'pending',
          'fallbackText': '',
          if (e['blockType'] == 'markdown') 'data': {'text': ''}
        });
        m['blocks'] = blocks;
      case 'block.delta':
        final b = {...block(e['blockId'])};
        if (b['status'] != 'pending') _fail('block_ended');
        if (b['type'] != 'markdown') _fail('invalid_delta');
        b['data'] = {
          ...object(b['data']),
          'text': '${object(b['data'])['text']}${object(e['delta'])['text']}'
        };
        blocks[blockIndex(e['blockId'])] = b;
        m['blocks'] = blocks;
      case 'block.data':
        final b = {...block(e['blockId'])};
        if (b['status'] != 'pending') _fail('block_ended');
        if (b.containsKey('data')) _fail('duplicate_block_data');
        if (b['type'] == 'markdown') _fail('invalid_data');
        b.addAll({
          'data': e['data'],
          'fallbackText': e['fallbackText'],
          if (e.containsKey('metadata')) 'metadata': e['metadata']
        });
        blocks[blockIndex(e['blockId'])] = b;
        m['blocks'] = blocks;
      case 'block.patch':
        final i = blockIndex(e['blockId']);
        final rev = m['rev'] as int;
        if (rev > 0) {
          final next = e['rev'] as int? ?? _fail('missing_rev');
          if (next <= rev) {
            lastSeq = seq;
            _answer = null;
            return true;
          }
          if (next != rev + 1) _fail('rev_gap');
          m['rev'] = next;
        } else if (e.containsKey('rev')) {
          _fail('unexpected_rev');
        }
        blocks[i] = object(mergePatch(blocks[i], e['patch']));
        if (status == 'paused' &&
            object(object(blocks[i]['data'])['state'])['status'] ==
                'resolved') {
          answer = (seq, blocks[i]['id'] as String);
        }
        m['blocks'] = blocks;
      case 'block.end':
        final i = blockIndex(e['blockId']);
        final b = {...blocks[i]};
        if (b['status'] != 'pending') _fail('block_ended');
        if (e['status'] == 'error') {
          b['status'] = 'error';
          final error = e['error'];
          if (error is Map<Object?, Object?> && error['message'] is String) {
            b['reason'] = error['message'];
          }
        } else {
          b.remove('status');
        }
        if (e.containsKey('fallbackText'))
          b['fallbackText'] = e['fallbackText'];
        if (b['type'] == 'markdown' &&
            b['fallbackText'] == '' &&
            !b.containsKey('status')) b.remove('fallbackText');
        if (strictBlocks && !b.containsKey('data') && b['status'] != 'error') {
          _fail('validation_failed');
        }
        blocks[i] = b;
        m['blocks'] = blocks;
      case 'step.started':
        if (steps.any((s) => s['id'] == e['stepId']))
          _fail('duplicate_step_id');
        if (steps.length >= 64) _fail('limit_exceeded');
        final parent = e['parentStepId'];
        if (parent != null) {
          var current = steps.where((s) => s['id'] == parent).firstOrNull;
          if (current == null ||
              current['kind'] != 'delegate' ||
              current['state'] != 'running') _fail('invalid_parent');
          var depth = 2;
          var node = current;
          while (node['parentStepId'] != null) {
            depth++;
            node = step(node['parentStepId']);
          }
          if (depth > 3) _fail('step_depth');
        }
        steps.add({
          'id': e['stepId'],
          'label': e['label'],
          'state': 'running',
          if (e.containsKey('kind')) 'kind': e['kind'],
          if (parent != null) 'parentStepId': parent
        });
        m['steps'] = steps;
      case 'step.finished':
        final i = stepIndex(e['stepId']);
        if (!_active(steps[i]['state'])) _fail('step_ended');
        if (steps.any(
            (s) => s['parentStepId'] == e['stepId'] && _active(s['state'])))
          _fail('unfinished_child');
        steps[i] = {
          ...steps[i],
          'state': e['state'],
          'durationMs': e['durationMs'],
          if (e.containsKey('summary')) 'summary': e['summary']
        };
        m['steps'] = steps;
      case 'message.paused':
        if (status != 'streaming') _fail('already_paused');
        if (blocks.any((b) => b['status'] == 'pending'))
          _fail('pause_open_block');
        if (e['blockCount'] != blocks.length) _fail('block_count');
        final interrupt = object(e['interrupt']);
        final id = interrupt['id'] as String;
        if (!ids.add(id)) _fail('duplicate_interrupt_id');
        final b = block(interrupt['blockId']);
        final state = object(object(b['data'])['state'] ?? <String, Object?>{});
        if (!const ['choice', 'confirmation', 'form_intent']
                .contains(b['type']) ||
            (state['status'] ?? 'open') != 'open') _fail('invalid_interrupt');
        if (!legacySteps) {
          final i = stepIndex(interrupt['stepId']);
          if (steps[i]['state'] != 'running') _fail('invalid_interrupt');
          final ancestors = <Object?>{steps[i]['id']};
          var current = steps[i];
          while (current['parentStepId'] != null) {
            current = step(current['parentStepId']);
            ancestors.add(current['id']);
          }
          if (steps
              .any((s) => _active(s['state']) && !ancestors.contains(s['id'])))
            _fail('pause_other_step');
          steps[i] = {
            ...steps[i],
            'state': 'awaiting_user',
            'blockId': interrupt['blockId']
          };
          m['steps'] = steps;
        }
        m.addAll({
          'status': 'paused',
          'interrupt': interrupt,
          'fallbackText': e['fallbackText']
        });
      case 'message.resumed':
        final interrupt = object(m['interrupt']);
        if (status != 'paused' || interrupt['id'] != e['interruptId']) {
          _fail('interrupt_mismatch');
        }
        if (_answer != (seq - 1, interrupt['blockId'])) _fail('resume_order');
        if (!legacySteps) {
          final i = stepIndex(interrupt['stepId']);
          steps[i] = {...steps[i], 'state': 'running'};
          m['steps'] = steps;
        }
        m['status'] = 'streaming';
        m.remove('interrupt');
      case 'message.end':
        if (blocks.any((b) => b['status'] == 'pending'))
          _fail('unfinished_block');
        if (steps.any((s) => _active(s['state']))) _fail('unfinished_step');
        if (e['blockCount'] != blocks.length) _fail('block_count');
        if (e['rev'] != 1) _fail('invalid_rev');
        m.addAll({
          'status': e['status'],
          'rev': e['rev'],
          'fallbackText': e['fallbackText'],
          if (e.containsKey('ts')) 'completedAt': e['ts']
        });
        m.remove('interrupt');
    }
    if (objects(m['blocks']).length > 64) _fail('limit_exceeded');
    if (strictBlocks) {
      for (final b in objects(m['blocks'])) {
        validateBlock(b, limits: limits);
      }
    }
    if (strictBlocks) {
      limits.checkMessage(m);
    } else {
      limits.checkBytes(m, limits.maxMessageBytes);
    }
    _message = object(freeze(m));
    if (!strictBlocks) checkConsumerBlocks(message, limits: limits);
    _interruptIds = ids;
    _answer = answer;
    lastSeq = seq;
    return true;
  }
}

Message fold(
  Iterable<StreamEvent> events, {
  Limits limits = const Limits(),
  bool legacySteps = false,
  bool strictBlocks = false,
}) {
  final state = FoldState(
      limits: limits, legacySteps: legacySteps, strictBlocks: strictBlocks);
  for (final event in events) {
    state.apply(event);
  }
  return state.message;
}
