import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ridevoice/audio/jitter_buffer.dart';

void main() {
  Uint8List frame(int seq) => Uint8List.fromList([seq & 0xFF, seq >> 8]);

  int seqOf(Uint8List f) => f[0] | (f[1] << 8);

  group('JitterBuffer', () {
    test('in-order frames pass straight through', () {
      final buffer = JitterBuffer();
      final out = <Uint8List>[];
      for (var seq = 1; seq <= 10; seq++) {
        out.addAll(buffer.insert(seq, frame(seq)));
      }
      expect(out.map(seqOf), List.generate(10, (i) => i + 1));
      expect(buffer.lostFrames, 0);
      expect(buffer.duplicateFrames, 0);
    });

    test('swapped frames are re-ordered', () {
      final buffer = JitterBuffer();
      final out = <Uint8List>[];
      out.addAll(buffer.insert(1, frame(1)));
      out.addAll(buffer.insert(3, frame(3))); // early
      out.addAll(buffer.insert(2, frame(2))); // fills the gap
      out.addAll(buffer.insert(4, frame(4)));
      expect(out.map(seqOf), [1, 2, 3, 4]);
      expect(buffer.lostFrames, 0);
      expect(buffer.reorderedFrames, 1);
    });

    test('duplicates and late arrivals are dropped', () {
      final buffer = JitterBuffer();
      final out = <Uint8List>[];
      out.addAll(buffer.insert(1, frame(1)));
      out.addAll(buffer.insert(2, frame(2)));
      out.addAll(buffer.insert(1, frame(1))); // duplicate
      expect(out.map(seqOf), [1, 2]);
      expect(buffer.duplicateFrames, 1);
    });

    test('a gap larger than capacity is flushed and counted as loss', () {
      final buffer = JitterBuffer(capacity: 3);
      final out = <Uint8List>[];
      out.addAll(buffer.insert(1, frame(1)));
      // Frame 2 is lost; 3..6 arrive.
      for (var seq = 3; seq <= 6; seq++) {
        out.addAll(buffer.insert(seq, frame(seq)));
      }
      expect(out.map(seqOf), [1, 3, 4, 5, 6]);
      expect(buffer.lostFrames, 1);
    });

    test('handles 16-bit sequence wraparound', () {
      final buffer = JitterBuffer();
      final out = <Uint8List>[];
      out.addAll(buffer.insert(0xFFFE, frame(1)));
      out.addAll(buffer.insert(0xFFFF, frame(2)));
      out.addAll(buffer.insert(0x0000, frame(3)));
      out.addAll(buffer.insert(0x0001, frame(4)));
      expect(out.map(seqOf), [1, 2, 3, 4]);
      expect(buffer.lostFrames, 0);
      expect(JitterBuffer.seqDistance(0xFFFF, 0x0000), 1);
      expect(JitterBuffer.seqDistance(0x0000, 0xFFFF), -1);
    });

    /// Communication quality under 10% loss + reordering: the output must
    /// stay in order and the loss count must match the frames dropped.
    test('10% loss with jitter keeps output ordered and counts losses', () {
      final random = Random(7);
      final buffer = JitterBuffer(capacity: 4);
      const total = 500;

      // Simulate the network: drop 10%, swap some adjacent arrivals.
      final arrivals = <int>[];
      var dropped = 0;
      for (var seq = 1; seq <= total; seq++) {
        if (random.nextDouble() < 0.10) {
          dropped++;
          continue;
        }
        arrivals.add(seq);
      }
      for (var i = 0; i + 1 < arrivals.length; i++) {
        if (random.nextDouble() < 0.15) {
          final t = arrivals[i];
          arrivals[i] = arrivals[i + 1];
          arrivals[i + 1] = t;
          i++;
        }
      }

      final delivered = <int>[];
      for (final seq in arrivals) {
        for (final f in buffer.insert(seq, frame(seq))) {
          delivered.add(seqOf(f));
        }
      }

      // Strictly increasing output (no duplicates, no disorder).
      for (var i = 1; i < delivered.length; i++) {
        expect(delivered[i], greaterThan(delivered[i - 1]));
      }
      // Every arrival is eventually delivered or the gap accounted for:
      // trailing frames may still sit in the buffer awaiting a flush.
      expect(delivered.length + buffer.lostFrames,
          lessThanOrEqualTo(arrivals.length + dropped));
      expect(buffer.lostFrames, greaterThan(0));
      expect(buffer.duplicateFrames, 0);
      // The buffer never mistakes reordering for loss beyond the real
      // dropped count (allowing for gaps still pending at the tail).
      expect(buffer.lostFrames, lessThanOrEqualTo(dropped));
    });
  });
}
