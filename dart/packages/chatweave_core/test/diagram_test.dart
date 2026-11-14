import 'package:chatweave_core/chatweave_core.dart';
import 'package:chatweave_core/src/wire_check.dart';
import 'package:test/test.dart';

void main() {
  test('diagram_defaults_and_group_getters_preserve_wire_values', () {
    final minimal = DiagramData({
      'steps': [
        {
          'nodes': [
            {'label': 'First'},
          ],
        },
        {
          'nodes': [
            {'label': 'Second'},
          ],
        },
      ],
    });
    expect(minimal.direction, 'vertical');
    expect(minimal.groups, isEmpty);
    expect(minimal.steps.first.id, isNull);
    expect(minimal.steps.first.link, isNull);
    final grouped = DiagramData({
      'direction': 'horizontal',
      'steps': [
        {
          'id': 'first',
          'nodes': [
            {'label': 'First'},
          ],
          'link': <String, Object?>{},
        },
        {
          'id': 'second',
          'nodes': [
            {'label': 'Second'},
          ],
        },
      ],
      'groups': [
        {'label': 'Together', 'from': 'first', 'to': 'second'},
      ],
    });
    expect(grouped.direction, 'horizontal');
    expect(grouped.steps.first.link!.arrow, 'forward');
    expect(grouped.groups.single.label, 'Together');
    expect(grouped.groups.single.from, 'first');
    expect(grouped.groups.single.to, 'second');
  });

  test('diagram_lifecycle_allows_absent_data_but_checks_present_data', () {
    for (final status in ['pending', 'error']) {
      final block = <String, Object?>{
        'id': 'diagram',
        'type': 'diagram',
        'schemaVersion': 1,
        'status': status,
        'fallbackText': 'Waiting for diagram',
      };
      expect(() => validateBlock(block), returnsNormally);
      expect(
        () => validateBlock({...block, 'data': <String, Object?>{}}),
        throwsA(isA<ProtocolError>()),
      );
    }
  });

  test('diagram_typed_data_preserves_optional_wire_fields', () {
    final json = <String, Object?>{
      'title': 'Message flow',
      'summary': 'A message source',
      'steps': [
        {
          'id': 'source',
          'nodes': [
            {
              'label': 'Client',
              'detail': 'Sends a message',
              'icon': 'smartphone',
              'highlight': false,
              'futureField': null,
            },
          ],
        },
      ],
    };
    final parsed = BlockData.fromJson('diagram', json) as DiagramData;
    expect(parsed.title, 'Message flow');
    expect(parsed.summary, 'A message source');
    expect(parsed.steps.single.id, 'source');
    final node = parsed.steps.single.nodes.single;
    expect(node.label, 'Client');
    expect(node.detail, 'Sends a message');
    expect(node.icon, 'smartphone');
    expect(node.highlight, isFalse);
    expect(parsed.toJson(), json);
    expect(() => node.json['label'] = 'Changed', throwsUnsupportedError);
    final minimal = DiagramNode({'label': 'Client'});
    expect(minimal.detail, isNull);
    expect(minimal.icon, isNull);
    expect(minimal.highlight, isNull);
    expect(minimal.toJson(), {'label': 'Client'});
  });

  test('diagram_node_schema_checks_field_bounds_and_types', () {
    final check = WireCheck();
    const ref = r'content-block.schema.json#/$defs/diagramNode';
    for (final value in <Json>[
      {'label': 'A'},
      {
        'label': 'a' * 40,
        'detail': 'd' * 120,
        'icon': 'a' * 32,
        'highlight': true,
      },
      {'label': 'Client', 'detail': '', 'icon': 'future-icon'},
    ]) {
      expect(check.accepts(value, ref), isTrue, reason: '$value');
    }
    for (final value in <Json>[
      {},
      {'label': ''},
      {'label': 'a' * 41},
      {'label': true},
      {'label': 'A', 'detail': 'd' * 121},
      {'label': 'A', 'detail': false},
      {'label': 'A', 'highlight': 'true'},
      {'label': 'A', 'icon': ''},
      {'label': 'A', 'icon': 'Bot'},
      {'label': 'A', 'icon': 'a' * 33},
      {'label': 'A', 'icon': 'two words'},
      {'label': 'A', 'icon': 'under_score'},
      {'label': 'A', 'extra': true},
    ]) {
      expect(check.accepts(value, ref), isFalse, reason: '$value');
    }
    expect(
      WireCheck(consumer: true)
          .accepts({'label': 'A', 'futureField': null}, ref),
      isTrue,
    );
  });

  test('diagram_link_schema_checks_arrow_and_label', () {
    final check = WireCheck();
    const ref = r'content-block.schema.json#/$defs/diagramLink';
    expect(check.accepts(<String, Object?>{}, ref), isTrue);
    expect(DiagramLink(<String, Object?>{}).arrow, 'forward');
    for (final arrow in ['forward', 'both', 'none']) {
      expect(check.accepts({'arrow': arrow}, ref), isTrue);
      expect(check.accepts({'arrow': arrow, 'label': 'a' * 40}, ref), isTrue);
      final link = DiagramLink({'arrow': arrow, 'label': 'Connection'});
      expect(link.arrow, arrow);
      expect(link.label, 'Connection');
    }
    for (final value in <Json>[
      {'arrow': 'backward'},
      {'arrow': false},
      {'arrow': 'forward', 'label': 'a' * 41},
      {'arrow': 'forward', 'label': false},
      {'arrow': 'forward', 'target': 'individual-node'},
    ]) {
      expect(check.accepts(value, ref), isFalse, reason: '$value');
    }
  });
}
