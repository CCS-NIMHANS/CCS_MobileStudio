import 'dart:math' as math;

enum SignalQualityGrade { good, fair, poor, bad }

class ChannelQualityMetrics {
  const ChannelQualityMetrics({
    required this.sqiPercent,
    required this.estimatedImpedanceKOhm,
    required this.peakToPeakUv,
    required this.rmsUv,
    required this.lineNoiseRmsUv,
    required this.hfNoiseRmsUv,
    required this.flatline,
    required this.saturated,
    required this.grade,
    this.isHardwareMeasured = false,
  });

  /// Composite Signal Quality Index (0 = unusable, 100 = pristine).
  final double sqiPercent;

  /// Passive contact impedance estimate in kΩ (infinite if saturated/open).
  final double estimatedImpedanceKOhm;
  final double peakToPeakUv;
  final double rmsUv;
  final double lineNoiseRmsUv;
  final double hfNoiseRmsUv;
  final bool flatline;
  final bool saturated;
  final SignalQualityGrade grade;
  final bool isHardwareMeasured;

  String get formattedImpedance {
    if (saturated) return 'SAT / ∞';
    if (flatline) return 'FLAT';
    if (!estimatedImpedanceKOhm.isFinite || estimatedImpedanceKOhm >= 250) {
      return '>250 kΩ';
    }
    if (estimatedImpedanceKOhm >= 100) {
      return '${estimatedImpedanceKOhm.round()} kΩ';
    }
    return '${estimatedImpedanceKOhm.toStringAsFixed(1)} kΩ';
  }
}

/// Real-time per-channel Signal Quality & Passive Electrode-Skin Impedance
/// Estimator.
///
/// Uses a calibrated multi-feature passive estimation model combining:
/// 1. Exact Goertzel narrowband mains-interference RMS (`50 Hz` or `60 Hz`,
///    which scales linearly with electrode-skin impedance mismatch via capacitive
///    common-mode-to-differential conversion).
/// 2. High-frequency thermal/contact-motion noise RMS (`70–110 Hz`, captured
///    when Nyquist permits).
/// 3. Rail saturation & flatline (shorted/disconnected) detection.
class SignalQualityAnalyzer {
  const SignalQualityAnalyzer._();

  static ChannelQualityMetrics analyzeChannel(
    List<double> rawSamples, {
    required double sampleRate,
    double mainsHz = 50.0,
    bool adcSaturated = false,
    double calibrationFactor = 1.0,
  }) {
    if (rawSamples.length < 16 || sampleRate <= 0) {
      return const ChannelQualityMetrics(
        sqiPercent: 0,
        estimatedImpedanceKOhm: double.infinity,
        peakToPeakUv: 0,
        rmsUv: 0,
        lineNoiseRmsUv: 0,
        hfNoiseRmsUv: 0,
        flatline: true,
        saturated: false,
        grade: SignalQualityGrade.bad,
      );
    }

    var sum = 0.0;
    var minVal = double.infinity;
    var maxVal = double.negativeInfinity;
    var absPeak = 0.0;
    for (final v in rawSamples) {
      sum += v;
      if (v < minVal) minVal = v;
      if (v > maxVal) maxVal = v;
      final a = v.abs();
      if (a > absPeak) absPeak = a;
    }
    final mean = sum / rawSamples.length;

    var varSum = 0.0;
    for (final v in rawSamples) {
      final d = v - mean;
      varSum += d * d;
    }
    final rmsUv = math.sqrt(varSum / rawSamples.length);
    final p2p = maxVal - minVal;
    final flatline = rmsUv < 0.08 && p2p < 0.3;
    final saturated = adcSaturated || absPeak > 15000.0 || p2p > 20000.0;

    final lineNoiseRmsUv = goertzelRms(
      rawSamples,
      mean: mean,
      targetHz: mainsHz,
      sampleRate: sampleRate,
    );

    // High-frequency contact/EMG noise band via Goertzel comb (72..108 Hz)
    var hfEnergySq = 0.0;
    var hfBins = 0;
    final nyquist = sampleRate * 0.5;
    for (var f = 72.0; f <= math.min(108.0, nyquist - 4.0); f += 9.0) {
      final binRms = goertzelRms(
        rawSamples,
        mean: mean,
        targetHz: f,
        sampleRate: sampleRate,
      );
      hfEnergySq += binRms * binRms;
      hfBins++;
    }
    final hfNoiseRmsUv = hfBins > 0 ? math.sqrt(hfEnergySq / hfBins) : 0.0;

    // Calibrated passive impedance model (kOhm):
    // Clean dry/gel electrode (<5 kOhm) typically exhibits <1.2 uV mains RMS
    // and <1.0 uV HF bin RMS; >25 uV mains corresponds to >50 kOhm poor contact.
    final double estZ;
    if (saturated) {
      estZ = double.infinity;
    } else if (flatline) {
      estZ = 0.2;
    } else {
      final rawZ = 1.2 + (lineNoiseRmsUv * 2.1) + (hfNoiseRmsUv * 2.8);
      estZ = (rawZ * calibrationFactor).clamp(0.5, 500.0);
    }

    // Composite SQI (0-100)
    double sqi;
    if (saturated || flatline) {
      sqi = 0.0;
    } else {
      final linePenalty = (lineNoiseRmsUv / 40.0).clamp(0.0, 1.0) * 45.0;
      final ampPenalty = p2p > 200.0
          ? ((p2p - 200.0) / 800.0).clamp(0.0, 1.0) * 35.0
          : 0.0;
      final hfPenalty = (hfNoiseRmsUv / 25.0).clamp(0.0, 1.0) * 20.0;
      sqi = (100.0 - linePenalty - ampPenalty - hfPenalty).clamp(0.0, 100.0);
    }

    final SignalQualityGrade grade;
    if (saturated || flatline || sqi < 30.0 || estZ > 50.0) {
      grade = SignalQualityGrade.bad;
    } else if (sqi < 60.0 || estZ > 25.0) {
      grade = SignalQualityGrade.poor;
    } else if (sqi < 80.0 || estZ > 10.0) {
      grade = SignalQualityGrade.fair;
    } else {
      grade = SignalQualityGrade.good;
    }

    return ChannelQualityMetrics(
      sqiPercent: sqi,
      estimatedImpedanceKOhm: estZ,
      peakToPeakUv: p2p,
      rmsUv: rmsUv,
      lineNoiseRmsUv: lineNoiseRmsUv,
      hfNoiseRmsUv: hfNoiseRmsUv,
      flatline: flatline,
      saturated: saturated,
      grade: grade,
    );
  }

  /// Computes exact narrowband sinusoidal RMS at [targetHz] using Goertzel's
  /// algorithm with Hann windowing to suppress spectral leakage.
  static double goertzelRms(
    List<double> samples, {
    required double mean,
    required double targetHz,
    required double sampleRate,
  }) {
    final n = samples.length;
    if (n < 8 || targetHz <= 0 || targetHz >= sampleRate * 0.5) return 0.0;
    final omega = (2.0 * math.pi * targetHz) / sampleRate;
    final coeff = 2.0 * math.cos(omega);
    var q0 = 0.0;
    var q1 = 0.0;
    var q2 = 0.0;
    for (var i = 0; i < n; i++) {
      final hann = 0.5 * (1.0 - math.cos((2.0 * math.pi * i) / (n - 1)));
      final x = (samples[i] - mean) * hann;
      q0 = coeff * q1 - q2 + x;
      q2 = q1;
      q1 = q0;
    }
    final power = q1 * q1 + q2 * q2 - q1 * q2 * coeff;
    final mag = math.sqrt(math.max(0.0, power));
    // Normalize by coherent gain of Hann window (0.5 * N) -> peak amplitude,
    // then / sqrt(2) -> RMS.
    final peak = (2.0 * mag) / (0.5 * n);
    return peak / math.sqrt2;
  }
}
