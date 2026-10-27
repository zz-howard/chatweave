import 'package:chatweave_core/chatweave_core.dart';
import 'package:chatweave_core/testing.dart';
import 'package:test/test.dart';

Message paused(String id,
        {String createdAt = '2026-10-26T09:30:00Z', bool otherInput = true}) =>
    Message.fromJson({
      'id': id,
      'conversationId': 'c',
      'protocolVersion': '0.1',
      'status': 'paused',
      'rev': 0,
      'lastSeq': 6,
      'role': 'assistant',
      'createdAt': createdAt,
      'fallbackText': '删除待办？',
      'blocks': [
        {
          'id': 'card',
          'type': 'confirmation',
          'schemaVersion': 1,
          'fallbackText': '删除待办？',
          'data': {
            'title': '删除待办？',
            'severity': 'normal',
            'action': {'type': 'confirmation.respond', 'target': 'todo.delete'},
            'state': {'status': 'open'}
          }
        }
      ],
      'steps': [
        {
          'id': 'step',
          'label': '删除待办',
          'state': 'awaiting_user',
          'blockId': 'card'
        }
      ],
      'interrupt': {
        'id': 'interrupt_$id',
        'stepId': 'step',
        'blockId': 'card',
        'reason': 'confirmation',
        'otherInput': otherInput
      },
    });

class Draft implements DraftPort {
  @override
  String text = '原来的草稿';
  int focuses = 0;
  @override
  void focus() {
    focuses++;
  }
}

void main() {
  test('paused_fixture_is_valid', () => validateMessage(paused('m').json));
  test('manual_process_expansion_survives_completion_and_reconstruction', () {
    final display = ProcessState();
    final active =
        Message.fromJson({...paused('m').json, 'status': 'streaming'});
    display.setExpanded('m', false);
    display.setExpanded('m', true);
    final complete =
        Message.fromJson({...active.json, 'status': 'complete', 'rev': 1}
          ..remove('interrupt')
          ..remove('lastSeq'));
    expect(display.expanded(complete), isTrue);
    expect(display.expanded(Message.fromJson(complete.toJson())), isTrue);
    expect(ProcessState().expanded(complete), isFalse);
  });
  test('composer_lock_answer_cancel_preserves_draft', () {
    final store = BlockStore()..apply(SyncMessage(paused('m')));
    final interactions = InteractionController(
        maxAutomaticRetries: 0,
        store: store,
        persistence: MemoryStore(),
        nextId: () => 'a',
        transport: ScriptedTransport(connections: []));
    final controller = InterruptComposerController(
        store: store, interactions: interactions, conversationId: 'c');
    final draft = Draft();
    controller.attachDraft(draft);
    expect(controller.state.mode, ComposerMode.locked);
    controller.beginOtherInput();
    expect(controller.state.mode, ComposerMode.answering);
    expect(draft.focuses, 1);
    draft.text = '先别删';
    controller.cancelOtherInput();
    expect(controller.state.mode, ComposerMode.locked);
    expect(draft.text, '先别删');
    controller.beginOtherInput();
    expect(draft.text, '先别删');
  });
  test('other_input_false_blocks_entry', () {
    final store = BlockStore()
      ..apply(SyncMessage(paused('m', otherInput: false)));
    final interactions = InteractionController(
        maxAutomaticRetries: 0,
        store: store,
        persistence: MemoryStore(),
        nextId: () => 'a',
        transport: ScriptedTransport(connections: []));
    final controller = InterruptComposerController(
        store: store, interactions: interactions, conversationId: 'c');
    controller.beginOtherInput();
    expect(controller.state.mode, ComposerMode.locked);
  });
  test('multiple_interrupts_choose_latest_creation_then_id_and_allow_hook', () {
    final store = BlockStore()
      ..apply(SyncMessage(paused('a')))
      ..apply(SyncMessage(paused('b')))
      ..apply(SyncMessage(paused('c', createdAt: '2026-10-25T09:30:00Z')));
    final interactions = InteractionController(
        maxAutomaticRetries: 0,
        store: store,
        persistence: MemoryStore(),
        nextId: () => 'a',
        transport: ScriptedTransport(connections: []));
    final controller = InterruptComposerController(
        store: store, interactions: interactions, conversationId: 'c');
    expect(controller.state.message?.id, 'b');
    final custom = InterruptComposerController(
        store: store,
        interactions: interactions,
        conversationId: 'c',
        selectInterrupt: (messages) => messages.last);
    expect(custom.state.message?.id, 'c');
  });
  for (final policy in ComposerLockPolicy.values) {
    test('composer_lock_policy_${policy.name}', () {
      final store = BlockStore()..apply(SyncMessage(paused('m')));
      final interactions = InteractionController(
          maxAutomaticRetries: 0,
          store: store,
          persistence: MemoryStore(),
          nextId: () => 'a');
      final controller = InterruptComposerController(
          store: store,
          interactions: interactions,
          conversationId: 'c',
          lockPolicy: policy);
      expect(
          controller.state.mode,
          policy == ComposerLockPolicy.everyone
              ? ComposerMode.locked
              : ComposerMode.free);
    });
  }
  for (final reason in [
    'expired',
    'stopped',
    'withdrawn',
    'answered_elsewhere'
  ]) {
    test('composer_closed_$reason', () async {
      final store = BlockStore()..apply(SyncMessage(paused('m')));
      final persistence = MemoryStore();
      final interactions = InteractionController(
          maxAutomaticRetries: 0,
          store: store,
          persistence: persistence,
          nextId: () => 'a',
          transport: ScriptedTransport(connections: []));
      final controller = InterruptComposerController(
          store: store, interactions: interactions, conversationId: 'c');
      final draft = Draft();
      controller.attachDraft(draft);
      controller.beginOtherInput();
      final original = paused('m');
      final b = original.blocks.single;
      store.apply(SyncMessage(Message.fromJson({
        ...original.json,
        'status': reason == 'answered_elsewhere' ? 'complete' : 'interrupted',
        'rev': 1,
        'steps': [
          {
            ...original.steps.single.json,
            'state': reason == 'answered_elsewhere' ? 'succeeded' : 'cancelled',
            'durationMs': 0,
          }
        ],
        'blocks': [
          {
            ...b.json,
            'data': {
              ...b.data,
              'state': {
                'status': reason == 'expired'
                    ? 'expired'
                    : reason == 'answered_elsewhere'
                        ? 'resolved'
                        : 'cancelled',
                if (reason == 'answered_elsewhere') ...{
                  'resolvedAt': '2026-10-26T09:31:00Z',
                  'outcome': 'confirm',
                },
                if (reason == 'stopped') 'reason': {'code': 'stopped'},
                if (reason == 'withdrawn') 'reason': {'code': 'withdrawn'},
              }
            }
          }
        ],
      }
        ..remove('interrupt')
        ..remove('lastSeq'))));
      validateMessage(store.snapshot.messages['m']!.json);
      expect(controller.state.mode, ComposerMode.free);
      expect(controller.state.closedReason, reason);
      expect(draft.text, '原来的草稿');
      await controller.dispose();
      await interactions.dispose();
      await persistence.dispose();
      await store.dispose();
    });
  }
  for (final queued in [false, true]) {
    test('composer_${queued ? 'queued' : 'rejected_restores_text'}', () async {
      final store = BlockStore()..apply(SyncMessage(paused('m')));
      final persistence = MemoryStore();
      final transport = ScriptedTransport(connections: [], actions: [
        (_) async => queued
            ? const ActionSubmission.queued()
            : ActionSubmission.result(ActionResult.fromJson({
                'status': 'rejected',
                'error': {'code': 'validation_failed', 'message': '请重新回答'},
              })),
      ]);
      final interactions = InteractionController(
          maxAutomaticRetries: 0,
          store: store,
          persistence: persistence,
          nextId: () => 'a',
          transport: transport);
      final controller = InterruptComposerController(
          store: store, interactions: interactions, conversationId: 'c');
      final draft = Draft();
      controller.attachDraft(draft);
      controller.beginOtherInput();
      await controller.submitOtherInput('先保留');
      expect(controller.state.mode,
          queued ? ComposerMode.submitting : ComposerMode.answering);
      expect(controller.state.queued, queued);
      if (!queued) {
        expect(draft.text, '先保留');
        expect(controller.state.error, '请重新回答');
      }
      expect(transport.requests.single['payload'], {'freeText': '先保留'});
      await controller.dispose();
      await interactions.dispose();
      await persistence.dispose();
      await store.dispose();
    });
  }
  test('closed_elsewhere_keeps_draft', () {
    final store = BlockStore()..apply(SyncMessage(paused('m')));
    final interactions = InteractionController(
        maxAutomaticRetries: 0,
        store: store,
        persistence: MemoryStore(),
        nextId: () => 'a',
        transport: ScriptedTransport(connections: []));
    final controller = InterruptComposerController(
        store: store, interactions: interactions, conversationId: 'c');
    final draft = Draft();
    controller.attachDraft(draft);
    controller.beginOtherInput();
    final current = paused('m');
    store.apply(SyncMessage(Message.fromJson({
      ...current.json,
      'status': 'interrupted',
      'rev': 1,
      'steps': [
        {...current.steps.single.json, 'state': 'cancelled', 'durationMs': 0}
      ],
      'blocks': [
        {
          ...current.blocks.single.json,
          'data': {
            ...current.blocks.single.data,
            'state': {
              'status': 'cancelled',
              'reason': {'code': 'stopped'},
            }
          }
        }
      ],
    }
      ..remove('interrupt')
      ..remove('lastSeq'))));
    validateMessage(store.snapshot.messages['m']!.json);
    expect(controller.state.mode, ComposerMode.free);
    expect(controller.state.closedReason, 'stopped');
    expect(draft.text, '原来的草稿');
  });
}
