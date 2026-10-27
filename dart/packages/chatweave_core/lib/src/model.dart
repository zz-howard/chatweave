import 'dart:convert';

typedef Json = Map<String, Object?>;

final _frozen = Expando<bool>();

Object? freeze(Object? value) {
  if (value is Map<Object?, Object?> || value is List<Object?>) {
    if (_frozen[value as Object] == true) return value;
    final Object result;
    if (value is Map<Object?, Object?>) {
      result = Map<String, Object?>.unmodifiable(
        value.map((key, item) => MapEntry(key as String, freeze(item))),
      );
    } else {
      result = List<Object?>.unmodifiable((value as List<Object?>).map(freeze));
    }
    _frozen[result] = true;
    return result;
  }
  return value;
}

Json object(Object? value) => value is Json
    ? value
    : (value as Map<Object?, Object?>).cast<String, Object?>();
List<Json> objects(Object? value) =>
    (value as List<Object?>? ?? const <Object?>[]).map(object).toList();

class ProtocolError implements Exception {
  const ProtocolError(this.code, [this.path = '', this.message = '']);
  final String code;
  final String path;
  final String message;
  @override
  String toString() => '$code at $path: $message';
}

class WireModel {
  WireModel(Json json) : json = object(freeze(json));
  final Json json;
  Json toJson() => json;
  Object? operator [](String key) => json[key];
}

class Message extends WireModel {
  Message.fromJson(super.json);
  String get id => this.json['id'] as String;
  String get status => this.json['status'] as String;
  int get rev => this.json['rev'] as int;
  List<Block> get blocks =>
      objects(this.json['blocks']).map(Block.fromJson).toList();
  List<Step> get steps =>
      objects(this.json['steps']).map(Step.fromJson).toList();
}

class Block extends WireModel {
  Block.fromJson(super.json);
  String get id => this.json['id'] is String
      ? this.json['id'] as String
      : 'invalid_${identityHashCode(this.json)}';
  String get type => this.json['type'] is String
      ? this.json['type'] as String
      : 'x-invalid.block';
  Json get data => object(this.json['data'] ?? <String, Object?>{});
  BlockData get typedData => BlockData.fromJson(type, data);
}

class Step extends WireModel {
  Step.fromJson(super.json);
}

class StreamEvent extends WireModel {
  StreamEvent.fromJson(super.json);
  String get type => this.json['type'] as String;
  String get messageId => this.json['messageId'] as String;
  int? get seq => this.json['seq'] as int?;
}

class ActionRequest extends WireModel {
  ActionRequest.fromJson(super.json);
  String get id => this.json['id'] as String;
}

class ActionResult extends WireModel {
  ActionResult.fromJson(super.json);
}

class ClientCapabilities extends WireModel {
  ClientCapabilities.fromJson(super.json);
}

/// Limits can only tighten the protocol ceilings. Sizes are UTF-8 bytes.
class Limits {
  const Limits({
    this.maxBlockDataBytes = 65536,
    this.maxMessageBytes = 262144,
    this.maxEventBytes = 131072,
    this.maxDeltaBytes = 4096,
    this.maxMarkdownBytes = 32768,
    this.maxDataDepth = 6,
    this.maxBlockNodes = 5000,
    this.maxEvents = 5000,
  });
  final int maxBlockDataBytes;
  final int maxMessageBytes;
  final int maxEventBytes;
  final int maxDeltaBytes;
  final int maxMarkdownBytes;
  final int maxDataDepth;
  final int maxBlockNodes;
  final int maxEvents;

  void validateConfiguration() {
    final values = [
      maxBlockDataBytes,
      maxMessageBytes,
      maxEventBytes,
      maxDeltaBytes,
      maxMarkdownBytes,
      maxDataDepth,
      maxBlockNodes,
      maxEvents
    ];
    const ceilings = [65536, 262144, 131072, 4096, 32768, 6, 5000, 5000];
    for (var i = 0; i < values.length; i++) {
      if (values[i] < 1 || values[i] > ceilings[i]) {
        throw const ProtocolError('invalid_limits');
      }
    }
  }

  void checkBytes(Object? value, int maximum) {
    validateConfiguration();
    if (utf8.encode(jsonEncode(value)).length > maximum) {
      throw const ProtocolError('limit_exceeded');
    }
  }

  void checkData(Object? data) {
    checkBytes(data, maxBlockDataBytes);
    var nodes = 0;
    void visit(Object? value, int depth) {
      if (++nodes > maxBlockNodes || depth > maxDataDepth) {
        throw const ProtocolError('limit_exceeded');
      }
      if (value is Map<Object?, Object?>) {
        for (final item in value.values) {
          visit(item, depth + 1);
        }
      } else if (value is List<Object?>) {
        for (final item in value) {
          visit(item, depth + 1);
        }
      }
    }

    visit(data, 1);
  }

  void checkBlock(Json block) {
    validateConfiguration();
    var nodes = 0;
    final stack = <Object?>[block];
    while (stack.isNotEmpty) {
      final value = stack.removeLast();
      if (++nodes > maxBlockNodes) throw const ProtocolError('limit_exceeded');
      if (value is Map<Object?, Object?>) stack.addAll(value.values);
      if (value is List<Object?>) stack.addAll(value);
    }
    if (block.containsKey('data')) checkData(block['data']);
    if (block['type'] == 'markdown') {
      final text = object(block['data'] ?? <String, Object?>{})['text'];
      if (text is String && utf8.encode(text).length > maxMarkdownBytes) {
        throw const ProtocolError('limit_exceeded');
      }
    }
  }

  void checkEvent(Json event, {bool checkBlockData = true}) {
    checkBytes(event, maxEventBytes);
    if (checkBlockData && event.containsKey('data')) checkData(event['data']);
    final delta = event['delta'];
    if (delta is Map<Object?, Object?> &&
        delta['text'] is String &&
        utf8.encode(delta['text'] as String).length > maxDeltaBytes) {
      throw const ProtocolError('limit_exceeded');
    }
  }

  void checkMessage(Json message) {
    checkBytes(message, maxMessageBytes);
    for (final block in objects(message['blocks'])) {
      checkBlock(block);
    }
  }
}

Object? mergePatch(Object? target, Object? patch) {
  if (patch is! Map<Object?, Object?>) return patch;
  final result = target is Map<Object?, Object?>
      ? object(target).map(
          (key, value) => MapEntry(key, value),
        )
      : <String, Object?>{};
  for (final entry in object(patch).entries) {
    if (entry.value == null) {
      result.remove(entry.key);
    } else {
      result[entry.key] = mergePatch(result[entry.key], entry.value);
    }
  }
  return result;
}

sealed class BlockData extends WireModel {
  BlockData(super.json);
  factory BlockData.fromJson(String type, Json json) => switch (type) {
        'markdown' => MarkdownData(json),
        'metric' => MetricData(json),
        'metric_group' => MetricGroupData(json),
        'dataset' => DatasetData(json),
        'time_series' => TimeSeriesData(json),
        'comparison' => ComparisonData(json),
        'status' => StatusData(json),
        'choice' => ChoiceData(json),
        'confirmation' => ConfirmationData(json),
        'form_intent' => FormIntentData(json),
        _ => UnknownBlockData(json),
      };
}

class MarkdownData extends BlockData {
  MarkdownData(super.json);
  String get text => this.json['text'] as String;
}

class MetricData extends BlockData {
  MetricData(super.json);
  String get label => this.json['label'] as String;
  Object? get value => this.json['value'];
  String? get unit => this.json['unit'] as String?;
}

class MetricGroupData extends BlockData {
  MetricGroupData(super.json);
  List<MetricData> get metrics =>
      objects(this.json['metrics']).map(MetricData.new).toList();
}

class DatasetData extends BlockData {
  DatasetData(super.json);
  List<Json> get columns => objects(this.json['columns']);
  List<Json> get rows => objects(this.json['rows']);
}

class TimeSeriesData extends BlockData {
  TimeSeriesData(super.json);
  String get xType => this.json['xType'] as String;
  List<Json> get series => objects(this.json['series']);
}

class ComparisonData extends BlockData {
  ComparisonData(super.json);
  List<Json> get subjects => objects(this.json['subjects']);
  List<Json> get attributes => objects(this.json['attributes']);
  List<Json> get values => objects(this.json['values']);
}

class StatusData extends BlockData {
  StatusData(super.json);
  String get label => this.json['label'] as String;
  String get state => this.json['state'] as String;
}

class ChoiceData extends BlockData {
  ChoiceData(super.json);
  String get prompt => this.json['prompt'] as String;
  List<Json> get options => objects(this.json['options']);
}

class ConfirmationData extends BlockData {
  ConfirmationData(super.json);
  String get title => this.json['title'] as String;
}

class FormIntentData extends BlockData {
  FormIntentData(super.json);
  String get title => this.json['title'] as String;
  List<Json> get fields => objects(this.json['fields']);
}

class UnknownBlockData extends BlockData {
  UnknownBlockData(super.json);
}

class Interrupt extends WireModel {
  Interrupt.fromJson(super.json);
}

class ActionSpec extends WireModel {
  ActionSpec.fromJson(super.json);
}

class GenerationResponse extends WireModel {
  GenerationResponse.fromJson(super.json);
}

bool jsonEquals(Object? first, Object? second) {
  if (identical(first, second)) return true;
  if (first is Map<Object?, Object?> && second is Map<Object?, Object?>) {
    return first.length == second.length &&
        first.keys.every((key) =>
            second.containsKey(key) && jsonEquals(first[key], second[key]));
  }
  if (first is List<Object?> && second is List<Object?>) {
    if (first.length != second.length) return false;
    for (var i = 0; i < first.length; i++) {
      if (!jsonEquals(first[i], second[i])) return false;
    }
    return true;
  }
  return first == second;
}
