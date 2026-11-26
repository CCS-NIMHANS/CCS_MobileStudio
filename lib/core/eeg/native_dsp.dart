import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'signal_quality_analyzer.dart';
import 'spectral_analyzer.dart';

typedef _WelchNative = IntPtr Function(
  Pointer<Double>,
  IntPtr,
  Double,
  IntPtr,
  Pointer<Double>,
  Pointer<Double>,
  Pointer<Double>,
  IntPtr,
  Pointer<Double>,
);
typedef _WelchDart = int Function(
  Pointer<Double>,
  int,
  double,
  int,
  Pointer<Double>,
  Pointer<Double>,
  Pointer<Double>,
  int,
  Pointer<Double>,
);

typedef _QualityBatchNative = Bool Function(
  Pointer<Double>,
  IntPtr,
  IntPtr,
  Double,
  Double,
  Double,
  Pointer<Uint8>,
  Pointer<Double>,
);
typedef _QualityBatchDart = bool Function(
  Pointer<Double>,
  int,
  int,
  double,
  double,
  double,
  Pointer<Uint8>,
  Pointer<Double>,
);

/// FFI bridge to the Rust DSP kernel (`ccs_welch_psd`, `ccs_signal_quality_batch`)
/// with pre-allocated scratch buffers and automatic pure-Dart fallback.
class NativeDsp {
  NativeDsp._() {
    try {
      final lib = _openLibrary();
      _welch = lib.lookupFunction<_WelchNative, _WelchDart>('ccs_welch_psd');
      _qualityBatch = lib.lookupFunction<_QualityBatchNative, _QualityBatchDart>(
        'ccs_signal_quality_batch',
      );
    } catch (_) {
      _welch = null;
      _qualityBatch = null;
    }
  }

  static final NativeDsp instance = NativeDsp._();

  _WelchDart? _welch;
  _QualityBatchDart? _qualityBatch;

  bool get isAvailable => _welch != null && _qualityBatch != null;

  // Reusable FFI scratch buffers to eliminate per-tick calloc/free overhead.
  Pointer<Double> _psdInput = nullptr;
  int _psdInputCap = 0;
  Pointer<Double> _psdFreqs = nullptr;
  Pointer<Double> _psdLinear = nullptr;
  Pointer<Double> _psdDb = nullptr;
  int _psdBinsCap = 0;
  Pointer<Double> _psdBands = nullptr;

  Pointer<Double> _sqiInput = nullptr;
  int _sqiInputCap = 0;
  Pointer<Uint8> _sqiSat = nullptr;
  Pointer<Double> _sqiOut = nullptr;
  int _sqiChCap = 0;

  static DynamicLibrary _openLibrary() {
    if (Platform.isAndroid) {
      return DynamicLibrary.open('libtrain_nidra_core.so');
    }
    if (Platform.isMacOS) {
      final executableDirectory = File(Platform.resolvedExecutable).parent;
      final bundledLibrary = File(
        '${executableDirectory.parent.path}/Frameworks/'
        'libtrain_nidra_core.dylib',
      );
      if (bundledLibrary.existsSync()) {
        return DynamicLibrary.open(bundledLibrary.path);
      }
      final releaseLib = File('rust/target/release/libtrain_nidra_core.dylib');
      if (releaseLib.existsSync()) {
        return DynamicLibrary.open(releaseLib.path);
      }
      return DynamicLibrary.open(
        'rust/target/debug/libtrain_nidra_core.dylib',
      );
    }
    if (Platform.isIOS) return DynamicLibrary.process();
    if (Platform.isWindows) {
      return DynamicLibrary.open('train_nidra_core.dll');
    }
    if (Platform.isLinux) {
      return DynamicLibrary.open('rust/target/debug/libtrain_nidra_core.so');
    }
    return DynamicLibrary.process();
  }

  WelchPsdResult? computeWelchPsd(
    List<double> samples, {
    required double sampleRate,
    int preferredSegmentLength = 512,
  }) {
    final fn = _welch;
    if (fn == null || samples.length < 32 || sampleRate <= 0) {
      return SpectralAnalyzer.computeWelchPsd(
        samples,
        sampleRate: sampleRate,
        preferredSegmentLength: preferredSegmentLength,
      );
    }

    final len = samples.length;
    if (_psdInputCap < len) {
      if (_psdInput != nullptr) calloc.free(_psdInput);
      _psdInput = calloc<Double>(len);
      _psdInputCap = len;
    }
    final maxBins = preferredSegmentLength ~/ 2 + 1;
    if (_psdBinsCap < maxBins) {
      if (_psdFreqs != nullptr) calloc.free(_psdFreqs);
      if (_psdLinear != nullptr) calloc.free(_psdLinear);
      if (_psdDb != nullptr) calloc.free(_psdDb);
      _psdFreqs = calloc<Double>(maxBins);
      _psdLinear = calloc<Double>(maxBins);
      _psdDb = calloc<Double>(maxBins);
      _psdBinsCap = maxBins;
    }
    if (_psdBands == nullptr) {
      _psdBands = calloc<Double>(7);
    }

    _psdInput.asTypedList(len).setAll(0, samples);
    final bins = fn(
      _psdInput,
      len,
      sampleRate,
      preferredSegmentLength,
      _psdFreqs,
      _psdLinear,
      _psdDb,
      maxBins,
      _psdBands,
    );
    if (bins <= 0) return null;

    final freqs = Float64List.fromList(_psdFreqs.asTypedList(bins));
    final psd = Float64List.fromList(_psdLinear.asTypedList(bins));
    final db = Float64List.fromList(_psdDb.asTypedList(bins));
    final bands = _psdBands.asTypedList(7);
    final nfft = (bins - 1) * 2;
    final step = math.max(1, nfft ~/ 2);
    final segments = len >= nfft ? ((len - nfft) ~/ step + 1) : 1;

    return WelchPsdResult(
      frequenciesHz: freqs,
      psdUv2PerHz: psd,
      psdDb: db,
      bands: SpectralBandPowers(
        deltaAbs: bands[0],
        thetaAbs: bands[1],
        alphaAbs: bands[2],
        betaAbs: bands[3],
        gammaAbs: bands[4],
        totalAbs: bands[5],
        peakFrequencyHz: bands[6],
      ),
      sampleRate: sampleRate,
      segmentCount: segments,
    );
  }

  List<ChannelQualityMetrics> analyzeQualityBatch(
    List<Float64List> rawWindows, {
    required double sampleRate,
    required double mainsHz,
    required double calibrationFactor,
    required List<bool> saturatedFlags,
  }) {
    final chCount = rawWindows.length;
    if (chCount == 0) return const [];
    final winLen = rawWindows.first.length;
    final fn = _qualityBatch;

    if (fn == null || winLen < 16) {
      return List<ChannelQualityMetrics>.generate(chCount, (i) {
        return SignalQualityAnalyzer.analyzeChannel(
          rawWindows[i],
          sampleRate: sampleRate,
          mainsHz: mainsHz,
          adcSaturated: i < saturatedFlags.length && saturatedFlags[i],
          calibrationFactor: calibrationFactor,
        );
      }, growable: false);
    }

    final total = chCount * winLen;
    if (_sqiInputCap < total) {
      if (_sqiInput != nullptr) calloc.free(_sqiInput);
      _sqiInput = calloc<Double>(total);
      _sqiInputCap = total;
    }
    if (_sqiChCap < chCount) {
      if (_sqiSat != nullptr) calloc.free(_sqiSat);
      if (_sqiOut != nullptr) calloc.free(_sqiOut);
      _sqiSat = calloc<Uint8>(chCount);
      _sqiOut = calloc<Double>(chCount * 8);
      _sqiChCap = chCount;
    }

    final flatView = _sqiInput.asTypedList(total);
    final satView = _sqiSat.asTypedList(chCount);
    for (var ch = 0; ch < chCount; ch++) {
      final w = rawWindows[ch];
      final copyLen = math.min(winLen, w.length);
      flatView.setRange(ch * winLen, ch * winLen + copyLen, w);
      satView[ch] =
          (ch < saturatedFlags.length && saturatedFlags[ch]) ? 1 : 0;
    }

    final ok = fn(
      _sqiInput,
      chCount,
      winLen,
      sampleRate,
      mainsHz,
      calibrationFactor,
      _sqiSat,
      _sqiOut,
    );
    if (!ok) return const [];

    final outView = _sqiOut.asTypedList(chCount * 8);
    return List<ChannelQualityMetrics>.generate(chCount, (ch) {
      final base = ch * 8;
      final flags = outView[base + 6].round();
      final gradeIdx = outView[base + 7].round().clamp(0, 3);
      return ChannelQualityMetrics(
        sqiPercent: outView[base],
        estimatedImpedanceKOhm: outView[base + 1],
        peakToPeakUv: outView[base + 2],
        rmsUv: outView[base + 3],
        lineNoiseRmsUv: outView[base + 4],
        hfNoiseRmsUv: outView[base + 5],
        flatline: (flags & 1) != 0,
        saturated: (flags & 2) != 0,
        grade: SignalQualityGrade.values[gradeIdx],
      );
    }, growable: false);
  }
}
