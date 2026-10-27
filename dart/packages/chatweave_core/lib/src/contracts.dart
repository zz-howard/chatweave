import 'model.dart';
import 'ports.dart';

class ContractFailure {
  const ContractFailure(this.name, this.error);
  final String name;
  final Object error;
}

class ContractReport {
  const ContractReport(this.executed, this.failures);
  final int executed;
  final List<ContractFailure> failures;
  bool get passed => executed > 0 && failures.isEmpty;
}

/// Run against an empty, isolated adapter. Does not depend on package:test.
Future<ContractReport> runContractSuite(ChatWeaveStore store) async {
  final failures = <ContractFailure>[];
  var executed = 0;
  Future<void> check(String name, Future<bool> Function() work) async {
    executed++;
    try {
      if (!await work()) throw StateError('contract failed');
    } catch (error) {
      failures.add(ContractFailure(name, error));
    }
  }

  final provisional = Message.fromJson({
    'id': 'contract_message',
    'conversationId': 'contract_conversation',
    'protocolVersion': '0.1',
    'role': 'assistant',
    'status': 'streaming',
    'rev': 0,
    'lastSeq': 3,
    'createdAt': '2026-10-26T09:30:00Z',
    'blocks': [],
    'fallbackText': ''
  });
  await check('provisional_cursor', () async {
    await store.saveProvisional(provisional, lastSeq: 3);
    return await store.lastSeq(provisional.id) == 3;
  });
  await check('checkpoint_never_rolls_back_seq', () async {
    await store.saveProvisional(
        Message.fromJson({...provisional.json, 'lastSeq': 2}),
        lastSeq: 2);
    return await store.lastSeq(provisional.id) == 3;
  });
  await check('final_rev_wins', () async {
    final finalMessage = Message.fromJson({
      ...provisional.json,
      'status': 'complete',
      'rev': 2
    }..remove('lastSeq'));
    await store.saveFinal(finalMessage);
    await store.saveProvisional(provisional, lastSeq: 4);
    await store.saveFinal(Message.fromJson({...finalMessage.json, 'rev': 1}));
    return (await store.load(provisional.id))?.rev == 2;
  });
  await check('complete_intent_and_stop_marker_roundtrip', () async {
    final request = ActionRequest.fromJson({
      'id': 'contract_action',
      'protocolVersion': '0.1',
      'type': 'choice.select',
      'target': 'weather.select',
      'context': {
        'conversationId': 'contract_conversation',
        'messageId': provisional.id,
        'blockId': 'b1'
      },
      'payload': {
        'selected': ['bj']
      }
    });
    await store.saveClientState(provisional.id,
        ClientState(stopRequested: true, intents: {'b1': request}));
    final restored = await store.loadClientState(provisional.id);
    return restored.stopRequested &&
        restored.intents['b1']?['payload'] is Map<Object?, Object?> &&
        restored.intents['b1']?.id == request.id;
  });
  await check('clear_removes_messages_cursors_intents_and_stop_markers',
      () async {
    await store.clear();
    final state = await store.loadClientState(provisional.id);
    return await store.load(provisional.id) == null &&
        await store.lastSeq(provisional.id) == null &&
        !state.stopRequested &&
        state.intents.isEmpty;
  });
  return ContractReport(executed, List.unmodifiable(failures));
}
