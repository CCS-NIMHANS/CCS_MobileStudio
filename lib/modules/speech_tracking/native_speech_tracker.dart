import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

final class _NativeSpeechDecodeResult extends Struct {
  @Double()
  external double rLeft;

  @Double()
  external double rRight;

  @Double()
  external double diffR;

  @Int32()
  external int predictedSide;

  @Double()
  external double confidence;

  @Double()
  external double snrDb;

  @Int32()
  external int nFeatures;
}

class SpeechDecodeScore {
  const SpeechDecodeScore({
    required this.rLeft,
    required this.rRight,
    required this.diffR,
    required this.predictedSide,
    required this.confidence,
    required this.snrDb,
    required this.nFeatures,
  });

  final double rLeft;
  final double rRight;
  final double diffR;
  final int predictedSide; // 0 = Left, 1 = Right
  final double confidence;
  final double snrDb;
  final int nFeatures;

  String get predictedLabel => predictedSide == 0 ? 'LEFT' : 'RIGHT';
}

/// FFI bridge to Rust neural speech tracking (`ccs_speech_*`) with pure-Dart
/// fallback for unit test environments.
class NativeSpeechTracker {
  NativeSpeechTracker._() {
    try {
      final lib = _openLib();
      _extractEnv = lib
          .lookupFunction<
            IntPtr Function(
              Pointer<Float>,
              IntPtr,
              Double,
              Double,
              Pointer<Double>,
              IntPtr,
            ),
            int Function(
              Pointer<Float>,
              int,
              double,
              double,
              Pointer<Double>,
              int,
            )
          >('ccs_speech_extract_envelope');
      _decodeBlock = lib
          .lookupFunction<
            Int32 Function(
              Pointer<Double>,
              IntPtr,
              IntPtr,
              Double,
              Pointer<Double>,
              Pointer<Double>,
              IntPtr,
              Double,
              Uint8,
              Double,
              Pointer<_NativeSpeechDecodeResult>,
            ),
            int Function(
              Pointer<Double>,
              int,
              int,
              double,
              Pointer<Double>,
              Pointer<Double>,
              int,
              double,
              int,
              double,
              Pointer<_NativeSpeechDecodeResult>,
            )
          >('ccs_speech_decode_block');
      _available = true;
    } catch (_) {
      _available = false;
    }
  }

  static final NativeSpeechTracker instance = NativeSpeechTracker._();

  bool _available = false;
  int Function(
    Pointer<Float>,
    int,
    double,
    double,
    Pointer<Double>,
    int,
  )?
  _extractEnv;
  int Function(
    Pointer<Double>,
    int,
    int,
    double,
    Pointer<Double>,
    Pointer<Double>,
    int,
    double,
    int,
    double,
    Pointer<_NativeSpeechDecodeResult>,
  )?
  _decodeBlock;

  static DynamicLibrary _openLib() {
    if (Platform.isAndroid) return DynamicLibrary.open('libtrain_nidra_core.so');
    if (Platform.isMacOS) {
      final exeDir = File(Platform.resolvedExecutable).parent;
      final bundled = File(
        '${exeDir.parent.path}/Frameworks/libtrain_nidra_core.dylib',
      );
      if (bundled.existsSync()) return DynamicLibrary.open(bundled.path);
      return DynamicLibrary.open('rust/target/debug/libtrain_nidra_core.dylib');
    }
    if (Platform.isIOS) return DynamicLibrary.process();
    if (Platform.isWindows) return DynamicLibrary.open('train_nidra_core.dll');
    return DynamicLibrary.open('rust/target/debug/libtrain_nidra_core.so');
  }

  Float64List extractEnvelope(
    Float32List pcm, {
    required double audioSampleRate,
    double targetRate = 50.0,
  }) {
    if (pcm.isEmpty) return Float64List(0);
    final maxOut = ((pcm.length / (audioSampleRate / targetRate))).floor();
    if (maxOut < 4) return Float64List(0);

    if (_available && _extractEnv != null) {
      final pcmPtr = calloc<Float>(pcm.length);
      final envPtr = calloc<Double>(maxOut);
      try {
        pcmPtr.asTypedList(pcm.length).setAll(0, pcm);
        final count = _extractEnv!(
          pcmPtr,
          pcm.length,
          audioSampleRate,
          targetRate,
          envPtr,
          maxOut,
        );
        final out = Float64List(count);
        for (var i = 0; i < count; i++) {
          out[i] = envPtr[i];
        }
        return out;
      } finally {
        calloc.free(pcmPtr);
        calloc.free(envPtr);
      }
    }

    // Pure-Dart fallback
    final step = math.max(1.0, audioSampleRate / targetRate);
    final n = (pcm.length / step).floor();
    final out = Float64List(n);
    var sum = 0.0;
    for (var k = 0; k < n; k++) {
      final a = (k * step).floor();
      final b = math.min(pcm.length, ((k + 1) * step).ceil());
      var acc = 0.0;
      for (var i = a; i < b; i++) {
        acc += math.pow(pcm[i].abs(), 0.6).toDouble();
      }
      out[k] = acc / math.max(1, b - a);
      sum += out[k];
    }
    final mean = sum / n;
    for (var k = 0; k < n; k++) {
      out[k] -= mean;
    }
    return out;
  }

  SpeechDecodeScore decodeBlock({
    required List<List<double>> eegChannels,
    required double eegSampleRate,
    required Float64List envLeft,
    required Float64List envRight,
    double envSampleRate = 50.0,
    bool multiFeature = true,
    double ridgeLambda = 8.0,
  }) {
    if (eegChannels.isEmpty ||
        eegChannels[0].length < 20 ||
        envLeft.length < 20 ||
        envRight.length < 20) {
      return const SpeechDecodeScore(
        rLeft: 0,
        rRight: 0,
        diffR: 0,
        predictedSide: 0,
        confidence: 0.5,
        snrDb: 0,
        nFeatures: 0,
      );
    }

    final nCh = eegChannels.length;
    final nSamples = eegChannels.map((c) => c.length).reduce(math.min);

    if (_available && _decodeBlock != null) {
      final eegPtr = calloc<Double>(nSamples * nCh);
      final leftPtr = calloc<Double>(envLeft.length);
      final rightPtr = calloc<Double>(envRight.length);
      final outPtr = calloc<_NativeSpeechDecodeResult>();
      try {
        for (var s = 0; s < nSamples; s++) {
          for (var c = 0; c < nCh; c++) {
            eegPtr[s * nCh + c] = eegChannels[c][s];
          }
        }
        leftPtr.asTypedList(envLeft.length).setAll(0, envLeft);
        rightPtr.asTypedList(envRight.length).setAll(0, envRight);

        final ok = _decodeBlock!(
          eegPtr,
          nSamples,
          nCh,
          eegSampleRate,
          leftPtr,
          rightPtr,
          math.min(envLeft.length, envRight.length),
          envSampleRate,
          multiFeature ? 1 : 0,
          ridgeLambda,
          outPtr,
        );
        if (ok == 1) {
          final r = outPtr.ref;
          return SpeechDecodeScore(
            rLeft: r.rLeft,
            rRight: r.rRight,
            diffR: r.diffR,
            predictedSide: r.predictedSide,
            confidence: r.confidence,
            snrDb: r.snrDb,
            nFeatures: r.nFeatures,
          );
        }
      } finally {
        calloc.free(eegPtr);
        calloc.free(leftPtr);
        calloc.free(rightPtr);
        calloc.free(outPtr);
      }
    }

    // Pure-Dart fallback cross-correlation peak for unit test environments
    final ratio = math.max(1.0, eegSampleRate / envSampleRate);
    final n = math.min((nSamples / ratio).floor(), math.min(envLeft.length, envRight.length));
    final down = List<double>.generate(n, (t) {
      var s = 0.0;
      final a = (t * ratio).floor();
      final b = math.min(nSamples, ((t + 1) * ratio).ceil());
      for (var k = a; k < b; k++) {
        s += eegChannels[0][k];
      }
      return s / math.max(1, b - a);
    });
    double corrAt(Float64List env, int lag) {
      final m = n - lag;
      if (m < 8) return 0;
      var num = 0.0, dx = 0.0, dy = 0.0;
      for (var i = 0; i < m; i++) {
        num += down[i + lag] * env[i];
        dx += down[i + lag] * down[i + lag];
        dy += env[i] * env[i];
      }
      return num / math.max(1e-9, math.sqrt(dx * dy));
    }

    var bestL = 0.0, bestR = 0.0;
    for (var lag = 0; lag <= 10; lag++) {
      bestL = math.max(bestL, corrAt(envLeft, lag).abs());
      bestR = math.max(bestR, corrAt(envRight, lag).abs());
    }
    return SpeechDecodeScore(
      rLeft: bestL,
      rRight: bestR,
      diffR: bestL - bestR,
      predictedSide: bestL >= bestR ? 0 : 1,
      confidence: ((bestL - bestR).abs() * 3.0).clamp(0.05, 0.99),
      snrDb: 0.0,
      nFeatures: nCh,
    );
  }
}
