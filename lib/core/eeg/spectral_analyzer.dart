import 'dart:math' as math;

class SpectralBandPowers {
  const SpectralBandPowers({
    required this.deltaAbs,
    required this.thetaAbs,
    required this.alphaAbs,
    required this.betaAbs,
    required this.gammaAbs,
    required this.totalAbs,
    required this.peakFrequencyHz,
  });

  final double deltaAbs;
  final double thetaAbs;
  final double alphaAbs;
  final double betaAbs;
  final double gammaAbs;
  final double totalAbs;
  final double peakFrequencyHz;

  double get deltaPct => totalAbs > 0 ? 100.0 * deltaAbs / totalAbs : 0.0;
  double get thetaPct => totalAbs > 0 ? 100.0 * thetaAbs / totalAbs : 0.0;
  double get alphaPct => totalAbs > 0 ? 100.0 * alphaAbs / totalAbs : 0.0;
  double get betaPct => totalAbs > 0 ? 100.0 * betaAbs / totalAbs : 0.0;
  double get gammaPct => totalAbs > 0 ? 100.0 * gammaAbs / totalAbs : 0.0;
}

class WelchPsdResult {
  const WelchPsdResult({
    required this.frequenciesHz,
    required this.psdUv2PerHz,
    required this.psdDb,
    required this.bands,
    required this.sampleRate,
    required this.segmentCount,
  });

  final List<double> frequenciesHz;
  final List<double> psdUv2PerHz;
  final List<double> psdDb;
  final SpectralBandPowers bands;
  final double sampleRate;
  final int segmentCount;
}

/// Real-time Welch Periodogram & Canonical EEG Band Power Analyzer.
class SpectralAnalyzer {
  const SpectralAnalyzer._();

  /// Computes Welch's averaged periodogram on [samples] with Hann windowing
  /// and 50% overlap. Segment length automatically adapts to power-of-2 size
  /// fitting available samples.
  static WelchPsdResult? computeWelchPsd(
    List<double> samples, {
    required double sampleRate,
    int preferredSegmentLength = 512,
    double overlap = 0.5,
  }) {
    if (samples.length < 32 || sampleRate <= 0) return null;

    var nfft = 32;
    while (nfft * 2 <= preferredSegmentLength && nfft * 2 <= samples.length) {
      nfft *= 2;
    }
    if (samples.length < nfft) return null;

    final step = math.max(1, (nfft * (1.0 - overlap)).round());
    final hann = List<double>.generate(
      nfft,
      (i) => 0.5 * (1.0 - math.cos((2.0 * math.pi * i) / (nfft - 1))),
      growable: false,
    );
    var windowEnergy = 0.0;
    for (final w in hann) {
      windowEnergy += w * w;
    }
    final bins = nfft ~/ 2 + 1;
    final accum = List<double>.filled(bins, 0.0);
    var segments = 0;

    final real = List<double>.filled(nfft, 0.0);
    final imag = List<double>.filled(nfft, 0.0);

    for (var start = 0; start + nfft <= samples.length; start += step) {
      var mean = 0.0;
      for (var i = 0; i < nfft; i++) {
        mean += samples[start + i];
      }
      mean /= nfft;

      for (var i = 0; i < nfft; i++) {
        real[i] = (samples[start + i] - mean) * hann[i];
        imag[i] = 0.0;
      }

      _fftInPlace(real, imag);

      final scale = 1.0 / (sampleRate * windowEnergy);
      for (var k = 0; k < bins; k++) {
        final magSq = real[k] * real[k] + imag[k] * imag[k];
        final factor = (k == 0 || k == bins - 1) ? 1.0 : 2.0;
        accum[k] += magSq * factor * scale;
      }
      segments++;
    }

    if (segments == 0) return null;

    final df = sampleRate / nfft;
    final freqs = List<double>.generate(bins, (k) => k * df, growable: false);
    final psd = List<double>.generate(
      bins,
      (k) => accum[k] / segments,
      growable: false,
    );
    final psdDb = List<double>.generate(
      bins,
      (k) => 10.0 * math.log(math.max(psd[k], 1e-12)) / math.ln10,
      growable: false,
    );

    var delta = 0.0;
    var theta = 0.0;
    var alpha = 0.0;
    var beta = 0.0;
    var gamma = 0.0;
    var peakFreq = 0.0;
    var peakVal = -1.0;

    for (var k = 0; k < bins; k++) {
      final f = freqs[k];
      final p = psd[k] * df;
      if (f >= 0.5 && f < 4.0) delta += p;
      if (f >= 4.0 && f < 8.0) theta += p;
      if (f >= 8.0 && f < 13.0) alpha += p;
      if (f >= 13.0 && f < 30.0) beta += p;
      if (f >= 30.0 && f <= 45.0) gamma += p;
      if (f >= 1.0 && f <= 40.0 && psd[k] > peakVal) {
        peakVal = psd[k];
        peakFreq = f;
      }
    }

    final total = delta + theta + alpha + beta + gamma;
    return WelchPsdResult(
      frequenciesHz: freqs,
      psdUv2PerHz: psd,
      psdDb: psdDb,
      bands: SpectralBandPowers(
        deltaAbs: delta,
        thetaAbs: theta,
        alphaAbs: alpha,
        betaAbs: beta,
        gammaAbs: gamma,
        totalAbs: total,
        peakFrequencyHz: peakFreq,
      ),
      sampleRate: sampleRate,
      segmentCount: segments,
    );
  }

  /// Iterative radix-2 Cooley-Tukey FFT on power-of-2 arrays.
  static void _fftInPlace(List<double> real, List<double> imag) {
    final n = real.length;
    var j = 0;
    for (var i = 1; i < n; i++) {
      var bit = n >> 1;
      while ((j & bit) != 0) {
        j ^= bit;
        bit >>= 1;
      }
      j ^= bit;
      if (i < j) {
        final tr = real[i];
        real[i] = real[j];
        real[j] = tr;
        final ti = imag[i];
        imag[i] = imag[j];
        imag[j] = ti;
      }
    }

    for (var len = 2; len <= n; len <<= 1) {
      final half = len >> 1;
      final angleStep = -2.0 * math.pi / len;
      final wStepR = math.cos(angleStep);
      final wStepI = math.sin(angleStep);
      for (var i = 0; i < n; i += len) {
        var wr = 1.0;
        var wi = 0.0;
        for (var k = 0; k < half; k++) {
          final evenIdx = i + k;
          final oddIdx = evenIdx + half;
          final tr = wr * real[oddIdx] - wi * imag[oddIdx];
          final ti = wr * imag[oddIdx] + wi * real[oddIdx];
          real[oddIdx] = real[evenIdx] - tr;
          imag[oddIdx] = imag[evenIdx] - ti;
          real[evenIdx] += tr;
          imag[evenIdx] += ti;
          final nextWr = wr * wStepR - wi * wStepI;
          wi = wr * wStepI + wi * wStepR;
          wr = nextWr;
        }
      }
    }
  }
}
