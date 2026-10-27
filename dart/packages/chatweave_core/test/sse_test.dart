import 'dart:convert';
import 'dart:math';

import 'package:chatweave_core/chatweave_core.dart';
import 'package:test/test.dart';

void main() {
  final bytes = utf8.encode('\uFEFF: heartbeat\r\nevent: custom\r\nid: 1\r\n'
      'retry: 250\r\ndata: 北京\r\ndata: 晴\r\n\r\n'
      ': pulse\n\ndata: second\n\n');
  Future<List<String>> decode(List<List<int>> chunks) async =>
      Stream.fromIterable(chunks)
          .transform(const SseDecoder())
          .map(
            (f) => '${f.event}|${f.id}|${f.retry}|${f.data}',
          )
          .toList();
  test('sse_all_single_cuts_and_bytewise', () async {
    final expected = await decode([bytes]);
    expect(expected, ['custom|1|250|北京\n晴', 'null|null|null|second']);
    for (var cut = 0; cut <= bytes.length; cut++) {
      expect(
          await decode([bytes.sublist(0, cut), bytes.sublist(cut)]), expected,
          reason: 'cut=$cut');
    }
    expect(await decode(bytes.map((b) => [b]).toList()), expected);
  });
  test('sse_seeded_chunk_partitions', () async {
    final expected = await decode([bytes]);
    for (var seed = 0; seed < 100; seed++) {
      final random = Random(seed);
      final chunks = <List<int>>[];
      for (var offset = 0; offset < bytes.length;) {
        final end = min(bytes.length, offset + 1 + random.nextInt(15));
        chunks.add(bytes.sublist(offset, end));
        offset = end;
      }
      expect(await decode(chunks), expected, reason: 'seed=$seed');
    }
  });
  test('unterminated_frame_is_not_dispatched', () async {
    expect(await decode([utf8.encode('data: incomplete')]), isEmpty);
  });
}
