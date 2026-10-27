import 'model.dart';
import 'ports.dart';
import 'sse.dart';
import 'contracts.dart';

class StreamContractHarness {
  const StreamContractHarness({required this.transport, required this.append});
  final StreamTransport transport;

  /// Publish through the test producer associated with this isolated transport.
  final Future<void> Function(StreamEvent) append;
}

Future<ContractReport> runStreamContractSuite(
    StreamContractHarness harness) async {
  const id = 'contract_stream';
  final failures = <ContractFailure>[];
  try {
    await harness.append(StreamEvent.fromJson({
      'protocolVersion': '0.1',
      'type': 'message.start',
      'messageId': id,
      'seq': 1,
      'message': {
        'id': id,
        'role': 'assistant',
        'createdAt': '2026-10-26T09:30:00Z'
      }
    }));
    final connection = await harness.transport.open(id,
        caps: ClientCapabilities.fromJson({
          'protocolVersions': ['0.1'],
          'blocks': {}
        }));
    await harness.append(StreamEvent.fromJson({
      'protocolVersion': '0.1',
      'type': 'message.end',
      'messageId': id,
      'seq': 2,
      'status': 'complete',
      'rev': 1,
      'blockCount': 0,
      'fallbackText': ''
    }));
    final events = await connection.bytes
        .timeout(const Duration(seconds: 2))
        .transform(const SseDecoder())
        .map(const EventParser().parse)
        .toList();
    final sequences = events.map((e) => e.seq).toList();
    if (!jsonEquals(sequences, [1, 2]))
      throw StateError('handoff lost or duplicated an event');
  } catch (error) {
    failures.add(ContractFailure('handoff_includes_concurrent_end', error));
  }
  return ContractReport(1, List.unmodifiable(failures));
}

/// The producer must deduplicate by request ID and return the same result for
/// retries, including after a lost response. The harness observes its side effect.
class ActionContractHarness {
  const ActionContractHarness(
      {required this.transport,
      required this.effectCount,
      required this.loseNextResponse});
  final ActionTransport transport;
  final Future<int> Function() effectCount;
  final Future<void> Function() loseNextResponse;
}

Future<ContractReport> runActionContractSuite(
    ActionContractHarness harness) async {
  final failures = <ContractFailure>[];
  var checked = 0;
  Future<void> check(String name, Future<void> Function() work) async {
    checked++;
    try {
      await work();
    } catch (error) {
      failures.add(ContractFailure(name, error));
    }
  }

  ActionRequest request(String id) => ActionRequest.fromJson({
        'id': id,
        'protocolVersion': '0.1',
        'type': 'confirmation.respond',
        'target': 'todo.delete',
        'payload': {'outcome': 'confirm'},
        'context': {
          'conversationId': 'contract',
          'messageId': 'contract_message',
          'blockId': 'contract_block'
        },
      });
  await check('action_duplicate_id_is_idempotent', () async {
    final before = await harness.effectCount();
    final first = await harness.transport.submit(request('contract_action_1'));
    final second = await harness.transport.submit(request('contract_action_1'));
    if (first.queued ||
        second.queued ||
        first.result == null ||
        first.result!['actionId'] != 'contract_action_1' ||
        !jsonEquals(first.result!.json, second.result?.json) ||
        await harness.effectCount() != before + 1) {
      throw StateError('duplicate request changed result or repeated effect');
    }
  });
  await check('action_lost_response_retry_is_idempotent', () async {
    final before = await harness.effectCount();
    await harness.loseNextResponse();
    try {
      await harness.transport.submit(request('contract_action_2'));
      throw StateError('harness must lose the response');
    } on ContractResponseLost {
      // The producer applied the action before transport uncertainty.
    }
    final result = await harness.transport.submit(request('contract_action_2'));
    if (result.queued ||
        result.result == null ||
        result.result!['actionId'] != 'contract_action_2' ||
        await harness.effectCount() != before + 1) {
      throw StateError('retry after uncertainty repeated effect');
    }
  });
  return ContractReport(checked, List.unmodifiable(failures));
}

class ContractResponseLost implements Exception {
  const ContractResponseLost();
}
