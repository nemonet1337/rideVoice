import 'dart:collection';
import 'dart:typed_data';

/// Sequence-number reorder buffer (lightweight jitter buffer, design doc
/// §6-3): re-orders out-of-order frames, drops duplicates/late arrivals,
/// and counts losses so the caller can trigger PLC per missing frame.
///
/// Sequence numbers are 16-bit and wrap around; distances are computed
/// modulo 2^16.
class JitterBuffer {
  /// How many frames ahead of the expected one we hold back before giving
  /// up on the gap (each held frame ≈ one 20 ms packet of latency).
  final int capacity;

  int? _expectedSeq;
  final _pending = SplayTreeMap<int, Uint8List>();

  int lostFrames = 0;
  int duplicateFrames = 0;
  int reorderedFrames = 0;

  JitterBuffer({this.capacity = 4});

  static const int _seqSpace = 1 << 16;
  static const int _half = 1 << 15;

  /// Signed distance from [from] to [to] in sequence space.
  static int seqDistance(int from, int to) {
    final d = (to - from) & (_seqSpace - 1);
    return d < _half ? d : d - _seqSpace;
  }

  /// Inserts a frame; returns the frames that are now deliverable in order.
  List<Uint8List> insert(int seqNum, Uint8List frame) {
    final expected = _expectedSeq;
    if (expected == null) {
      _expectedSeq = (seqNum + 1) & (_seqSpace - 1);
      return [frame];
    }

    final distance = seqDistance(expected, seqNum);
    if (distance < 0) {
      // Late or duplicate: already delivered (or declared lost).
      duplicateFrames++;
      return const [];
    }
    if (distance == 0) {
      final out = <Uint8List>[frame];
      _expectedSeq = (seqNum + 1) & (_seqSpace - 1);
      _drainConsecutive(out);
      return out;
    }

    // Ahead of the expected frame: hold it back.
    reorderedFrames++;
    _pending[seqNum] = frame;
    if (_pendingSpan() > capacity) {
      return _flushGap();
    }
    return const [];
  }

  /// Distance covered by buffered frames relative to the expected seq.
  int _pendingSpan() {
    if (_pending.isEmpty || _expectedSeq == null) return 0;
    var maxDist = 0;
    for (final seq in _pending.keys) {
      final d = seqDistance(_expectedSeq!, seq);
      if (d > maxDist) maxDist = d;
    }
    return maxDist;
  }

  /// Gives up waiting for the gap: counts the missing frames as lost and
  /// delivers what we have in order.
  List<Uint8List> _flushGap() {
    final out = <Uint8List>[];
    while (_pending.isNotEmpty) {
      final nextSeq = _nearestPendingSeq()!;
      final gap = seqDistance(_expectedSeq!, nextSeq);
      if (gap > 0) lostFrames += gap;
      out.add(_pending.remove(nextSeq)!);
      _expectedSeq = (nextSeq + 1) & (_seqSpace - 1);
      _drainConsecutive(out);
      if (_pendingSpan() <= capacity) break;
    }
    return out;
  }

  int? _nearestPendingSeq() {
    int? best;
    var bestDist = 1 << 30;
    for (final seq in _pending.keys) {
      final d = seqDistance(_expectedSeq!, seq);
      if (d >= 0 && d < bestDist) {
        bestDist = d;
        best = seq;
      }
    }
    return best;
  }

  void _drainConsecutive(List<Uint8List> out) {
    while (true) {
      final next = _pending.remove(_expectedSeq);
      if (next == null) break;
      out.add(next);
      _expectedSeq = (_expectedSeq! + 1) & (_seqSpace - 1);
    }
  }
}
