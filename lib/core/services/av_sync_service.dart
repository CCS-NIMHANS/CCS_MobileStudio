import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'file_naming_service.dart';

class AvSyncTelemetry {
  AvSyncTelemetry({
    required this.videoPath,
    required this.sessionStem,
    required this.subject,
    required this.eegStartUtcMs,
    required this.eegSampleRate,
  });

  final String videoPath;
  final String sessionStem;
  final String subject;
  final int eegStartUtcMs;
  final int eegSampleRate;

  double? firstFrameUtcMs;
  double? monotonicUptimeSec;
  double? firstPtsSec;
  int? eegSampleIndexAtFirstFrame;
  double? eegOffsetSecondsAtFirstFrame;
  int frameCount = 0;
  double durationSec = 0.0;
  double driftMsPerMin = 0.0;
  String? lastError;
  final List<Map<String, dynamic>> syncMarkers = [];

  Map<String, dynamic> toJson({String? edfFilename}) => {
    'format': 'ccs_av_sync_v1',
    'subject': subject,
    'session_stem': sessionStem,
    'video_file': videoPath.split(Platform.pathSeparator).last,
    if (edfFilename != null) 'eeg_edf_file': edfFilename,
    'eeg_start_utc_ms': eegStartUtcMs,
    'eeg_sample_rate_hz': eegSampleRate,
    'first_frame_utc_ms': firstFrameUtcMs,
    'first_frame_monotonic_uptime_sec': monotonicUptimeSec,
    'first_frame_pts_sec': firstPtsSec,
    'eeg_sample_index_at_first_frame': eegSampleIndexAtFirstFrame,
    'eeg_offset_seconds_at_first_frame': eegOffsetSecondsAtFirstFrame,
    'frame_count': frameCount,
    'video_duration_seconds': durationSec,
    'drift_ms_per_min': driftMsPerMin,
    'sync_markers': syncMarkers,
  };
}

/// Manages time-synchronized webcam video + audio recording alongside EEG.
///
/// Communicates with native macOS `AvSyncRecorder` (`AVCaptureSession` +
/// `AVAssetWriter`) over `ccs_mobile_studio/av_sync`, stamps exact sample-locked
/// `AV_SYNC_START` / `AV_SYNC_STOP` markers into EDF+ and `_markers.csv`, and
/// exports `<sessionStem>_av_sync.json` beside `<sessionStem>_video.mp4`.
class AvSyncService extends ChangeNotifier {
  AvSyncService() {
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  static const MethodChannel _channel = MethodChannel(
    'ccs_mobile_studio/av_sync',
  );

  bool _armed = false;
  bool _recording = false;
  bool _available = Platform.isMacOS;
  String? _lastError;
  AvSyncTelemetry? _currentTelemetry;
  VoidCallback? _onFirstFrameStamped;

  // Hook callbacks supplied by SessionManager
  int Function()? _readEegSamplesWritten;
  int Function()? _readEegSampleRate;
  void Function(String label, int code, {DateTime? occurredAt})? _emitMarker;

  bool get armed => _armed;
  bool get isRecording => _recording;
  bool get isSupported => _available;
  String? get lastError => _lastError;
  AvSyncTelemetry? get currentTelemetry => _currentTelemetry;

  void attachSessionCallbacks({
    required int Function() readEegSamplesWritten,
    required int Function() readEegSampleRate,
    required void Function(String label, int code, {DateTime? occurredAt})
    emitMarker,
  }) {
    _readEegSamplesWritten = readEegSamplesWritten;
    _readEegSampleRate = readEegSampleRate;
    _emitMarker = emitMarker;
  }

  void setArmed(bool value) {
    if (_armed == value) return;
    _armed = value;
    _lastError = null;
    notifyListeners();
  }

  Future<bool> checkAvailability() async {
    try {
      final res = await _channel.invokeMapMethod<String, dynamic>('isAvailable');
      _available = (res?['available'] as bool?) ?? false;
      notifyListeners();
      return _available;
    } catch (_) {
      _available = false;
      notifyListeners();
      return false;
    }
  }

  Future<bool> startSessionRecording({
    required String subject,
    required String sessionStem,
    required int eegStartUtcMs,
    required int eegSampleRate,
  }) async {
    if (!_armed || _recording) return false;
    _lastError = null;
    try {
      Directory stagingDir;
      try {
        stagingDir = await getApplicationDocumentsDirectory();
      } catch (_) {
        stagingDir = Directory.systemTemp;
      }
      final videoDir = Directory('${stagingDir.path}/recordings');
      if (!await videoDir.exists()) await videoDir.create(recursive: true);
      final videoPath = '${videoDir.path}/${sessionStem}_video.mp4';

      _currentTelemetry = AvSyncTelemetry(
        videoPath: videoPath,
        sessionStem: sessionStem,
        subject: subject,
        eegStartUtcMs: eegStartUtcMs,
        eegSampleRate: eegSampleRate,
      );

      await _channel.invokeMethod('startRecording', {'path': videoPath});
      _recording = true;
      notifyListeners();
      return true;
    } catch (e) {
      _lastError = e is PlatformException ? (e.message ?? e.code) : '$e';
      _recording = false;
      _currentTelemetry = null;
      notifyListeners();
      return false;
    }
  }

  Future<void> stopSessionRecording({String? edfPath}) async {
    final tel = _currentTelemetry;
    if (!_recording) return;
    _recording = false;
    try {
      final res = await _channel.invokeMapMethod<String, dynamic>(
        'stopRecording',
      );
      if (tel != null && res != null) {
        tel.frameCount = (res['frameCount'] as num?)?.toInt() ?? tel.frameCount;
        tel.durationSec =
            (res['durationSec'] as num?)?.toDouble() ?? tel.durationSec;
        final stopUtcMs = (res['stopUtcMs'] as num?)?.toDouble();
        final sampleIdx = _readEegSamplesWritten?.call() ?? 0;
        final sr = _readEegSampleRate?.call() ?? tel.eegSampleRate;
        final stopOffsetSec = sr > 0 ? sampleIdx / sr : 0.0;
        final stopTime = stopUtcMs != null
            ? DateTime.fromMillisecondsSinceEpoch(stopUtcMs.round())
            : DateTime.now();
        tel.syncMarkers.add({
          'event': 'AV_SYNC_STOP',
          'code': 9902,
          'utc_ms': stopTime.millisecondsSinceEpoch,
          'eeg_sample_index': sampleIdx,
          'eeg_offset_sec': stopOffsetSec,
        });
        _emitMarker?.call('AV_SYNC_STOP', 9902, occurredAt: stopTime);
      }
    } catch (e) {
      _lastError = '$e';
    }

    if (tel != null) {
      await _exportOutputs(tel, edfPath: edfPath);
    }
    notifyListeners();
  }

  Future<void> _exportOutputs(
    AvSyncTelemetry tel, {
    String? edfPath,
  }) async {
    final videoFile = File(tel.videoPath);
    if (await videoFile.exists() && await videoFile.length() > 0) {
      await FileNamingService.exportToDownloads(
        tel.videoPath,
        subject: tel.subject,
        sessionStem: tel.sessionStem,
      );
    }
    try {
      Directory dataDir;
      try {
        dataDir = Directory(
          '${(await getApplicationDocumentsDirectory()).path}/data',
        );
      } catch (_) {
        dataDir = Directory.systemTemp;
      }
      if (!await dataDir.exists()) await dataDir.create(recursive: true);
      final jsonPath = '${dataDir.path}/${tel.sessionStem}_av_sync.json';
      final edfName = edfPath?.split(Platform.pathSeparator).last;
      await File(jsonPath).writeAsString(
        const JsonEncoder.withIndent('  ').convert(tel.toJson(edfFilename: edfName)),
        flush: true,
      );
      await FileNamingService.exportToDownloads(
        jsonPath,
        subject: tel.subject,
        sessionStem: tel.sessionStem,
      );
    } catch (e) {
      debugPrint('[AvSyncService] Metadata export failed: $e');
    }
  }

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    final tel = _currentTelemetry;
    if (tel == null) return null;
    if (call.method == 'onFirstFrame') {
      final args = Map<String, dynamic>.from(call.arguments as Map);
      final firstUtcMs = (args['first_frame_utc_ms'] as num?)?.toDouble();
      final uptime = (args['monotonic_uptime_sec'] as num?)?.toDouble();
      final pts = (args['pts_sec'] as num?)?.toDouble();
      final sampleIdx = _readEegSamplesWritten?.call() ?? 0;
      final sr = _readEegSampleRate?.call() ?? tel.eegSampleRate;
      final offsetSec = sr > 0 ? sampleIdx / sr : 0.0;

      tel.firstFrameUtcMs = firstUtcMs;
      tel.monotonicUptimeSec = uptime;
      tel.firstPtsSec = pts;
      tel.eegSampleIndexAtFirstFrame = sampleIdx;
      tel.eegOffsetSecondsAtFirstFrame = offsetSec;

      final dt = firstUtcMs != null
          ? DateTime.fromMillisecondsSinceEpoch(firstUtcMs.round())
          : DateTime.now();
      tel.syncMarkers.add({
        'event': 'AV_SYNC_START',
        'code': 9901,
        'utc_ms': dt.millisecondsSinceEpoch,
        'eeg_sample_index': sampleIdx,
        'eeg_offset_sec': offsetSec,
      });
      _emitMarker?.call('AV_SYNC_START', 9901, occurredAt: dt);
      _onFirstFrameStamped?.call();
      notifyListeners();
    } else if (call.method == 'onSyncPulse') {
      final args = Map<String, dynamic>.from(call.arguments as Map);
      final wall = (args['elapsed_wall_sec'] as num?)?.toDouble() ?? 0.0;
      final pts = (args['elapsed_pts_sec'] as num?)?.toDouble() ?? 0.0;
      final frames = (args['frame_count'] as num?)?.toInt() ?? tel.frameCount;
      tel.frameCount = frames;
      if (wall > 1.0) {
        tel.driftMsPerMin = ((wall - pts) * 1000.0) / (wall / 60.0);
      }
      notifyListeners();
    }
    return null;
  }
}
