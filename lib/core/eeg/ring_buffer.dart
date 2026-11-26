import 'dart:math' as math;
import 'dart:typed_data';

/// Fixed-capacity O(1) circular ring buffer backed by [Float64List].
/// Avoids O(N) `List.removeAt(0)` memory shifts on 250+ Hz streaming hot paths.
class Float64RingBuffer {
  Float64RingBuffer(int capacity)
      : assert(capacity > 0),
        _data = Float64List(capacity);

  final Float64List _data;
  int _head = 0; // next write index
  int _length = 0;

  int get capacity => _data.length;
  int get length => _length;
  bool get isEmpty => _length == 0;
  bool get isNotEmpty => _length > 0;

  void push(double value) {
    _data[_head] = value;
    _head = (_head + 1) % _data.length;
    if (_length < _data.length) {
      _length++;
    }
  }

  void clear() {
    _head = 0;
    _length = 0;
  }

  double operator [](int index) {
    final start = _length < _data.length ? 0 : _head;
    return _data[(start + index) % _data.length];
  }

  /// Copies up to [maxCount] most recent samples in chronological order into
  /// [dest] starting at [destOffset]. Returns number of samples copied.
  int copyRecent(int maxCount, Float64List dest, {int destOffset = 0}) {
    final count = math.min(_length, maxCount);
    if (count <= 0) return 0;
    final cap = _data.length;
    final start = (_head - count + cap) % cap;
    final firstChunk = math.min(count, cap - start);
    dest.setRange(destOffset, destOffset + firstChunk, _data, start);
    final remaining = count - firstChunk;
    if (remaining > 0) {
      dest.setRange(destOffset + firstChunk, destOffset + count, _data, 0);
    }
    return count;
  }

  Float64List toRecentFloat64List(int maxCount) {
    final count = math.min(_length, maxCount);
    final out = Float64List(count);
    copyRecent(count, out);
    return out;
  }
}
