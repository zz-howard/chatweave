import 'package:chatweave_core/chatweave_core.dart';
import 'package:chatweave_core/testing.dart';
import 'package:test/test.dart';

void main() {
  for (final broken in [false, true]) {
    test('action_contract_${broken ? 'rejects_bad_adapter' : 'passes'}',
        () async {
      final adapter = ContractActions(broken);
      final report = await runActionContractSuite(ActionContractHarness(
          transport: adapter,
          effectCount: () async => adapter.effects,
          loseNextResponse: () async {
            adapter.lose = true;
          }));
      expect(report.failures.isEmpty, !broken);
      expect(report.executed, 2);
    });
  }

  test('contract_suite_rejects_zero_cases', () {
    expect(const ContractReport(0, []).passed, isFalse);
  });
  test('memory_transport_passes_stream_contract_suite', () async {
    final transport = MemoryTransport();
    final report = await runStreamContractSuite(StreamContractHarness(
        transport: transport,
        append: (event) async {
          transport.append(event);
        }));
    expect(report.passed, isTrue);
    await transport.dispose();
  });
  test('stream_contract_suite_rejects_lost_handoff', () async {
    final transport = ScriptedTransport(connections: [
      (_, __) async => StreamConnection(
          status: 200,
          headers: const {'ChatWeave-Protocol': '0.1'},
          bytes: const Stream<List<int>>.empty())
    ]);
    final report = await runStreamContractSuite(
        StreamContractHarness(transport: transport, append: (_) async {}));
    expect(report.passed, isFalse);
    expect(report.failures.single.name, 'handoff_includes_concurrent_end');
  });
  test('contract_handoff_includes_concurrent_end', () async {
    final transport = MemoryTransport();
    final start = StreamEvent.fromJson({
      'protocolVersion': '0.1',
      'type': 'message.start',
      'messageId': 'm',
      'seq': 1,
      'message': {
        'id': 'm',
        'role': 'assistant',
        'createdAt': '2026-10-26T09:30:00Z'
      }
    });
    final end = StreamEvent.fromJson({
      'protocolVersion': '0.1',
      'type': 'message.end',
      'messageId': 'm',
      'seq': 2,
      'status': 'complete',
      'rev': 1,
      'blockCount': 0,
      'fallbackText': ''
    });
    transport.append(start);
    final connection = await transport.open('m',
        caps: ClientCapabilities.fromJson({
          'protocolVersions': ['0.1'],
          'blocks': {}
        }));
    // The end arrives after open and before the consumer starts reading.
    transport.append(end);
    final events = await connection.bytes
        .transform(const SseDecoder())
        .map(const EventParser().parse)
        .toList();
    expect(events.map((e) => e.seq), [1, 2]);
    expect(fold(events).status, 'complete');
    await transport.dispose();
  });
}

class ContractActions implements ActionTransport {
  ContractActions(this.broken);
  final bool broken;
  var effects = 0;
  var lose = false;
  final results = <Object?, ActionSubmission>{};
  @override
  Future<ActionSubmission> submit(ActionRequest request) async {
    var result = results[request['id']];
    if (result == null || broken) {
      effects++;
      result = ActionSubmission.result(ActionResult.fromJson({
        'actionId': request['id'],
        'status': 'completed',
      }));
      results[request['id']] = result;
    }
    if (lose) {
      lose = false;
      throw const ContractResponseLost();
    }
    return result;
  }
}
