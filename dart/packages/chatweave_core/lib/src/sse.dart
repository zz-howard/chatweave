import 'dart:async';
import 'dart:convert';

import 'model.dart';

class SseFrame {
  const SseFrame({required this.data, this.event, this.id, this.retry});
  final String data;
  final String? event;
  final String? id;
  final int? retry;
}

/// SSE fields are local to each dispatch; an activity frame never inherits id.
class SseDecoder extends StreamTransformerBase<List<int>, SseFrame> {
  const SseDecoder({this.limits = const Limits()});
  final Limits limits;

  @override
  Stream<SseFrame> bind(Stream<List<int>> stream) {
    limits.validateConfiguration();
    var length = 0;
    var data = <String>[];
    String? event;
    String? id;
    int? retry;
    var bytes = 0;
    var first = true;
    // Synchronous transforms propagate cancellation immediately. An async*
    // decoder can wait for the next byte while its subscription is cancelled.
    final bounded = stream.transform(
      StreamTransformer<List<int>, List<int>>.fromHandlers(
        handleData: (chunk, sink) {
          for (final byte in chunk) {
            if (byte == 10 || byte == 13) {
              length = 0;
            } else if (++length > limits.maxEventBytes) {
              sink.addError(const ProtocolError('limit_exceeded'));
              return;
            }
          }
          sink.add(chunk);
        },
      ),
    );
    return bounded
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .transform(
      StreamTransformer<String, SseFrame>.fromHandlers(
        handleData: (input, sink) {
          var line = input;
          if (first) {
            first = false;
            if (line.startsWith('\uFEFF')) line = line.substring(1);
          }
          if (line.isEmpty) {
            if (data.isNotEmpty) {
              sink.add(
                SseFrame(
                  data: data.join('\n'),
                  event: event,
                  id: id,
                  retry: retry,
                ),
              );
            }
            data = <String>[];
            event = null;
            id = null;
            retry = null;
            bytes = 0;
            return;
          }
          bytes += utf8.encode(line).length;
          if (bytes > limits.maxEventBytes) {
            sink.addError(const ProtocolError('limit_exceeded'));
            return;
          }
          if (line.startsWith(':')) return;
          final colon = line.indexOf(':');
          final field = colon < 0 ? line : line.substring(0, colon);
          var value = colon < 0 ? '' : line.substring(colon + 1);
          if (value.startsWith(' ')) value = value.substring(1);
          switch (field) {
            case 'data':
              data.add(value);
            case 'event':
              event = value;
            case 'id':
              if (!value.contains('\u0000')) id = value;
            case 'retry':
              if (RegExp(r'^\d+$').hasMatch(value)) retry = int.tryParse(value);
          }
        },
      ),
    );
    // An unterminated frame is deliberately not dispatched.
  }
}

class EventParser {
  const EventParser({this.limits = const Limits()});
  final Limits limits;
  StreamEvent parse(SseFrame frame) {
    limits.validateConfiguration();
    if (utf8.encode(frame.data).length > limits.maxEventBytes) {
      throw const ProtocolError('limit_exceeded');
    }
    final json = object(jsonDecode(frame.data));
    limits.checkEvent(json, checkBlockData: false);
    if (frame.event != null && frame.event != json['type']) {
      throw const ProtocolError('event_type_mismatch');
    }
    if (json['type'] == 'message.activity') {
      if (frame.id != null || json.containsKey('seq')) {
        throw const ProtocolError('activity_seq');
      }
    } else if (frame.id != '${json['seq']}') {
      throw const ProtocolError('sse_id_mismatch');
    }
    if (json['protocolVersion'] != '0.1') {
      throw const ProtocolError('unsupported_protocol');
    }
    return StreamEvent.fromJson(json);
  }
}
