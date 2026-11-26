import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../../core/eeg/ring_buffer.dart';
import '../../core/models/eeg_sample.dart';

/// Incremental real-time Event-Related Potential (ERP) averager.
///
/// Uses an O(1) [Float64RingBuffer] for the `-100..0 ms` baseline history and
/// maintains running epoch sums so updating and querying [averages] is O(epoch)
/// rather than O(trials * epoch).
class ErpAverager {
  ErpAverager({required this.sampleRate, this.channelIndex = 0})
    : preSamples = math.max(1, (sampleRate * 0.1).round()),
      postSamples = math.max(1, (sampleRate * 0.8).round()),
      _history = Float64RingBuffer(math.max(1, (sampleRate * 0.1).round()));

  final double sampleRate;
  final int channelIndex;
  final int preSamples;
  final int postSamples;
  final Float64RingBuffer _history;

  final Map<String, Float64List> _sums = {};
  final Map<String, int> _counts = {};
  final List<_ActiveErpEpoch> _active = [];

  /// Incremented whenever at least one epoch finishes and updates the average.
  final ValueNotifier<int> version = ValueNotifier<int>(0);

  int get epochLength => preSamples + postSamples;

  Map<String, List<double>> get averages => {
    for (final entry in _sums.entries)
      entry.key: _averageFor(entry.value, _counts[entry.key] ?? 0),
  };

  Map<String, int> get counts => Map<String, int>.unmodifiable(_counts);

  void mark(String stimulusClass) {
    final total = preSamples + postSamples;
    final preCount = _history.length;
    final buf = Float64List(total);
    // Right-align available pre-stimulus history if fewer than preSamples exist.
    final pad = preSamples - preCount;
    if (preCount > 0) {
      _history.copyRecent(preCount, buf, destOffset: pad);
    }
    _active.add(_ActiveErpEpoch(stimulusClass, buf, preSamples, preCount));
  }

  bool push(EegSample sample) {
    if (channelIndex >= sample.channels.length) return false;
    final value = sample.channels[channelIndex];
    _history.push(value);
    if (_active.isEmpty) return false;

    var completed = false;
    for (var i = _active.length - 1; i >= 0; i--) {
      final active = _active[i];
      active.samples[active.writeIndex++] = value;
      if (active.writeIndex < active.samples.length) continue;

      final baselineLen = math.max(1, active.preSampleCount);
      final baselineStart = preSamples - active.preSampleCount;
      var baselineSum = 0.0;
      for (var j = 0; j < baselineLen; j++) {
        baselineSum += active.samples[baselineStart + j];
      }
      final baseline = baselineSum / baselineLen;

      final sumBuf = _sums.putIfAbsent(
        active.stimulusClass,
        () => Float64List(active.samples.length),
      );
      for (var j = 0; j < active.samples.length; j++) {
        sumBuf[j] += active.samples[j] - baseline;
      }
      _counts[active.stimulusClass] = (_counts[active.stimulusClass] ?? 0) + 1;
      _active.removeAt(i);
      completed = true;
    }

    if (completed) {
      version.value++;
    }
    return completed;
  }

  List<double> _averageFor(Float64List sumBuf, int count) {
    if (count <= 0) return const [];
    final inv = 1.0 / count;
    return List<double>.generate(
      sumBuf.length,
      (i) => sumBuf[i] * inv,
      growable: false,
    );
  }

  void dispose() {
    version.dispose();
  }
}

class _ActiveErpEpoch {
  _ActiveErpEpoch(
    this.stimulusClass,
    this.samples,
    this.writeIndex,
    this.preSampleCount,
  );

  final String stimulusClass;
  final Float64List samples;
  int writeIndex;
  final int preSampleCount;
}
