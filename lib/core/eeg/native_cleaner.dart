import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

class OnlineCleanerConfig {
  const OnlineCleanerConfig({
    this.enabled = false,
    this.enableCleanLine = true,
    this.lineFreqHz = 50.0,
    this.enableAsr = true,
    this.asrCutoff = 15.0,
    this.enableEog = true,
    this.enableEmg = true,
    this.eogChannelMask = 0,
  });

  final bool enabled;
  final bool enableCleanLine;
  final double lineFreqHz;
  final bool enableAsr;
  final double asrCutoff;
  final bool enableEog;
  final bool enableEmg;
  final int eogChannelMask;

  OnlineCleanerConfig copyWith({
    bool? enabled,
    bool? enableCleanLine,
    double? lineFreqHz,
    bool? enableAsr,
    double? asrCutoff,
    bool? enableEog,
    bool? enableEmg,
    int? eogChannelMask,
  }) => OnlineCleanerConfig(
    enabled: enabled ?? this.enabled,
    enableCleanLine: enableCleanLine ?? this.enableCleanLine,
    lineFreqHz: lineFreqHz ?? this.lineFreqHz,
    enableAsr: enableAsr ?? this.enableAsr,
    asrCutoff: asrCutoff ?? this.asrCutoff,
    enableEog: enableEog ?? this.enableEog,
    enableEmg: enableEmg ?? this.enableEmg,
    eogChannelMask: eogChannelMask ?? this.eogChannelMask,
  );
}

class _CleanerBindings {
  _CleanerBindings._() {
    try {
      final lib = _openLib();
      create = lib
          .lookupFunction<
            Pointer<Void> Function(IntPtr, Double),
            Pointer<Void> Function(int, double)
          >('ccs_cleaner_create');
      setConfig = lib
          .lookupFunction<
            Void Function(
              Pointer<Void>,
              Uint8,
              Double,
              Uint8,
              Double,
              Uint8,
              Uint8,
              Uint32,
            ),
            void Function(
              Pointer<Void>,
              int,
              double,
              int,
              double,
              int,
              int,
              int,
            )
          >('ccs_cleaner_set_config');
      calibratePush = lib
          .lookupFunction<
            Int32 Function(Pointer<Void>, Pointer<Double>, IntPtr),
            int Function(Pointer<Void>, Pointer<Double>, int)
          >('ccs_cleaner_calibrate_push');
      processSample = lib
          .lookupFunction<
            Double Function(
              Pointer<Void>,
              Pointer<Double>,
              Pointer<Double>,
              IntPtr,
            ),
            double Function(Pointer<Void>, Pointer<Double>, Pointer<Double>, int)
          >('ccs_cleaner_process_sample');
      calibrationProgress = lib
          .lookupFunction<
            Int32 Function(Pointer<Void>),
            int Function(Pointer<Void>)
          >('ccs_cleaner_calibration_progress');
      reset = lib
          .lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>(
            'ccs_cleaner_reset',
          );
      freeFn = lib
          .lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>(
            'ccs_cleaner_free',
          );
      available = true;
    } catch (_) {
      available = false;
    }
  }

  static final _CleanerBindings instance = _CleanerBindings._();

  bool available = false;
  Pointer<Void> Function(int, double)? create;
  void Function(Pointer<Void>, int, double, int, double, int, int, int)?
  setConfig;
  int Function(Pointer<Void>, Pointer<Double>, int)? calibratePush;
  double Function(Pointer<Void>, Pointer<Double>, Pointer<Double>, int)?
  processSample;
  int Function(Pointer<Void>)? calibrationProgress;
  void Function(Pointer<Void>)? reset;
  void Function(Pointer<Void>)? freeFn;

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
}

/// Zero-allocation FFI wrapper around Rust [OnlineEegCleaner].
class NativeOnlineEegCleaner {
  NativeOnlineEegCleaner({
    required this.channelCount,
    required this.sampleRate,
  }) {
    _inBuf = calloc<Double>(channelCount);
    _outBuf = calloc<Double>(channelCount);
    final b = _CleanerBindings.instance;
    if (b.available && b.create != null) {
      _ptr = b.create!(channelCount, sampleRate);
    }
  }

  final int channelCount;
  final double sampleRate;
  Pointer<Void> _ptr = nullptr;
  late final Pointer<Double> _inBuf;
  late final Pointer<Double> _outBuf;
  bool _disposed = false;

  int get calibrationProgress {
    final p = _ptr;
    final fn = _CleanerBindings.instance.calibrationProgress;
    if (_disposed || p == nullptr || fn == null) return 0;
    return fn(p);
  }

  void applyConfig(OnlineCleanerConfig cfg) {
    final p = _ptr;
    final fn = _CleanerBindings.instance.setConfig;
    if (_disposed || p == nullptr || fn == null) return;
    fn(
      p,
      cfg.enableCleanLine ? 1 : 0,
      cfg.lineFreqHz,
      cfg.enableAsr ? 1 : 0,
      cfg.asrCutoff,
      cfg.enableEog ? 1 : 0,
      cfg.enableEmg ? 1 : 0,
      cfg.eogChannelMask,
    );
  }

  void reset() {
    final p = _ptr;
    final fn = _CleanerBindings.instance.reset;
    if (_disposed || p == nullptr || fn == null) return;
    fn(p);
  }

  int pushCalibration(List<double> sample) {
    final p = _ptr;
    final fn = _CleanerBindings.instance.calibratePush;
    if (_disposed || p == nullptr || fn == null) return 0;
    for (var i = 0; i < channelCount; i++) {
      _inBuf[i] = i < sample.length ? sample[i] : 0.0;
    }
    return fn(p, _inBuf, channelCount);
  }

  /// Processes one multichannel EEG sample in-place into [outValues] and
  /// returns cleaning intensity in `[0.0, 1.0]`.
  double processSample(List<double> rawValues, List<double> outValues) {
    final p = _ptr;
    final fn = _CleanerBindings.instance.processSample;
    if (_disposed || p == nullptr || fn == null) {
      for (var i = 0; i < outValues.length; i++) {
        outValues[i] = i < rawValues.length ? rawValues[i] : 0.0;
      }
      return 0.0;
    }
    for (var i = 0; i < channelCount; i++) {
      _inBuf[i] = i < rawValues.length ? rawValues[i] : 0.0;
    }
    final intensity = fn(p, _inBuf, _outBuf, channelCount);
    for (var i = 0; i < outValues.length && i < channelCount; i++) {
      outValues[i] = _outBuf[i];
    }
    return intensity;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    final p = _ptr;
    _ptr = nullptr;
    final fn = _CleanerBindings.instance.freeFn;
    if (p != nullptr && fn != null) fn(p);
    calloc.free(_inBuf);
    calloc.free(_outBuf);
  }
}
