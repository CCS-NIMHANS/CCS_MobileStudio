import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ccs_mobile_studio/core/eeg/ring_buffer.dart';
import 'package:ccs_mobile_studio/core/eeg/signal_quality_analyzer.dart';
import 'package:ccs_mobile_studio/core/eeg/spectral_analyzer.dart';
import 'package:ccs_mobile_studio/core/widgets/waveform_scale_snapshot.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SpectralAnalyzer Welch PSD', () {
    test('recovers 10 Hz peak frequency and dominant alpha power', () {
      const sr = 250.0;
      const n = 1000; // 4 seconds
      final samples = List<double>.generate(
        n,
        (i) => 25.0 * math.sin(2.0 * math.pi * 10.0 * (i / sr)),
      );
      final psd = SpectralAnalyzer.computeWelchPsd(samples, sampleRate: sr);
      expect(psd, isNotNull);
      expect(psd!.bands.peakFrequencyHz, closeTo(10.0, 0.8));
      expect(psd.bands.alphaPct, greaterThan(80.0));
      expect(psd.segmentCount, greaterThan(1));
    });

    test('returns null when buffer is too short', () {
      expect(
        SpectralAnalyzer.computeWelchPsd(const [1.0, 2.0, 3.0], sampleRate: 250),
        isNull,
      );
    });
  });

  group('SignalQualityAnalyzer', () {
    test('grades clean physiological EEG as good with low impedance', () {
      const sr = 250.0;
      final clean = List<double>.generate(
        500,
        (i) => 18.0 * math.sin(2.0 * math.pi * 10.0 * (i / sr)),
      );
      final metrics = SignalQualityAnalyzer.analyzeChannel(
        clean,
        sampleRate: sr,
        mainsHz: 50.0,
      );
      expect(metrics.grade, SignalQualityGrade.good);
      expect(metrics.sqiPercent, greaterThan(80.0));
      expect(metrics.estimatedImpedanceKOhm, lessThan(10.0));
      expect(metrics.flatline, isFalse);
      expect(metrics.saturated, isFalse);
    });

    test('grades high 50 Hz mains interference as bad with elevated impedance', () {
      const sr = 250.0;
      final noisy = List<double>.generate(
        500,
        (i) => 90.0 * math.sin(2.0 * math.pi * 50.0 * (i / sr)),
      );
      final metrics = SignalQualityAnalyzer.analyzeChannel(
        noisy,
        sampleRate: sr,
        mainsHz: 50.0,
      );
      expect(metrics.lineNoiseRmsUv, greaterThan(45.0));
      expect(metrics.estimatedImpedanceKOhm, greaterThan(50.0));
      expect(metrics.grade, SignalQualityGrade.bad);
    });

    test('detects ADC saturation and flatline electrodes', () {
      final flat = List<double>.filled(250, 12.0);
      final flatMetrics = SignalQualityAnalyzer.analyzeChannel(
        flat,
        sampleRate: 250.0,
      );
      expect(flatMetrics.flatline, isTrue);
      expect(flatMetrics.grade, SignalQualityGrade.bad);

      final sat = List<double>.generate(250, (i) => i.isEven ? 10.0 : -10.0);
      final satMetrics = SignalQualityAnalyzer.analyzeChannel(
        sat,
        sampleRate: 250.0,
        adcSaturated: true,
      );
      expect(satMetrics.saturated, isTrue);
      expect(satMetrics.estimatedImpedanceKOhm, double.infinity);
      expect(satMetrics.grade, SignalQualityGrade.bad);
    });
  });

  group('Float64RingBuffer & RobustWaveformAutoscale', () {
    test('wraps circularly in chronological order and matches autoscale', () {
      final ring = Float64RingBuffer(5);
      for (var i = 1; i <= 8; i++) {
        ring.push(i.toDouble());
      }
      expect(ring.length, 5);
      expect([for (var i = 0; i < ring.length; i++) ring[i]], [4, 5, 6, 7, 8]);

      final recent = ring.toRecentFloat64List(3);
      expect(recent, Float64List.fromList([6, 7, 8]));

      final bigRing = Float64RingBuffer(200);
      final list = <double>[];
      for (var i = 0; i < 200; i++) {
        final v = 50.0 * math.sin(i * 0.1);
        bigRing.push(v);
        list.add(v);
      }
      expect(
        RobustWaveformAutoscale.amplitudeFromRing(bigRing, visiblePoints: 200),
        closeTo(
          RobustWaveformAutoscale.amplitude(list, visiblePoints: 200),
          1e-6,
        ),
      );
    });
  });
}
