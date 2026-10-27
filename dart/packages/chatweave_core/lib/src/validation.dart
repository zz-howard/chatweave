import 'model.dart';
import 'wire_check.dart';

const builtinTypes = {
  'markdown',
  'metric',
  'metric_group',
  'dataset',
  'time_series',
  'comparison',
  'status',
  'choice',
  'confirmation',
  'form_intent'
};

/// Consumer checks preserve unknown fields and let unknown block types degrade.
void validateBlock(Json b, {Limits limits = const Limits()}) {
  limits.checkBlock(b);
  if (b['id'] is! String ||
      b['type'] is! String ||
      b['schemaVersion'] is! int) {
    throw const ProtocolError('validation_failed');
  }
  if ((b['status'] == 'pending' || b['status'] == 'error') &&
      !b.containsKey('data')) return;
  if (b['data'] is! Map<Object?, Object?>)
    throw const ProtocolError('validation_failed');
  final data = object(b['data']);
  final required = switch (b['type']) {
    'markdown' => ['text'],
    'metric' => ['label', 'value'],
    'metric_group' => ['metrics'],
    'dataset' => ['columns', 'rows'],
    'time_series' => ['series', 'xType'],
    'comparison' => ['subjects', 'attributes', 'values'],
    'status' => ['label', 'state'],
    'choice' => ['prompt', 'options', 'action'],
    'confirmation' => ['title', 'action'],
    'form_intent' => ['fields', 'action'],
    _ => <String>[],
  };
  if (required.any((k) => !data.containsKey(k))) {
    throw const ProtocolError('validation_failed');
  }
  final definition = switch (b['type']) {
    'metric_group' => 'metricGroupData',
    'time_series' => 'timeSeriesData',
    'form_intent' => 'formIntentData',
    _ => '${b['type']}Data',
  };
  if (builtinTypes.contains(b['type']) &&
      b['schemaVersion'] == 1 &&
      !WireCheck(consumer: true)
          .accepts(data, 'content-block.schema.json#/\$defs/$definition')) {
    throw const ProtocolError('validation_failed');
  }
  if (object(b['metadata'] ?? <String, Object?>{})['provenance'] == 'adapter' &&
      b['type'] != 'markdown') throw const ProtocolError('invalid_provenance');
}

void validateMessage(Json m,
    {Limits limits = const Limits(), bool legacySteps = false}) {
  limits.checkMessage(m);
  final blocks = objects(m['blocks']);
  final ids = <Object?>{};
  for (final b in blocks) {
    if (!ids.add(b['id'])) throw const ProtocolError('duplicate_block_id');
    validateBlock(b, limits: limits);
  }
  if (legacySteps) return;
  final steps = objects(m['steps']);
  final seen = <Object?, (Json, int)>{};
  for (final step in steps) {
    if (seen.containsKey(step['id']))
      throw const ProtocolError('duplicate_step_id');
    final parent = step['parentStepId'];
    var depth = 1;
    if (parent != null) {
      final previous = seen[parent];
      if (previous == null || previous.$1['kind'] != 'delegate') {
        throw const ProtocolError('invalid_parent');
      }
      depth = previous.$2 + 1;
      if (const ['running', 'awaiting_user'].contains(step['state']) &&
          previous.$1['state'] != 'running')
        throw const ProtocolError('invalid_parent');
    }
    if (depth > 3) throw const ProtocolError('step_depth');
    if (step['blockId'] != null && !ids.contains(step['blockId'])) {
      throw const ProtocolError('invalid_block_reference');
    }
    seen[step['id']] = (step, depth);
  }
  if (m['status'] == 'paused') {
    final interrupt = object(m['interrupt']);
    final step = seen[interrupt['stepId']]?.$1;
    final block =
        blocks.where((b) => b['id'] == interrupt['blockId']).firstOrNull;
    if (step == null ||
        step['state'] != 'awaiting_user' ||
        step['blockId'] != interrupt['blockId'] ||
        block == null ||
        !const ['choice', 'confirmation', 'form_intent']
            .contains(block['type']) ||
        (object(object(block['data'])['state'] ?? <String, Object?>{})[
                    'status'] ??
                'open') !=
            'open') {
      throw const ProtocolError('invalid_interrupt');
    }
    final allowed = <Object?>{step['id']};
    var current = step;
    while (current['parentStepId'] != null) {
      current = seen[current['parentStepId']]!.$1;
      allowed.add(current['id']);
    }
    if (steps
        .any((s) => s['state'] == 'running' && !allowed.contains(s['id']))) {
      throw const ProtocolError('pause_other_step');
    }
  }
}
