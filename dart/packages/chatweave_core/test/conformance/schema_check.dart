import 'dart:convert';
import 'dart:io';

import 'package:chatweave_core/chatweave_core.dart';

/// Test-only evaluator for the vocabulary used by the repository's schemas.
/// It never loads references over the network.
class SchemaCheck {
  SchemaCheck(this.directory);
  final Directory directory;
  final _documents = <String, Object?>{};
  Object? _load(String file) => _documents.putIfAbsent(file, () {
        final document =
            jsonDecode(File('${directory.path}/$file').readAsStringSync());
        assertSupported(document);
        return document;
      });

  static const supportedKeywords = {
    r'$schema',
    r'$id',
    r'$ref',
    r'$defs',
    r'$comment',
    'title',
    'description',
    'default',
    'type',
    'const',
    'enum',
    'allOf',
    'anyOf',
    'oneOf',
    'not',
    'if',
    'then',
    'else',
    'minLength',
    'maxLength',
    'pattern',
    'format',
    'minimum',
    'maximum',
    'exclusiveMinimum',
    'minItems',
    'maxItems',
    'items',
    'uniqueItems',
    'contains',
    'minContains',
    'maxContains',
    'required',
    'maxProperties',
    'properties',
    'propertyNames',
    'additionalProperties',
    'unevaluatedProperties',
  };

  void assertSupported(Object? raw) {
    if (raw is bool) return;
    final schema = object(raw);
    for (final key in schema.keys) {
      if (!supportedKeywords.contains(key)) {
        throw UnsupportedError('Unsupported schema keyword: $key');
      }
    }
    for (final key in [r'$defs', 'properties']) {
      for (final child in object(schema[key] ?? <String, Object?>{}).values) {
        assertSupported(child);
      }
    }
    for (final key in ['allOf', 'anyOf', 'oneOf']) {
      for (final child in schema[key] as List<Object?>? ?? []) {
        assertSupported(child);
      }
    }
    for (final key in [
      'not',
      'if',
      'then',
      'else',
      'items',
      'contains',
      'propertyNames',
      'additionalProperties',
      'unevaluatedProperties'
    ]) {
      if (schema.containsKey(key)) assertSupported(schema[key]);
    }
    if (schema['format'] != null &&
        !const ['date', 'date-time', 'uri'].contains(schema['format'])) {
      throw UnsupportedError('Unsupported format: ${schema['format']}');
    }
  }

  void assertRepositorySupported() {
    for (final file in directory.listSync().whereType<File>()) {
      if (file.path.endsWith('.schema.json')) {
        assertSupported(jsonDecode(file.readAsStringSync()));
      }
    }
  }

  bool accepts(Object? value, String reference) {
    final parts = reference.split('#');
    final file = parts.first;
    var schema = _load(file);
    if (parts.length > 1) {
      for (final token in parts[1].split('/').skip(1)) {
        schema =
            object(schema)[token.replaceAll('~1', '/').replaceAll('~0', '~')];
      }
    }
    return _check(value, schema, file) != null;
  }

  Set<String>? _check(Object? value, Object? raw, String file) {
    if (raw == true) return <String>{};
    if (raw == false || raw == null) return null;
    final s = object(raw);
    for (final key in s.keys) {
      if (!supportedKeywords.contains(key)) {
        throw UnsupportedError(key);
      }
    }
    final evaluated = <String>{};
    if (s[r'$ref'] is String) {
      final parts = (s[r'$ref'] as String).split('#');
      final nextFile = parts.first.isEmpty ? file : parts.first.split('/').last;
      var target = _load(nextFile);
      if (parts.length > 1) {
        for (final token in parts[1].split('/').skip(1)) {
          target =
              object(target)[token.replaceAll('~1', '/').replaceAll('~0', '~')];
        }
      }
      final result = _check(value, target, nextFile);
      if (result == null) return null;
      evaluated.addAll(result);
    }
    bool same(Object? a, Object? b) {
      if (a is Map<Object?, Object?> && b is Map<Object?, Object?>) {
        return a.length == b.length &&
            a.keys.every((k) => b.containsKey(k) && same(a[k], b[k]));
      }
      if (a is List<Object?> && b is List<Object?>) {
        return a.length == b.length &&
            List.generate(a.length, (i) => same(a[i], b[i])).every((v) => v);
      }
      return a == b;
    }

    if (s.containsKey('const') && !same(s['const'], value)) return null;
    if (s['enum'] is List<Object?> &&
        !(s['enum'] as List<Object?>).any((e) => same(e, value))) return null;
    final types = s['type'];
    bool hasType(Object? type) => switch (type) {
          'object' => value is Map<Object?, Object?>,
          'array' => value is List<Object?>,
          'string' => value is String,
          'integer' => value is num && value == value.roundToDouble(),
          'number' => value is num,
          'boolean' => value is bool,
          'null' => value == null,
          _ => false,
        };
    if (types != null &&
        !(types is List<Object?> ? types.any(hasType) : hasType(types)))
      return null;
    for (final keyword in ['allOf', 'anyOf', 'oneOf']) {
      if (s[keyword] is! List<Object?>) continue;
      final results = (s[keyword] as List<Object?>)
          .map((child) => _check(value, child, file))
          .toList();
      final successes = results.whereType<Set<String>>().toList();
      if ((keyword == 'allOf' && successes.length != results.length) ||
          (keyword == 'anyOf' && successes.isEmpty) ||
          (keyword == 'oneOf' && successes.length != 1)) return null;
      for (final result in successes) {
        evaluated.addAll(result);
      }
    }
    if (s.containsKey('not') && _check(value, s['not'], file) != null)
      return null;
    if (s.containsKey('if')) {
      final matches = _check(value, s['if'], file) != null;
      final branch = matches ? 'then' : 'else';
      if (s.containsKey(branch)) {
        final result = _check(value, s[branch], file);
        if (result == null) return null;
        evaluated.addAll(result);
      }
    }
    if (value is String) {
      if (s['minLength'] is int && value.runes.length < (s['minLength'] as int))
        return null;
      if (s['maxLength'] is int && value.runes.length > (s['maxLength'] as int))
        return null;
      if (s['pattern'] is String &&
          !RegExp(s['pattern'] as String).hasMatch(value)) return null;
      if (s['format'] == 'uri' &&
          (Uri.tryParse(value)?.hasScheme != true || value.contains(' '))) {
        return null;
      }
      bool validDate(String date) {
        if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(date)) return false;
        final parsed = DateTime.tryParse(date);
        return parsed != null && parsed.toIso8601String().startsWith(date);
      }

      if (s['format'] == 'date' && !validDate(value)) return null;
      if (s['format'] == 'date-time') {
        final match = RegExp(
                r'^(\d{4}-\d{2}-\d{2})[Tt](\d{2}):(\d{2}):(\d{2})(?:\.\d+)?(?:[Zz]|[+-]\d{2}:\d{2})$')
            .firstMatch(value);
        if (match == null ||
            !validDate(match[1]!) ||
            int.parse(match[2]!) > 23 ||
            int.parse(match[3]!) > 59 ||
            int.parse(match[4]!) > 60 ||
            DateTime.tryParse(value) == null) {
          return null;
        }
      }
    }
    if (value is num) {
      if (s['minimum'] is num && value < (s['minimum'] as num)) return null;
      if (s['maximum'] is num && value > (s['maximum'] as num)) return null;
      if (s['exclusiveMinimum'] is num &&
          value <= (s['exclusiveMinimum'] as num)) return null;
    }
    if (value is List<Object?>) {
      if (s['minItems'] is int && value.length < (s['minItems'] as int))
        return null;
      if (s['maxItems'] is int && value.length > (s['maxItems'] as int))
        return null;
      if (s['items'] != null &&
          value.any((v) => _check(v, s['items'], file) == null)) return null;
      if (s['uniqueItems'] == true) {
        for (var i = 0; i < value.length; i++) {
          for (var j = i + 1; j < value.length; j++) {
            if (same(value[i], value[j])) return null;
          }
        }
      }
      if (s.containsKey('contains')) {
        final count =
            value.where((v) => _check(v, s['contains'], file) != null).length;
        if (count < (s['minContains'] as int? ?? 1) ||
            count > (s['maxContains'] as int? ?? value.length)) return null;
      }
    }
    if (value is Map<Object?, Object?>) {
      final map = object(value);
      if (s['required'] is List<Object?> &&
          (s['required'] as List<Object?>).any((k) => !map.containsKey(k)))
        return null;
      if (s['maxProperties'] is int && map.length > (s['maxProperties'] as int))
        return null;
      final properties = object(s['properties'] ?? <String, Object?>{});
      for (final entry in map.entries) {
        if (s['propertyNames'] != null &&
            _check(entry.key, s['propertyNames'], file) == null) return null;
        if (properties.containsKey(entry.key)) {
          if (_check(entry.value, properties[entry.key], file) == null)
            return null;
          evaluated.add(entry.key);
        } else if (s.containsKey('additionalProperties')) {
          if (_check(entry.value, s['additionalProperties'], file) == null)
            return null;
          evaluated.add(entry.key);
        }
      }
      if (s['unevaluatedProperties'] == false &&
          map.keys.any((k) => !evaluated.contains(k))) return null;
    }
    return evaluated;
  }
}
