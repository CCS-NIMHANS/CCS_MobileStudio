import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../eeg/acquisition_service.dart';
import '../eeg/display_filter.dart';
import '../eeg/lsl_eeg_acquisition_service.dart';
import '../eeg/native_cleaner.dart';
import '../eeg/native_dsp.dart';
import '../eeg/ring_buffer.dart';
import '../eeg/signal_quality_analyzer.dart';
import '../eeg/spectral_analyzer.dart';
import '../models/device_profile.dart';
import '../models/eeg_sample.dart';
import '../models/nirs_sample.dart';
import '../models/signal_stream_sample.dart';
import '../models/stream_marker.dart';
import '../services/nirs_acquisition_service.dart';
import '../services/settings_service.dart';
import '../theme/studio_theme.dart';
import 'nirs_waveform_painter.dart';
import 'psd_viewer.dart';
import 'signal_quality_panel.dart';
import 'waveform_painter.dart';
import 'waveform_scale_snapshot.dart';

/// Unified EEG & fNIRS viewer widget with interactive channel gutter,
/// per-channel display filtering, montage/rename controls, real-time Welch PSD,
/// and per-channel signal quality / passive impedance monitoring.
class EegViewer extends StatefulWidget {
  const EegViewer({
    super.key,
    this.eegService,
    this.lslEegService,
    this.nirsService,
    this.signalStream,
    this.signalProfile,
    this.displayStateKey,
    this.initialDurationSeconds = 4,
    this.showControls = true,
    this.showMetrics = true,
    this.markerStream,
    this.fullScreen = false,
    this.extraToolbarActions = const [],
  });

  final AcquisitionService? eegService;
  final LslEegAcquisitionService? lslEegService;
  final NirsAcquisitionService? nirsService;
  final Stream<SignalStreamSample>? signalStream;
  final SignalStreamProfile? signalProfile;
  final String? displayStateKey;
  final int initialDurationSeconds;
  final bool showControls;
  final bool showMetrics;
  final Stream<StreamMarker>? markerStream;
  final bool fullScreen;
  final List<Widget> extraToolbarActions;

  @override
  State<EegViewer> createState() => _EegViewerState();
}

class _EegViewerState extends State<EegViewer>
    with SingleTickerProviderStateMixin, AutomaticKeepAliveClientMixin {
  late TabController? _tabController;
  final List<Float64RingBuffer> _eegBuffers = [];
  final List<Float64RingBuffer> _rawEegBuffers = [];
  final List<List<double>> _nirsBuffers = [];
  final List<String> _eegChannelLabels = [];
  final List<String> _nirsChannelLabels = [];
  final Set<int> _hiddenNirsChannels = {};
  final List<bool> _visibleEegChannels = [];
  final List<SignalType> _eegChannelTypes = [];
  final List<double> _scaleFactorsList = [];

  StreamSubscription<EegSample>? _btEegSub;
  StreamSubscription<EegSample>? _lslEegSub;
  StreamSubscription<NirsSample>? _nirsSub;
  StreamSubscription<SignalStreamSample>? _signalSub;
  StreamSubscription<StreamMarker>? _markerSub;
  final List<StreamMarker> _markers = [];
  Timer? _repaintTimer;
  bool _dirtyWaveform = false;
  final ValueNotifier<int> _waveformTick = ValueNotifier<int>(0);
  final ValueNotifier<int> _analyticsTick = ValueNotifier<int>(0);

  // Display filtering & montage
  final DisplayFilter _displayFilter = DisplayFilter();
  final List<double> _runningMeans = [];
  bool _notchEnabled = true;
  bool _bandpassEnabled = true;
  late DisplayFilterSettings _filterSettings;
  Map<String, ChannelFilterConfig> _channelFilterOverrides = {};
  Map<String, String> _montageReferences = {};
  Map<String, String> _channelRenameOverrides = {};
  Map<String, int> _channelColorOverrides = {};
  Set<String> _hiddenChannelLabels = {};
  String? _prominentChannelLabel;
  String? _soloChannelLabel;

  // Scale & view mode
  bool _autoscale = true;
  double _gain = 1.2;
  late int _durationSeconds;
  String _viewMode = 'rolling';
  double _eegFixedScale = 150.0;
  double _ecgFixedScale = 2000.0;
  double _ppgFixedScale = 100.0;
  double _eegAutoScale = 150.0;
  double _ecgAutoScale = 2000.0;
  double _ppgAutoScale = 100.0;
  int _pageSampleCount = 0;
  DateTime? _pageStartedAt;
  int _samplesSinceScaleUpdate = 0;
  int _autoscaleSuppressionSamples = 0;

  // Signal quality, impedance & Welch PSD
  double _peakToPeakUv = 0.0;
  double _artifactRatio = 0.0;
  bool _signalStable = false;
  List<ChannelQualityMetrics> _channelQuality = const [];
  double _impedanceCalibration = 1.0;
  bool _showQualityPanel = false;
  bool _showImpedanceInGutter = true;
  bool _showPsdPanel = false;
  int _psdChannelIndex = 0;
  WelchPsdResult? _latestPsd;
  int _samplesSinceAnalytics = 0;

  // Online ASR + OSCAR cleaning (display & real-time analysis only)
  NativeOnlineEegCleaner? _onlineCleaner;
  OnlineCleanerConfig _cleanerConfig = const OnlineCleanerConfig();
  List<double> _cleanedSampleBuf = const [];
  double _cleaningIntensity = 0.0;
  int _asrCalProgress = 0;

  bool _hasEeg = false;
  bool _hasNirs = false;
  final List<String> _tabs = [];

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    final settings = context.read<SettingsService>();
    final savedDisplay = settings.viewerDisplayProfile(widget.displayStateKey);
    const supportedDurations = [2, 4, 8, 10, 20, 30];
    final savedDuration =
        savedDisplay['durationSeconds'] as int? ??
        settings.waveformDurationSeconds;
    _durationSeconds = supportedDurations.contains(savedDuration)
        ? savedDuration
        : (supportedDurations.contains(widget.initialDurationSeconds)
              ? widget.initialDurationSeconds
              : 10);
    _notchEnabled =
        savedDisplay['notchEnabled'] as bool? ?? settings.notchEnabled;
    _bandpassEnabled =
        savedDisplay['bandpassEnabled'] as bool? ?? settings.bandpassEnabled;

    final rawOverrides = savedDisplay['channelFilterOverrides'];
    if (rawOverrides is Map) {
      _channelFilterOverrides = {
        for (final entry in rawOverrides.entries)
          if (entry.value is Map)
            entry.key.toString(): ChannelFilterConfig.fromJson(
              Map<String, dynamic>.from(entry.value as Map),
            ),
      };
    }

    _filterSettings = _displayFilterSettingsFrom(settings, savedDisplay);
    _montageReferences = Map<String, String>.from(
      savedDisplay['montageReferences'] as Map? ??
          settings.displayMontageReferences,
    );
    _channelRenameOverrides = Map<String, String>.from(
      savedDisplay['channelRenames'] as Map? ?? const {},
    );
    final rawColors = savedDisplay['channelColors'];
    if (rawColors is Map) {
      _channelColorOverrides = {
        for (final entry in rawColors.entries)
          if (entry.value is num)
            entry.key.toString(): (entry.value as num).toInt(),
      };
    }
    _hiddenChannelLabels = List<String>.from(
      savedDisplay['hiddenChannelLabels'] as List? ??
          settings.displayHiddenChannelLabels,
    ).toSet();
    _prominentChannelLabel = savedDisplay['prominentChannel'] as String?;
    _soloChannelLabel = savedDisplay['soloChannel'] as String?;
    _showImpedanceInGutter =
        savedDisplay['showImpedanceInGutter'] as bool? ?? true;
    _impedanceCalibration =
        (savedDisplay['impedanceCalibration'] as num?)?.toDouble() ?? 1.0;

    _autoscale =
        savedDisplay['autoscale'] as bool? ?? settings.waveformAutoscaleV2;
    _gain = (savedDisplay['gain'] as num?)?.toDouble() ?? settings.waveformGain;
    _viewMode = savedDisplay.containsKey('viewMode')
        ? (savedDisplay['viewMode'] == 'page' ? 'page' : 'rolling')
        : settings.waveformViewMode;
    _eegFixedScale =
        (savedDisplay['eegScale'] as num?)?.toDouble() ??
        settings.eegDisplayScaleUv;
    _ecgFixedScale =
        (savedDisplay['ecgScale'] as num?)?.toDouble() ??
        settings.ecgDisplayScaleUv;
    _ppgFixedScale =
        (savedDisplay['ppgScale'] as num?)?.toDouble() ??
        settings.ppgDisplayScale;
    _eegAutoScale = _eegFixedScale;
    _ecgAutoScale = _ecgFixedScale;
    _ppgAutoScale = _ppgFixedScale;

    _hasEeg =
        widget.eegService != null ||
        widget.lslEegService != null ||
        widget.signalStream != null;
    _hasNirs = widget.nirsService != null;

    if (_hasEeg) _tabs.add('EEG');
    if (_hasNirs) _tabs.add('fNIRS');
    if (_hasEeg && _hasNirs) _tabs.add('Dual View');

    if (_tabs.length > 1) {
      _tabController = TabController(length: _tabs.length, vsync: this);
    } else {
      _tabController = null;
    }

    _initStreams();
    _repaintTimer = Timer.periodic(const Duration(milliseconds: 33), (_) {
      if (!mounted || !_dirtyWaveform) return;
      _dirtyWaveform = false;
      _waveformTick.value++;
    });
    _markerSub = widget.markerStream?.listen((marker) {
      if (!mounted) return;
      final existing = _markers.indexWhere(
        (item) =>
            item.receivedAt == marker.receivedAt && item.code == marker.code,
      );
      setState(() {
        if (existing >= 0) {
          _markers[existing] = marker;
        } else {
          _markers.add(marker);
        }
        _markers.removeWhere(
          (item) => DateTime.now().difference(item.receivedAt).inMinutes > 10,
        );
      });
    });
  }

  void _initStreams() {
    if (widget.eegService != null) {
      _btEegSub = widget.eegService!.samples.listen(_processEegSample);
    }
    if (widget.lslEegService != null) {
      _lslEegSub = widget.lslEegService!.samples.listen(_processEegSample);
    }
    if (widget.signalStream != null) {
      _signalSub = widget.signalStream!.listen(_processSignalStreamSample);
    }
    if (widget.nirsService != null) {
      _nirsSub = widget.nirsService!.samples.listen(_processNirsSample);
    }
  }

  void _processEegSample(EegSample sample) {
    _processEegSampleWithMetadata(sample);
  }

  String _effectiveChannelName(int index) {
    final raw = index < _eegChannelLabels.length
        ? _eegChannelLabels[index]
        : 'Ch ${index + 1}';
    final renamed = _channelRenameOverrides[raw];
    if (renamed != null && renamed.trim().isNotEmpty) return renamed.trim();
    return raw;
  }

  List<String> get _effectiveBaseLabels => List<String>.generate(
    _eegChannelLabels.length,
    _effectiveChannelName,
    growable: false,
  );

  List<String> get _displayChannelLabels {
    final base = _effectiveBaseLabels;
    return List<String>.generate(base.length, (i) {
      final raw = _eegChannelLabels[i];
      final ref = _montageReferences[raw];
      if (ref == null || ref == raw) return base[i];
      if (ref == DisplayMontage.carReferenceKey) return '${base[i]}-CAR';
      final refIdx = _eegChannelLabels.indexOf(ref);
      final refDisplay = refIdx >= 0 ? _effectiveChannelName(refIdx) : ref;
      return '${base[i]}-$refDisplay';
    }, growable: false);
  }

  void _processEegSampleWithMetadata(
    EegSample sample, {
    List<String>? explicitLabels,
    List<SignalType>? explicitTypes,
  }) {
    if (!mounted) return;
    final wasEmpty = _eegBuffers.isEmpty || _eegBuffers[0].isEmpty;
    final chCount = sample.channels.length;
    final sampleRate = _eegSampleRate;
    final displayCap = math.max(sampleRate * 30, 7500);
    final rawCap = math.max(sampleRate * 4, 1024);
    if (_viewMode == 'page') {
      if (_pageSampleCount == 0 || _pageStartedAt == null) {
        _pageStartedAt = DateTime.now();
      }
      if (_pageSampleCount >= sampleRate * _durationSeconds) {
        for (final buffer in _eegBuffers) {
          buffer.clear();
        }
        _pageSampleCount = 0;
        _pageStartedAt = DateTime.now();
      }
    }
    var structureChanged = false;
    while (_eegBuffers.length < chCount) {
      _eegBuffers.add(Float64RingBuffer(displayCap));
      _rawEegBuffers.add(Float64RingBuffer(rawCap));
      _runningMeans.add(double.nan);
      _visibleEegChannels.add(true);
      _eegChannelLabels.add('Ch ${_eegBuffers.length}');
      _scaleFactorsList.add(_eegFixedScale);
      structureChanged = true;
    }
    if (explicitLabels != null) {
      for (var i = 0; i < chCount; i++) {
        _eegChannelLabels[i] = i < explicitLabels.length
            ? explicitLabels[i]
            : 'Ch ${i + 1}';
      }
      _eegChannelTypes
        ..clear()
        ..addAll(
          SignalStreamProfile.normalizeChannelTypes(
            _eegChannelLabels,
            explicitTypes,
          ),
        );
    } else if (_eegChannelLabels.length == chCount &&
        widget.eegService != null) {
      final names = widget.eegService!.displayChannelLabels(chCount);
      final types = widget.eegService!.displayChannelTypes(chCount);
      for (var i = 0; i < chCount; i++) {
        _eegChannelLabels[i] = names[i];
      }
      _eegChannelTypes
        ..clear()
        ..addAll(types);
    } else if (_eegChannelLabels.length == chCount &&
        widget.lslEegService != null) {
      final names = widget.lslEegService!.channelNames;
      if (names.length == chCount) {
        for (var i = 0; i < chCount; i++) {
          _eegChannelLabels[i] = names[i];
        }
      }
    }

    for (var i = 0; i < chCount; i++) {
      _visibleEegChannels[i] = !_hiddenChannelLabels.contains(
        _eegChannelLabels[i],
      );
    }

    List<double> stageChannels = sample.channels;
    if (_cleanerConfig.enabled && chCount > 0) {
      if (_onlineCleaner == null ||
          _onlineCleaner!.channelCount != chCount ||
          (_onlineCleaner!.sampleRate - sampleRate).abs() > 0.5) {
        _onlineCleaner?.dispose();
        _onlineCleaner = NativeOnlineEegCleaner(
          channelCount: chCount,
          sampleRate: sampleRate.toDouble(),
        )..applyConfig(_cleanerConfig);
        _cleanedSampleBuf = List<double>.filled(chCount, 0.0);
      }
      _cleaningIntensity = _onlineCleaner!.processSample(
        sample.channels,
        _cleanedSampleBuf,
      );
      _asrCalProgress = _onlineCleaner!.calibrationProgress;
      stageChannels = _cleanedSampleBuf;
    }

    final montageValues = DisplayMontage.apply(
      stageChannels,
      _eegChannelLabels,
      _montageReferences,
      channelTypes: _eegChannelTypes,
    );
    final filtered = _displayFilter.process(
      montageValues,
      labels: _eegChannelLabels,
      channelTypes: _eegChannelTypes,
      sampleRate: sampleRate.toDouble(),
      notch: _notchEnabled,
      bandpass: _bandpassEnabled,
      settings: _filterSettings,
    );

    for (var i = 0; i < chCount; i++) {
      _rawEegBuffers[i].push(sample.channels[i]);

      final val = filtered[i];
      final type = i < _eegChannelTypes.length
          ? biosignalTypeForSignalType(_eegChannelTypes[i])
          : biosignalTypeForLabel(_eegChannelLabels[i]);
      final override = _channelFilterOverrides[_eegChannelLabels[i]];
      final hasActiveBandpass =
          _bandpassEnabled &&
          (override != null
              ? override.highPassEnabled
              : _filterSettings.bandFor(type) != null);
      final alreadyCentered = hasActiveBandpass || type == BiosignalType.ppg;
      if (!alreadyCentered) {
        if (!_runningMeans[i].isFinite) {
          _runningMeans[i] = val;
        } else {
          _runningMeans[i] = _runningMeans[i] * 0.998 + val * 0.002;
        }
      }
      final zeroCentered = alreadyCentered ? val : val - _runningMeans[i];

      _eegBuffers[i].push(zeroCentered);
    }

    _pageSampleCount++;
    _samplesSinceScaleUpdate++;
    _samplesSinceAnalytics++;
    if (_autoscaleSuppressionSamples > 0) {
      _autoscaleSuppressionSamples--;
    }
    if (_autoscale && _samplesSinceScaleUpdate >= 25) {
      _samplesSinceScaleUpdate = 0;
      _updateAutomaticScales();
    }
    if (_samplesSinceAnalytics >= math.max(60, (sampleRate * 0.5).round())) {
      _samplesSinceAnalytics = 0;
      _updateAnalytics();
    }
    if (wasEmpty || structureChanged) {
      _syncScaleFactorsList();
      setState(() {});
    } else {
      _dirtyWaveform = true;
    }
  }

  void _processSignalStreamSample(SignalStreamSample sample) {
    final profile = widget.signalProfile;
    if (profile != null && sample.streamId != profile.id) return;
    final labels = sample.channelLabels.length == sample.channels.length
        ? sample.channelLabels
        : List<String>.generate(sample.channels.length, (index) {
            if (index < sample.channelLabels.length) {
              return sample.channelLabels[index];
            }
            return 'Ch ${index + 1}';
          });
    _processEegSampleWithMetadata(
      EegSample(
        channels: sample.channels,
        sampleRate: sample.sampleRate,
        timestamp: sample.timestamp,
        source: profile?.name ?? sample.streamId,
      ),
      explicitLabels: labels,
      explicitTypes: sample.channelTypes,
    );
  }

  int get _eegSampleRate =>
      (widget.eegService?.sampleRate ??
              widget.lslEegService?.sampleRate ??
              widget.signalProfile?.sampleRate ??
              250)
          .round()
          .clamp(1, 4000);

  bool _isPpgLabel(String label) => label.toUpperCase().contains('PPG');
  bool _isEcgLabel(String label) => label.toUpperCase().contains('ECG');

  DisplayFilterSettings _displayFilterSettingsFrom(
    SettingsService settings, [
    Map<String, dynamic> saved = const {},
  ]) {
    double value(String key, double fallback) =>
        (saved[key] as num?)?.toDouble() ?? fallback;
    return DisplayFilterSettings(
      eegHighPassHz: value('eegHighPassHz', settings.eegDisplayHighPassHz),
      eegLowPassHz: value('eegLowPassHz', settings.eegDisplayLowPassHz),
      eogHighPassHz: value('eogHighPassHz', settings.eogDisplayHighPassHz),
      eogLowPassHz: value('eogLowPassHz', settings.eogDisplayLowPassHz),
      emgHighPassHz: value('emgHighPassHz', settings.emgDisplayHighPassHz),
      emgLowPassHz: value('emgLowPassHz', settings.emgDisplayLowPassHz),
      ecgHighPassHz: value('ecgHighPassHz', settings.ecgDisplayHighPassHz),
      ecgLowPassHz: value('ecgLowPassHz', settings.ecgDisplayLowPassHz),
      notchFrequencyHz: value(
        'notchFrequencyHz',
        settings.displayNotchFrequencyHz,
      ),
      channelOverrides: Map<String, ChannelFilterConfig>.of(
        _channelFilterOverrides,
      ),
    );
  }

  void _persistDisplaySettings() {
    final settings = context.read<SettingsService>();
    final hidden = _hiddenChannelLabels.toList()..sort();
    final profile = <String, dynamic>{
      'durationSeconds': _durationSeconds,
      'viewMode': _viewMode,
      'autoscale': _autoscale,
      'notchEnabled': _notchEnabled,
      'bandpassEnabled': _bandpassEnabled,
      'gain': _gain,
      'eegScale': _eegFixedScale,
      'ecgScale': _ecgFixedScale,
      'ppgScale': _ppgFixedScale,
      'eegHighPassHz': _filterSettings.eegHighPassHz,
      'eegLowPassHz': _filterSettings.eegLowPassHz,
      'eogHighPassHz': _filterSettings.eogHighPassHz,
      'eogLowPassHz': _filterSettings.eogLowPassHz,
      'emgHighPassHz': _filterSettings.emgHighPassHz,
      'emgLowPassHz': _filterSettings.emgLowPassHz,
      'ecgHighPassHz': _filterSettings.ecgHighPassHz,
      'ecgLowPassHz': _filterSettings.ecgLowPassHz,
      'notchFrequencyHz': _filterSettings.notchFrequencyHz,
      'channelFilterOverrides': _channelFilterOverrides.map(
        (key, cfg) => MapEntry(key, cfg.toJson()),
      ),
      'montageReferences': Map<String, String>.of(_montageReferences),
      'channelRenames': Map<String, String>.of(_channelRenameOverrides),
      'channelColors': Map<String, int>.of(_channelColorOverrides),
      'hiddenChannelLabels': hidden,
      'prominentChannel': _prominentChannelLabel,
      'soloChannel': _soloChannelLabel,
      'showImpedanceInGutter': _showImpedanceInGutter,
      'impedanceCalibration': _impedanceCalibration,
    };
    final key = widget.displayStateKey;
    if (key != null && key.trim().isNotEmpty) {
      settings.updateViewerDisplayProfile(key, profile);
      return;
    }
    settings.update((s) {
      s.waveformDurationSeconds = _durationSeconds;
      s.waveformViewMode = _viewMode;
      s.waveformAutoscaleV2 = _autoscale;
      s.notchEnabled = _notchEnabled;
      s.bandpassEnabled = _bandpassEnabled;
      s.waveformGain = _gain;
      s.eegDisplayScaleUv = _eegFixedScale;
      s.ecgDisplayScaleUv = _ecgFixedScale;
      s.ppgDisplayScale = _ppgFixedScale;
      s.eegDisplayHighPassHz = _filterSettings.eegHighPassHz;
      s.eegDisplayLowPassHz = _filterSettings.eegLowPassHz;
      s.eogDisplayHighPassHz = _filterSettings.eogHighPassHz;
      s.eogDisplayLowPassHz = _filterSettings.eogLowPassHz;
      s.emgDisplayHighPassHz = _filterSettings.emgHighPassHz;
      s.emgDisplayLowPassHz = _filterSettings.emgLowPassHz;
      s.ecgDisplayHighPassHz = _filterSettings.ecgHighPassHz;
      s.ecgDisplayLowPassHz = _filterSettings.ecgLowPassHz;
      s.displayNotchFrequencyHz = _filterSettings.notchFrequencyHz;
      s.displayMontageReferences = Map.of(_montageReferences);
      s.displayHiddenChannelLabels = hidden;
    });
  }

  void _resetDisplayFilterForControlChange() {
    _displayFilter.reset();
    for (var i = 0; i < _runningMeans.length; i++) {
      _runningMeans[i] = double.nan;
    }
    _autoscaleSuppressionSamples = _eegSampleRate;
  }

  void _updateAutomaticScales({bool force = false}) {
    if (_autoscaleSuppressionSamples > 0 && !force) return;
    var eeg = 20.0;
    var ecg = 100.0;
    var ppg = 5.0;
    final points = _eegSampleRate * _durationSeconds;
    for (var i = 0; i < _eegBuffers.length; i++) {
      final data = _eegBuffers[i];
      if (data.length < math.min(_eegSampleRate, points)) continue;
      final peak = RobustWaveformAutoscale.amplitudeFromRing(
        data,
        visiblePoints: points,
      );
      final label = i < _eegChannelLabels.length ? _eegChannelLabels[i] : '';
      if (_isPpgLabel(label)) {
        ppg = math.max(ppg, peak * 1.15);
      } else if (_isEcgLabel(label)) {
        ecg = math.max(ecg, peak * 1.15);
      } else {
        eeg = math.max(eeg, peak * 1.15);
      }
    }
    _eegAutoScale = eeg;
    _ecgAutoScale = ecg;
    _ppgAutoScale = ppg;
    _syncScaleFactorsList();
    if (_autoscale) {
      _analyticsTick.value++;
    }
  }

  void _syncScaleFactorsList() {
    while (_scaleFactorsList.length < _eegBuffers.length) {
      _scaleFactorsList.add(_eegFixedScale);
    }
    for (var index = 0; index < _eegBuffers.length; index++) {
      final label = index < _eegChannelLabels.length
          ? _eegChannelLabels[index]
          : '';
      if (_isPpgLabel(label)) {
        _scaleFactorsList[index] = _autoscale ? _ppgAutoScale : _ppgFixedScale;
      } else if (_isEcgLabel(label)) {
        _scaleFactorsList[index] = _autoscale ? _ecgAutoScale : _ecgFixedScale;
      } else {
        _scaleFactorsList[index] = _autoscale ? _eegAutoScale : _eegFixedScale;
      }
    }
  }

  void _processNirsSample(NirsSample sample) {
    if (!mounted) return;
    final wasEmpty = _nirsBuffers.isEmpty || _nirsBuffers.every((b) => b.isEmpty);
    final chCount = sample.channels.length;
    while (_nirsBuffers.length < chCount) {
      _nirsBuffers.add([]);
    }
    if (sample.channelNames.length == chCount) {
      _nirsChannelLabels.clear();
      _nirsChannelLabels.addAll(sample.channelNames);
    } else {
      while (_nirsChannelLabels.length < chCount) {
        _nirsChannelLabels.add('NIRS ${_nirsChannelLabels.length + 1}');
      }
    }
    for (var i = 0; i < chCount; i++) {
      _nirsBuffers[i].add(sample.channels[i]);
      if (_nirsBuffers[i].length > 500) {
        _nirsBuffers[i].removeAt(0);
      }
    }
    if (wasEmpty) {
      setState(() {});
    } else {
      _dirtyWaveform = true;
    }
  }

  void _updateAnalytics() {
    if (_eegBuffers.isEmpty || _eegBuffers[0].isEmpty) return;

    // Overall summary metrics on first visible EEG channel
    final firstVisible = _visibleEegChannels.indexWhere((v) => v);
    final summaryIdx = firstVisible >= 0 ? firstVisible : 0;
    final ring = _eegBuffers[summaryIdx];
    final len = ring.length;
    if (len > 0) {
      var sum = 0.0;
      var minVal = double.infinity;
      var maxVal = double.negativeInfinity;
      for (var i = 0; i < len; i++) {
        final v = ring[i];
        sum += v;
        if (v < minVal) minVal = v;
        if (v > maxVal) maxVal = v;
      }
      final mean = sum / len;
      _peakToPeakUv = maxVal - minVal;
      var outliers = 0;
      for (var i = 0; i < len; i++) {
        if ((ring[i] - mean).abs() > 200.0) outliers++;
      }
      _artifactRatio = outliers / len;
      _signalStable = _peakToPeakUv < 150.0 && _artifactRatio < 0.10;
    }

    // Batch Signal Quality & Passive Impedance via Rust FFI (with Dart fallback)
    final sr = _eegSampleRate.toDouble();
    final windowSamples = math.max(64, (sr * 1.5).round());
    final saturatedLabels =
        widget.eegService?.adcSaturatedChannelLabels.toSet() ?? const <String>{};
    final minLen = _rawEegBuffers
        .map((b) => math.min(b.length, windowSamples))
        .fold<int>(windowSamples, math.min);
    if (minLen >= 16) {
      final rawWindows = List<Float64List>.generate(
        _rawEegBuffers.length,
        (i) => _rawEegBuffers[i].toRecentFloat64List(minLen),
        growable: false,
      );
      final satFlags = List<bool>.generate(
        _rawEegBuffers.length,
        (i) => i < _eegChannelLabels.length &&
            saturatedLabels.contains(_eegChannelLabels[i]),
        growable: false,
      );
      _channelQuality = NativeDsp.instance.analyzeQualityBatch(
        rawWindows,
        sampleRate: sr,
        mainsHz: _filterSettings.notchFrequencyHz,
        calibrationFactor: _impedanceCalibration,
        saturatedFlags: satFlags,
      );
    }

    if (_showPsdPanel) {
      _computePsdNow();
    }
    _analyticsTick.value++;
  }

  void _computePsdNow() {
    if (_eegBuffers.isEmpty) {
      _latestPsd = null;
      return;
    }
    final idx = _psdChannelIndex.clamp(0, _eegBuffers.length - 1);
    final sr = _eegSampleRate.toDouble();
    final ring = _eegBuffers[idx];
    final window = math.min(ring.length, (sr * 4).round());
    final slice = ring.toRecentFloat64List(window);
    _latestPsd = NativeDsp.instance.computeWelchPsd(
      slice,
      sampleRate: sr,
      preferredSegmentLength: 512,
    );
  }

  void _calibrateImpedanceBaseline() {
    if (_channelQuality.isEmpty) return;
    final finiteZ = _channelQuality
        .where((m) => !m.saturated && !m.flatline && m.estimatedImpedanceKOhm.isFinite)
        .map((m) => m.estimatedImpedanceKOhm)
        .toList()
      ..sort();
    if (finiteZ.isEmpty) return;
    final medianZ = finiteZ[finiteZ.length ~/ 2];
    if (medianZ > 0.2) {
      setState(() {
        _impedanceCalibration = (_impedanceCalibration * (5.0 / medianZ)).clamp(
          0.1,
          5.0,
        );
      });
      _updateAnalytics();
      _persistDisplaySettings();
    }
  }

  @override
  void dispose() {
    _btEegSub?.cancel();
    _lslEegSub?.cancel();
    _nirsSub?.cancel();
    _signalSub?.cancel();
    _markerSub?.cancel();
    _repaintTimer?.cancel();
    _waveformTick.dispose();
    _analyticsTick.dispose();
    _tabController?.dispose();
    _onlineCleaner?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    const lightTeal = StudioColors.teal;

    if (_tabs.isEmpty) {
      return Container(
        decoration: BoxDecoration(
          color: StudioColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: StudioColors.border),
        ),
        child: const Center(
          child: Text(
            'No EEG or fNIRS service attached',
            style: TextStyle(color: StudioColors.textSecondary),
          ),
        ),
      );
    }

    final viewer = Column(
      children: [
        if (_tabs.length > 1)
          Container(
            margin: const EdgeInsets.only(bottom: 6),
            decoration: BoxDecoration(
              color: StudioColors.card,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: StudioColors.border),
            ),
            child: TabBar(
              controller: _tabController,
              indicatorColor: lightTeal,
              labelColor: lightTeal,
              unselectedLabelColor: StudioColors.textSecondary,
              indicatorSize: TabBarIndicatorSize.tab,
              tabs: _tabs.map((name) => Tab(text: name, height: 34)).toList(),
            ),
          ),
        if (widget.showControls && _hasEeg && !widget.fullScreen)
          _buildControlsBar(lightTeal),
        Expanded(
          child: _tabs.length > 1
              ? TabBarView(
                  controller: _tabController,
                  physics: const NeverScrollableScrollPhysics(),
                  children: _tabs.map((tab) {
                    if (tab == 'EEG') return _buildEegWorkspace(lightTeal);
                    if (tab == 'fNIRS') return _buildNirsView();
                    return _buildDualView(lightTeal);
                  }).toList(),
                )
              : (_hasEeg ? _buildEegWorkspace(lightTeal) : _buildNirsView()),
        ),
        if (widget.showMetrics && !widget.fullScreen) ...[
          const SizedBox(height: 6),
          _buildSlimMetricsBar(),
        ],
      ],
    );

    if (!widget.fullScreen) return viewer;
    return Stack(
      children: [
        Positioned.fill(child: viewer),
        Positioned(
          right: 8,
          top: 8,
          child: Material(
            color: const Color(0xCC111827),
            borderRadius: BorderRadius.circular(24),
            child: IconButton(
              tooltip: 'Exit full screen',
              color: Colors.white,
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.fullscreen_exit),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildControlsBar(Color activeColor) {
    final isSolo = _soloChannelLabel != null;
    final hiddenCount = _hiddenChannelLabels.length;
    final visibleCount = _eegChannelLabels.length - hiddenCount;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: StudioColors.card,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: StudioColors.border),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _pillButton(
              icon: isSolo ? Icons.view_agenda_outlined : Icons.layers_outlined,
              label: isSolo ? 'Solo: $_soloChannelLabel' : 'Stacked',
              active: isSolo,
              color: StudioColors.sky,
              onTap: () {
                setState(() {
                  if (isSolo) {
                    _soloChannelLabel = null;
                  } else if (_eegChannelLabels.isNotEmpty) {
                    _soloChannelLabel = _eegChannelLabels.first;
                  }
                });
                _persistDisplaySettings();
              },
            ),
            const SizedBox(width: 6),
            _dividerV(),
            const Text(
              'Epoch ',
              style: TextStyle(color: StudioColors.textSecondary, fontSize: 11.5),
            ),
            DropdownButton<int>(
              value: _durationSeconds,
              isDense: true,
              dropdownColor: StudioColors.elevated,
              style: const TextStyle(color: StudioColors.textPrimary, fontSize: 12),
              underline: const SizedBox(),
              items: const [2, 4, 8, 10, 20, 30]
                  .map(
                    (seconds) => DropdownMenuItem(
                      value: seconds,
                      child: Text('${seconds}s'),
                    ),
                  )
                  .toList(),
              onChanged: (value) {
                if (value == null) return;
                setState(() {
                  _durationSeconds = value;
                  _pageSampleCount = 0;
                  if (_viewMode == 'page') {
                    _pageStartedAt = DateTime.now();
                    for (final buffer in _eegBuffers) {
                      buffer.clear();
                    }
                  }
                });
                _persistDisplaySettings();
              },
            ),
            const SizedBox(width: 6),
            DropdownButton<String>(
              value: _viewMode,
              isDense: true,
              dropdownColor: StudioColors.elevated,
              style: const TextStyle(color: StudioColors.textPrimary, fontSize: 12),
              underline: const SizedBox(),
              items: const [
                DropdownMenuItem(value: 'rolling', child: Text('Rolling')),
                DropdownMenuItem(value: 'page', child: Text('Page')),
              ],
              onChanged: (value) {
                if (value != null) _setViewMode(value);
              },
            ),
            _dividerV(),
            _pillButton(
              icon: Icons.auto_fix_high,
              label: 'Auto',
              active: _autoscale,
              color: activeColor,
              onTap: () => _setAutoscale(!_autoscale),
            ),
            IconButton(
              tooltip: 'Magnify amplitude',
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              padding: EdgeInsets.zero,
              color: activeColor,
              onPressed: () => _refineManualScale(0.8),
              icon: const Icon(Icons.add_circle_outline, size: 17),
            ),
            GestureDetector(
              onTap: () => _showScaleSettings(activeColor),
              child: ValueListenableBuilder<int>(
                valueListenable: _analyticsTick,
                builder: (_, __, ___) => Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: StudioColors.surface,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: StudioColors.border),
                  ),
                  child: Text(
                    _autoscale
                        ? '±${_eegAutoScale.round()}µV'
                        : '±${_eegFixedScale.round()}µV',
                    style: const TextStyle(
                      color: StudioColors.textPrimary,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
            IconButton(
              tooltip: 'Reduce amplitude',
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              padding: EdgeInsets.zero,
              color: activeColor,
              onPressed: () => _refineManualScale(1.25),
              icon: const Icon(Icons.remove_circle_outline, size: 17),
            ),
            _dividerV(),
            _pillButton(
              icon: Icons.electrical_services,
              label: '${_filterSettings.notchFrequencyHz.toInt()}Hz',
              active: _notchEnabled,
              color: activeColor,
              onTap: () {
                setState(() => _notchEnabled = !_notchEnabled);
                _resetDisplayFilterForControlChange();
                _persistDisplaySettings();
              },
            ),
            const SizedBox(width: 4),
            _pillButton(
              icon: Icons.graphic_eq,
              label: 'BP',
              active: _bandpassEnabled,
              color: activeColor,
              onTap: () {
                setState(() => _bandpassEnabled = !_bandpassEnabled);
                _resetDisplayFilterForControlChange();
                _persistDisplaySettings();
              },
            ),
            const SizedBox(width: 4),
            _pillButton(
              icon: Icons.tune,
              label: 'Filters',
              active: _channelFilterOverrides.isNotEmpty,
              color: StudioColors.sky,
              onTap: () => _showChannelAndFilterManager(
                activeColor,
                initialTab: 1,
              ),
            ),
            const SizedBox(width: 4),
            _pillButton(
              icon: Icons.cleaning_services_outlined,
              label: _cleanerConfig.enabled
                  ? (_asrCalProgress < 100 && _cleanerConfig.enableAsr
                        ? 'ASR ${_asrCalProgress}%'
                        : 'ASR On')
                  : 'ASR Clean',
              active: _cleanerConfig.enabled,
              color: StudioColors.amber,
              onTap: () => _showCleanerSettingsDialog(activeColor),
            ),
            const SizedBox(width: 4),
            _pillButton(
              icon: Icons.view_list_outlined,
              label: _eegChannelLabels.isEmpty
                  ? 'Channels'
                  : 'Channels ($visibleCount/${_eegChannelLabels.length})',
              active: hiddenCount > 0 || _montageReferences.isNotEmpty,
              color: activeColor,
              onTap: () => _showChannelAndFilterManager(
                activeColor,
                initialTab: 0,
              ),
            ),
            const SizedBox(width: 4),
            _pillButton(
              icon: Icons.health_and_safety_outlined,
              label: 'Z / SQI',
              active: _showQualityPanel,
              color: StudioColors.emerald,
              onTap: () {
                setState(() {
                  _showQualityPanel = !_showQualityPanel;
                  if (_showQualityPanel) _updateAnalytics();
                });
              },
            ),
            const SizedBox(width: 4),
            _pillButton(
              icon: Icons.equalizer,
              label: 'PSD',
              active: _showPsdPanel,
              color: StudioColors.sky,
              onTap: () {
                setState(() {
                  _showPsdPanel = !_showPsdPanel;
                  if (_showPsdPanel) _computePsdNow();
                });
              },
            ),
            if (widget.extraToolbarActions.isNotEmpty) ...[
              _dividerV(),
              ...widget.extraToolbarActions,
            ],
            _dividerV(),
            IconButton(
              tooltip: 'Maximize waveform area',
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              padding: EdgeInsets.zero,
              color: activeColor,
              onPressed: _openFullScreen,
              icon: const Icon(Icons.fullscreen, size: 19),
            ),
          ],
        ),
      ),
    );
  }

  Widget _dividerV() => Container(
    width: 1,
    height: 18,
    margin: const EdgeInsets.symmetric(horizontal: 6),
    color: StudioColors.border,
  );

  Widget _pillButton({
    required IconData icon,
    required String label,
    required bool active,
    required Color color,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(7),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: active ? color.withValues(alpha: 0.16) : StudioColors.surface,
          borderRadius: BorderRadius.circular(7),
          border: Border.all(
            color: active ? color.withValues(alpha: 0.65) : StudioColors.border,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 14,
              color: active ? color : StudioColors.textSecondary,
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                color: active ? color : StudioColors.textSecondary,
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openFullScreen() async {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => Scaffold(
          backgroundColor: StudioColors.canvas,
          body: SafeArea(
            minimum: const EdgeInsets.all(4),
            child: EegViewer(
              eegService: widget.eegService,
              lslEegService: widget.lslEegService,
              nirsService: widget.nirsService,
              signalStream: widget.signalStream,
              signalProfile: widget.signalProfile,
              displayStateKey: widget.displayStateKey,
              initialDurationSeconds: _durationSeconds,
              showControls: false,
              showMetrics: false,
              markerStream: widget.markerStream,
              fullScreen: true,
            ),
          ),
        ),
      ),
    );
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }

  Future<void> _showCleanerSettingsDialog(Color activeColor) async {
    var cfg = _cleanerConfig.copyWith(
      lineFreqHz: _filterSettings.notchFrequencyHz,
    );
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          void syncConfig(OnlineCleanerConfig next) {
            cfg = next;
            setState(() => _cleanerConfig = next);
            _onlineCleaner?.applyConfig(next);
            setDialogState(() {});
          }

          return AlertDialog(
            backgroundColor: StudioColors.elevated,
            title: const Row(
              children: [
                Icon(Icons.cleaning_services, color: StudioColors.amber, size: 20),
                SizedBox(width: 8),
                Text(
                  'Realtime ASR & OSCAR Cleaning',
                  style: TextStyle(
                    color: StudioColors.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            content: SizedBox(
              width: 420,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text(
                        'Enable online artifact cleaning',
                        style: TextStyle(color: StudioColors.textPrimary),
                      ),
                      subtitle: const Text(
                        'Cleans waveform & PSD display in Rust; raw EDF+ stays intact.',
                        style: TextStyle(
                          color: StudioColors.textSecondary,
                          fontSize: 11.5,
                        ),
                      ),
                      activeThumbColor: StudioColors.amber,
                      value: cfg.enabled,
                      onChanged: (v) => syncConfig(cfg.copyWith(enabled: v)),
                    ),
                    const Divider(color: StudioColors.border),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: Text(
                        'CleanLine (${cfg.lineFreqHz.round()} Hz + harmonic)',
                        style: const TextStyle(color: StudioColors.textPrimary),
                      ),
                      value: cfg.enableCleanLine,
                      onChanged: (v) =>
                          syncConfig(cfg.copyWith(enableCleanLine: v)),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: const Text(
                        'ASR Subspace Reconstruction',
                        style: TextStyle(color: StudioColors.textPrimary),
                      ),
                      value: cfg.enableAsr,
                      onChanged: (v) => syncConfig(cfg.copyWith(enableAsr: v)),
                    ),
                    if (cfg.enableAsr) ...[
                      Text(
                        'ASR Burst Cutoff k = ${cfg.asrCutoff.round()} (lower = stricter)',
                        style: const TextStyle(
                          color: StudioColors.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                      Slider(
                        value: cfg.asrCutoff.clamp(5.0, 30.0),
                        min: 5.0,
                        max: 30.0,
                        divisions: 25,
                        activeColor: StudioColors.amber,
                        onChanged: (v) =>
                            syncConfig(cfg.copyWith(asrCutoff: v)),
                      ),
                      Row(
                        children: [
                          Expanded(
                            child: LinearProgressIndicator(
                              value: (_asrCalProgress / 100.0).clamp(0.0, 1.0),
                              backgroundColor: StudioColors.surface,
                              color: _asrCalProgress >= 100
                                  ? StudioColors.emerald
                                  : StudioColors.amber,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _asrCalProgress >= 100
                                ? 'Calibrated'
                                : 'Cal ${_asrCalProgress}%',
                            style: const TextStyle(
                              color: StudioColors.textSecondary,
                              fontSize: 11,
                            ),
                          ),
                          const SizedBox(width: 8),
                          TextButton(
                            onPressed: () {
                              _onlineCleaner?.reset();
                              setState(() => _asrCalProgress = 0);
                              setDialogState(() {});
                            },
                            child: const Text('Recalibrate'),
                          ),
                        ],
                      ),
                    ],
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: const Text(
                        'OSCAR Frontal EOG / Blink Regression',
                        style: TextStyle(color: StudioColors.textPrimary),
                      ),
                      value: cfg.enableEog,
                      onChanged: (v) => syncConfig(cfg.copyWith(enableEog: v)),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: const Text(
                        'Slew-Rate & High-Freq EMG Pop Suppression',
                        style: TextStyle(color: StudioColors.textPrimary),
                      ),
                      value: cfg.enableEmg,
                      onChanged: (v) => syncConfig(cfg.copyWith(enableEmg: v)),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('Done'),
              ),
            ],
          );
        },
      ),
    );
  }

  /// Upgraded 2-tab Channel, Montage & Per-Channel Filter Manager inspired by
  /// CCS_SleepStudio & CCS_EEGStudio.
  Future<void> _showChannelAndFilterManager(
    Color activeColor, {
    int initialTab = 0,
  }) async {
    final references = Map<String, String>.of(_montageReferences);
    final renames = Map<String, String>.of(_channelRenameOverrides);
    final colors = Map<String, int>.of(_channelColorOverrides);
    final hidden = Set<String>.of(_hiddenChannelLabels);
    final overrides = Map<String, ChannelFilterConfig>.of(_channelFilterOverrides);
    var globalSettings = _filterSettings;
    var applyToAll = false;
    var saveNamesToProfile = false;
    var notchHz = globalSettings.notchFrequencyHz == 60 ? 60.0 : 50.0;
    String? prominent = _prominentChannelLabel;
    String? solo = _soloChannelLabel;

    final renameControllers = <String, TextEditingController>{
      for (final raw in _eegChannelLabels)
        raw: TextEditingController(text: renames[raw] ?? raw),
    };

    ChannelFilterConfig configFor(String rawLabel, int index) {
      if (overrides.containsKey(rawLabel)) return overrides[rawLabel]!;
      final type = index < _eegChannelTypes.length
          ? biosignalTypeForSignalType(_eegChannelTypes[index])
          : biosignalTypeForLabel(rawLabel);
      return globalSettings.effectiveFor(rawLabel, type);
    }

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => DefaultTabController(
        length: 2,
        initialIndex: initialTab,
        child: StatefulBuilder(
          builder: (context, setDialogState) {
            final dialogWidth = math.min(
              760.0,
              MediaQuery.sizeOf(context).width - 24,
            );
            final dialogHeight = math.min(
              560.0,
              MediaQuery.sizeOf(context).height * 0.78,
            );

            void setChannelFilter(
              String rawLabel,
              int idx,
              ChannelFilterConfig next,
            ) {
              setDialogState(() {
                if (applyToAll) {
                  for (final label in _eegChannelLabels) {
                    overrides[label] = next;
                  }
                } else {
                  overrides[rawLabel] = next;
                }
              });
            }

            return Dialog(
              backgroundColor: StudioColors.elevated,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: const BorderSide(color: StudioColors.border),
              ),
              child: SizedBox(
                width: dialogWidth,
                height: dialogHeight,
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(18, 14, 10, 0),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.tune,
                            color: StudioColors.teal,
                            size: 20,
                          ),
                          const SizedBox(width: 8),
                          const Expanded(
                            child: Text(
                              'Channels, Montage & Per-Channel Filters',
                              style: TextStyle(
                                color: StudioColors.textPrimary,
                                fontWeight: FontWeight.w700,
                                fontSize: 16,
                              ),
                            ),
                          ),
                          IconButton(
                            onPressed: () => Navigator.of(dialogContext).pop(),
                            icon: const Icon(
                              Icons.close,
                              color: StudioColors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const TabBar(
                      indicatorColor: StudioColors.teal,
                      labelColor: StudioColors.teal,
                      unselectedLabelColor: StudioColors.textSecondary,
                      tabs: [
                        Tab(text: 'Channels & Montage'),
                        Tab(text: 'Per-Channel Filters'),
                      ],
                    ),
                    Expanded(
                      child: TabBarView(
                        children: [
                          // ── Tab 1: Channels, Rename & Montage ─────────────
                          Padding(
                            padding: const EdgeInsets.all(14),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 6,
                                  children: [
                                    ActionChip(
                                      label: const Text('Show All'),
                                      onPressed: () =>
                                          setDialogState(hidden.clear),
                                    ),
                                    ActionChip(
                                      label: const Text('Clear Refs'),
                                      onPressed: () =>
                                          setDialogState(references.clear),
                                    ),
                                    ActionChip(
                                      label: const Text('CAR All EEG'),
                                      onPressed: () => setDialogState(() {
                                        for (var i = 0;
                                            i < _eegChannelLabels.length;
                                            i++) {
                                          final raw = _eegChannelLabels[i];
                                          final type = i < _eegChannelTypes.length
                                              ? biosignalTypeForSignalType(
                                                  _eegChannelTypes[i],
                                                )
                                              : biosignalTypeForLabel(raw);
                                          if (type == BiosignalType.eeg) {
                                            references[raw] =
                                                DisplayMontage.carReferenceKey;
                                          }
                                        }
                                      }),
                                    ),
                                    ActionChip(
                                      label: const Text('Reset Names'),
                                      onPressed: () => setDialogState(() {
                                        renames.clear();
                                        for (final raw in _eegChannelLabels) {
                                          renameControllers[raw]?.text = raw;
                                        }
                                      }),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                Expanded(
                                  child: ListView.separated(
                                    itemCount: _eegChannelLabels.length,
                                    separatorBuilder: (_, __) =>
                                        const SizedBox(height: 6),
                                    itemBuilder: (context, idx) {
                                      final raw = _eegChannelLabels[idx];
                                      final isVisible = !hidden.contains(raw);
                                      final candidates = _eegChannelLabels
                                          .where((c) => c != raw)
                                          .toList();
                                      final curRef = references[raw];
                                      final refVal =
                                          curRef ==
                                                      DisplayMontage
                                                          .carReferenceKey ||
                                                  candidates.contains(curRef)
                                              ? curRef!
                                              : '__none__';
                                      final colorVal = Color(
                                        colors[raw] ??
                                            WaveformPainter
                                                .colors[idx %
                                                    WaveformPainter
                                                        .colors
                                                        .length]
                                                .toARGB32(),
                                      );
                                      final isProm = prominent == raw;
                                      final isSolo = solo == raw;

                                      return Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 6,
                                        ),
                                        decoration: BoxDecoration(
                                          color: StudioColors.card,
                                          borderRadius: BorderRadius.circular(
                                            10,
                                          ),
                                          border: Border.all(
                                            color: isProm || isSolo
                                                ? StudioColors.teal
                                                : StudioColors.border,
                                          ),
                                        ),
                                        child: Row(
                                          children: [
                                            Checkbox(
                                              value: isVisible,
                                              visualDensity:
                                                  VisualDensity.compact,
                                              activeColor: activeColor,
                                              onChanged: (v) => setDialogState(
                                                () {
                                                  if (v ?? false) {
                                                    hidden.remove(raw);
                                                  } else {
                                                    hidden.add(raw);
                                                  }
                                                },
                                              ),
                                            ),
                                            InkWell(
                                              onTap: () {
                                                final palette =
                                                    WaveformPainter.colors;
                                                final nextIdx =
                                                    (palette.indexWhere(
                                                          (c) =>
                                                              c.toARGB32() ==
                                                              colorVal
                                                                  .toARGB32(),
                                                        ) +
                                                        1) %
                                                    palette.length;
                                                setDialogState(() {
                                                  colors[raw] = palette[nextIdx]
                                                      .toARGB32();
                                                });
                                              },
                                              child: Container(
                                                width: 16,
                                                height: 16,
                                                margin: const EdgeInsets.only(
                                                  right: 8,
                                                ),
                                                decoration: BoxDecoration(
                                                  color: colorVal,
                                                  shape: BoxShape.circle,
                                                  border: Border.all(
                                                    color: StudioColors.border,
                                                  ),
                                                ),
                                              ),
                                            ),
                                            Expanded(
                                              flex: 2,
                                              child: TextField(
                                                controller:
                                                    renameControllers[raw],
                                                style: TextStyle(
                                                  color: isVisible
                                                      ? StudioColors.textPrimary
                                                      : StudioColors.textMuted,
                                                  fontSize: 13,
                                                ),
                                                decoration: InputDecoration(
                                                  isDense: true,
                                                  labelText: 'Ch ${idx + 1} ($raw)',
                                                  contentPadding:
                                                      const EdgeInsets.symmetric(
                                                        horizontal: 8,
                                                        vertical: 8,
                                                      ),
                                                ),
                                                onChanged: (v) {
                                                  if (v.trim().isEmpty ||
                                                      v.trim() == raw) {
                                                    renames.remove(raw);
                                                  } else {
                                                    renames[raw] = v.trim();
                                                  }
                                                },
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            Expanded(
                                              flex: 2,
                                              child: DropdownButtonFormField<String>(
                                                initialValue: refVal,
                                                isDense: true,
                                                dropdownColor:
                                                    StudioColors.elevated,
                                                style: const TextStyle(
                                                  color:
                                                      StudioColors.textPrimary,
                                                  fontSize: 12,
                                                ),
                                                decoration:
                                                    const InputDecoration(
                                                      labelText: 'Ref',
                                                      contentPadding:
                                                          EdgeInsets.symmetric(
                                                            horizontal: 8,
                                                            vertical: 8,
                                                          ),
                                                    ),
                                                items: [
                                                  const DropdownMenuItem(
                                                    value: '__none__',
                                                    child: Text('None'),
                                                  ),
                                                  const DropdownMenuItem(
                                                    value: DisplayMontage
                                                        .carReferenceKey,
                                                    child: Text('CAR (Avg)'),
                                                  ),
                                                  ...candidates.map(
                                                    (c) => DropdownMenuItem(
                                                      value: c,
                                                      child: Text(
                                                        renames[c] ?? c,
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                                onChanged: isVisible
                                                    ? (v) => setDialogState(() {
                                                        if (v == null ||
                                                            v == '__none__') {
                                                          references.remove(
                                                            raw,
                                                          );
                                                        } else {
                                                          references[raw] = v;
                                                        }
                                                      })
                                                    : null,
                                              ),
                                            ),
                                            IconButton(
                                              tooltip:
                                                  'Toggle prominent (2.5× height)',
                                              visualDensity:
                                                  VisualDensity.compact,
                                              icon: Icon(
                                                isProm
                                                    ? Icons.star
                                                    : Icons.star_border,
                                                size: 18,
                                                color: isProm
                                                    ? StudioColors.amber
                                                    : StudioColors.textMuted,
                                              ),
                                              onPressed: () => setDialogState(
                                                () => prominent =
                                                    isProm ? null : raw,
                                              ),
                                            ),
                                            IconButton(
                                              tooltip: 'Solo this channel',
                                              visualDensity:
                                                  VisualDensity.compact,
                                              icon: Icon(
                                                Icons.center_focus_strong,
                                                size: 18,
                                                color: isSolo
                                                    ? StudioColors.sky
                                                    : StudioColors.textMuted,
                                              ),
                                              onPressed: () => setDialogState(
                                                () => solo = isSolo ? null : raw,
                                              ),
                                            ),
                                          ],
                                        ),
                                      );
                                    },
                                  ),
                                ),
                                if (widget.eegService?.connectedDeviceProfile !=
                                    null)
                                  CheckboxListTile(
                                    dense: true,
                                    contentPadding: EdgeInsets.zero,
                                    value: saveNamesToProfile,
                                    activeColor: activeColor,
                                    title: const Text(
                                      'Also update channel names in active Device Profile',
                                      style: TextStyle(
                                        color: StudioColors.textSecondary,
                                        fontSize: 12,
                                      ),
                                    ),
                                    onChanged: (v) => setDialogState(
                                      () => saveNamesToProfile = v ?? false,
                                    ),
                                  ),
                              ],
                            ),
                          ),

                          // ── Tab 2: Per-Channel Filters ────────────────────
                          Padding(
                            padding: const EdgeInsets.all(14),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Row(
                                  children: [
                                    Checkbox(
                                      value: applyToAll,
                                      activeColor: activeColor,
                                      visualDensity: VisualDensity.compact,
                                      onChanged: (v) => setDialogState(
                                        () => applyToAll = v ?? false,
                                      ),
                                    ),
                                    const Expanded(
                                      child: Text(
                                        'Apply filter edits to all channels',
                                        style: TextStyle(
                                          color: StudioColors.textPrimary,
                                          fontSize: 12.5,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                    DropdownButton<double>(
                                      value: notchHz,
                                      isDense: true,
                                      dropdownColor: StudioColors.elevated,
                                      style: const TextStyle(
                                        color: StudioColors.textPrimary,
                                        fontSize: 12,
                                      ),
                                      items: const [
                                        DropdownMenuItem(
                                          value: 50,
                                          child: Text('Mains 50 Hz'),
                                        ),
                                        DropdownMenuItem(
                                          value: 60,
                                          child: Text('Mains 60 Hz'),
                                        ),
                                      ],
                                      onChanged: (v) {
                                        if (v == null) return;
                                        setDialogState(() {
                                          notchHz = v;
                                          globalSettings = DisplayFilterSettings(
                                            eegHighPassHz:
                                                globalSettings.eegHighPassHz,
                                            eegLowPassHz:
                                                globalSettings.eegLowPassHz,
                                            eogHighPassHz:
                                                globalSettings.eogHighPassHz,
                                            eogLowPassHz:
                                                globalSettings.eogLowPassHz,
                                            emgHighPassHz:
                                                globalSettings.emgHighPassHz,
                                            emgLowPassHz:
                                                globalSettings.emgLowPassHz,
                                            ecgHighPassHz:
                                                globalSettings.ecgHighPassHz,
                                            ecgLowPassHz:
                                                globalSettings.ecgLowPassHz,
                                            notchFrequencyHz: v,
                                            channelOverrides: overrides,
                                          );
                                        });
                                      },
                                    ),
                                  ],
                                ),
                                Wrap(
                                  spacing: 6,
                                  runSpacing: 4,
                                  children: [
                                    ActionChip(
                                      label: const Text('EEG 0.3–35 Hz'),
                                      onPressed: () => setDialogState(() {
                                        for (final l in _eegChannelLabels) {
                                          overrides[l] = ChannelFilterConfig(
                                            highPassHz: 0.3,
                                            lowPassHz: 35,
                                            notchHz: notchHz,
                                          );
                                        }
                                      }),
                                    ),
                                    ActionChip(
                                      label: const Text('Wide 0.1–70 Hz'),
                                      onPressed: () => setDialogState(() {
                                        for (final l in _eegChannelLabels) {
                                          overrides[l] = ChannelFilterConfig(
                                            highPassHz: 0.1,
                                            lowPassHz: 70,
                                            notchHz: notchHz,
                                          );
                                        }
                                      }),
                                    ),
                                    ActionChip(
                                      label: const Text('Reset All to Type Defaults'),
                                      onPressed: () => setDialogState(
                                        overrides.clear,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                Expanded(
                                  child: ListView.separated(
                                    itemCount: _eegChannelLabels.length,
                                    separatorBuilder: (_, __) =>
                                        const SizedBox(height: 6),
                                    itemBuilder: (context, idx) {
                                      final raw = _eegChannelLabels[idx];
                                      final disp = renames[raw] ?? raw;
                                      final cfg = configFor(raw, idx);
                                      return Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 6,
                                        ),
                                        decoration: BoxDecoration(
                                          color: StudioColors.card,
                                          borderRadius: BorderRadius.circular(
                                            10,
                                          ),
                                          border: Border.all(
                                            color: overrides.containsKey(raw)
                                                ? StudioColors.sky.withValues(
                                                    alpha: 0.5,
                                                  )
                                                : StudioColors.border,
                                          ),
                                        ),
                                        child: Wrap(
                                          spacing: 8,
                                          runSpacing: 6,
                                          crossAxisAlignment:
                                              WrapCrossAlignment.center,
                                          children: [
                                            SizedBox(
                                              width: 78,
                                              child: Text(
                                                disp,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                  color:
                                                      StudioColors.textPrimary,
                                                  fontWeight: FontWeight.w600,
                                                  fontSize: 12.5,
                                                ),
                                              ),
                                            ),
                                            _filterNumberChip(
                                              label: 'HPF',
                                              enabled: cfg.highPassEnabled,
                                              value: cfg.highPassHz,
                                              onToggle: (on) => setChannelFilter(
                                                raw,
                                                idx,
                                                cfg.copyWith(
                                                  highPassEnabled: on,
                                                ),
                                              ),
                                              onSubmitted: (v) =>
                                                  setChannelFilter(
                                                    raw,
                                                    idx,
                                                    cfg.copyWith(
                                                      highPassHz: v.clamp(
                                                        0.01,
                                                        cfg.lowPassHz - 0.1,
                                                      ),
                                                    ),
                                                  ),
                                            ),
                                            _filterNumberChip(
                                              label: 'LPF',
                                              enabled: cfg.lowPassEnabled,
                                              value: cfg.lowPassHz,
                                              onToggle: (on) => setChannelFilter(
                                                raw,
                                                idx,
                                                cfg.copyWith(
                                                  lowPassEnabled: on,
                                                ),
                                              ),
                                              onSubmitted: (v) =>
                                                  setChannelFilter(
                                                    raw,
                                                    idx,
                                                    cfg.copyWith(
                                                      lowPassHz: v.clamp(
                                                        cfg.highPassHz + 0.1,
                                                        500.0,
                                                      ),
                                                    ),
                                                  ),
                                            ),
                                            _filterNumberChip(
                                              label: 'Notch',
                                              enabled: cfg.notchEnabled,
                                              value: cfg.notchHz,
                                              onToggle: (on) => setChannelFilter(
                                                raw,
                                                idx,
                                                cfg.copyWith(notchEnabled: on),
                                              ),
                                              onSubmitted: (v) =>
                                                  setChannelFilter(
                                                    raw,
                                                    idx,
                                                    cfg.copyWith(
                                                      notchHz: v.clamp(
                                                        1.0,
                                                        500.0,
                                                      ),
                                                    ),
                                                  ),
                                            ),
                                            Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Checkbox(
                                                  value: cfg.invertPolarity,
                                                  visualDensity:
                                                      VisualDensity.compact,
                                                  onChanged: (inv) =>
                                                      setChannelFilter(
                                                        raw,
                                                        idx,
                                                        cfg.copyWith(
                                                          invertPolarity:
                                                              inv ?? false,
                                                        ),
                                                      ),
                                                ),
                                                const Text(
                                                  'Inv',
                                                  style: TextStyle(
                                                    color: StudioColors
                                                        .textSecondary,
                                                    fontSize: 11.5,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ],
                                        ),
                                      );
                                    },
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                      child: Row(
                        children: [
                          const Expanded(
                            child: Text(
                              'Display-only montage & filters (raw EDF stays untouched).',
                              style: TextStyle(
                                color: StudioColors.textMuted,
                                fontSize: 11,
                              ),
                            ),
                          ),
                          TextButton(
                            onPressed: () => Navigator.of(dialogContext).pop(),
                            child: const Text('Cancel'),
                          ),
                          const SizedBox(width: 8),
                          FilledButton(
                            style: FilledButton.styleFrom(
                              backgroundColor: StudioColors.teal,
                              foregroundColor: Colors.white,
                            ),
                            onPressed: () {
                              if (saveNamesToProfile) {
                                final profile = widget
                                    .eegService
                                    ?.connectedDeviceProfile;
                                if (profile != null) {
                                  final updated = DeviceProfile.fromJson(
                                    profile.toJson(),
                                  );
                                  var offset = 0;
                                  for (final stream in updated.enabledStreams) {
                                    for (var j = 0;
                                        j < stream.channelLabels.length &&
                                            offset < _eegChannelLabels.length;
                                        j++) {
                                      final raw = _eegChannelLabels[offset];
                                      final nextName =
                                          renames[raw] ?? raw;
                                      stream.channelLabels[j] = nextName;
                                      offset++;
                                    }
                                  }
                                  renames.clear();
                                  context
                                      .read<SettingsService>()
                                      .updateDeviceProfile(updated);
                                }
                              }
                              setState(() {
                                _montageReferences = Map.of(references);
                                _channelRenameOverrides = Map.of(renames);
                                _channelColorOverrides = Map.of(colors);
                                _hiddenChannelLabels = Set.of(hidden);
                                _prominentChannelLabel = prominent;
                                _soloChannelLabel = solo;
                                _channelFilterOverrides = Map.of(overrides);
                                _filterSettings = DisplayFilterSettings(
                                  eegHighPassHz: globalSettings.eegHighPassHz,
                                  eegLowPassHz: globalSettings.eegLowPassHz,
                                  eogHighPassHz: globalSettings.eogHighPassHz,
                                  eogLowPassHz: globalSettings.eogLowPassHz,
                                  emgHighPassHz: globalSettings.emgHighPassHz,
                                  emgLowPassHz: globalSettings.emgLowPassHz,
                                  ecgHighPassHz: globalSettings.ecgHighPassHz,
                                  ecgLowPassHz: globalSettings.ecgLowPassHz,
                                  notchFrequencyHz: notchHz,
                                  channelOverrides: Map.of(overrides),
                                );
                                for (var i = 0;
                                    i < _visibleEegChannels.length;
                                    i++) {
                                  final label = i < _eegChannelLabels.length
                                      ? _eegChannelLabels[i]
                                      : 'Ch ${i + 1}';
                                  _visibleEegChannels[i] =
                                      !hidden.contains(label);
                                }
                              });
                              _resetDisplayFilterForControlChange();
                              _persistDisplaySettings();
                              Navigator.of(dialogContext).pop();
                            },
                            child: const Text('Apply'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
    for (final ctrl in renameControllers.values) {
      ctrl.dispose();
    }
  }

  Widget _filterNumberChip({
    required String label,
    required bool enabled,
    required double value,
    required ValueChanged<bool> onToggle,
    required ValueChanged<double> onSubmitted,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: StudioColors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: enabled ? StudioColors.border : StudioColors.border.withValues(alpha: 0.4),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Checkbox(
            value: enabled,
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            onChanged: (v) => onToggle(v ?? false),
          ),
          Text(
            '$label:',
            style: TextStyle(
              color: enabled
                  ? StudioColors.textSecondary
                  : StudioColors.textMuted,
              fontSize: 11,
            ),
          ),
          const SizedBox(width: 4),
          SizedBox(
            width: 48,
            child: TextFormField(
              key: ValueKey('$label:${value.toStringAsFixed(2)}'),
              initialValue: value.toStringAsFixed(value < 10 ? 1 : 0),
              enabled: enabled,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              style: TextStyle(
                color: enabled
                    ? StudioColors.textPrimary
                    : StudioColors.textMuted,
                fontSize: 11.5,
              ),
              decoration: const InputDecoration(
                isDense: true,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                filled: false,
                contentPadding: EdgeInsets.symmetric(vertical: 4),
              ),
              onChanged: (txt) {
                final parsed = double.tryParse(txt.trim());
                if (parsed != null && parsed > 0) onSubmitted(parsed);
              },
            ),
          ),
          const Text(
            'Hz',
            style: TextStyle(color: StudioColors.textMuted, fontSize: 10),
          ),
        ],
      ),
    );
  }

  void _setViewMode(String mode) {
    setState(() {
      _viewMode = mode == 'page' ? 'page' : 'rolling';
      if (_viewMode == 'page' && _durationSeconds < 10) {
        _durationSeconds = 10;
      }
      _pageSampleCount = 0;
      if (_viewMode == 'page') {
        _pageStartedAt = DateTime.now();
        for (final buffer in _eegBuffers) {
          buffer.clear();
        }
      } else {
        _pageStartedAt = null;
      }
    });
    _persistDisplaySettings();
  }

  void _setAutoscale(bool enabled) {
    setState(() {
      if (_autoscale && !enabled) {
        _captureAutomaticScale();
      }
      _autoscale = enabled;
      if (enabled) {
        _autoscaleSuppressionSamples = 0;
        _updateAutomaticScales(force: true);
      } else {
        _syncScaleFactorsList();
      }
    });
    _waveformTick.value++;
    _analyticsTick.value++;
    _persistDisplaySettings();
  }

  void _captureAutomaticScale() {
    _updateAutomaticScales();
    final snapshot = WaveformScaleSnapshot.capture(
      eegUv: _eegAutoScale,
      ecgUv: _ecgAutoScale,
      ppg: _ppgAutoScale,
    );
    _eegFixedScale = snapshot.eegUv;
    _ecgFixedScale = snapshot.ecgUv;
    _ppgFixedScale = snapshot.ppg;
    _syncScaleFactorsList();
  }

  void _refineManualScale(double factor) {
    setState(() {
      if (_autoscale) {
        _captureAutomaticScale();
        _autoscale = false;
      }
      _eegFixedScale = (_eegFixedScale * factor).clamp(10.0, 15000.0);
      _ecgFixedScale = (_ecgFixedScale * factor).clamp(100.0, 30000.0);
      _ppgFixedScale = (_ppgFixedScale * factor).clamp(5.0, 32768.0);
      _syncScaleFactorsList();
    });
    _waveformTick.value++;
    _analyticsTick.value++;
    _persistDisplaySettings();
  }

  Future<void> _showScaleSettings(Color activeColor) async {
    var eegScale = _eegFixedScale;
    var ecgScale = _ecgFixedScale;
    var ppgScale = _ppgFixedScale;
    var automatic = _autoscale;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: StudioColors.elevated,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, updateSheet) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Waveform Display Scale',
                  style: TextStyle(
                    color: StudioColors.textPrimary,
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text(
                    'Autoscale',
                    style: TextStyle(color: StudioColors.textPrimary),
                  ),
                  subtitle: const Text(
                    'Turning this off captures and keeps the current automatic scale.',
                    style: TextStyle(color: StudioColors.textSecondary),
                  ),
                  activeThumbColor: activeColor,
                  value: automatic,
                  onChanged: (value) {
                    _setAutoscale(value);
                    updateSheet(() {
                      automatic = value;
                      eegScale = _eegFixedScale;
                      ecgScale = _ecgFixedScale;
                      ppgScale = _ppgFixedScale;
                    });
                  },
                ),
                _buildScaleSlider(
                  label: 'EEG full scale',
                  unit: 'µV',
                  value: eegScale,
                  minimum: 10,
                  maximum: 15000,
                  enabled: !automatic,
                  activeColor: activeColor,
                  onChanged: (value) {
                    updateSheet(() => eegScale = value);
                    setState(() {
                      _eegFixedScale = value;
                      _syncScaleFactorsList();
                    });
                    _waveformTick.value++;
                    _analyticsTick.value++;
                  },
                ),
                _buildScaleSlider(
                  label: 'ECG full scale',
                  unit: 'µV',
                  value: ecgScale,
                  minimum: 100,
                  maximum: 30000,
                  enabled: !automatic,
                  activeColor: activeColor,
                  onChanged: (value) {
                    updateSheet(() => ecgScale = value);
                    setState(() {
                      _ecgFixedScale = value;
                      _syncScaleFactorsList();
                    });
                    _waveformTick.value++;
                    _analyticsTick.value++;
                  },
                ),
                _buildScaleSlider(
                  label: 'PPG full scale',
                  unit: 'a.u.',
                  value: ppgScale,
                  minimum: 5,
                  maximum: 32768,
                  enabled: !automatic,
                  activeColor: activeColor,
                  onChanged: (value) {
                    updateSheet(() => ppgScale = value);
                    setState(() {
                      _ppgFixedScale = value;
                      _syncScaleFactorsList();
                    });
                    _waveformTick.value++;
                    _analyticsTick.value++;
                  },
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () {
                      setState(() {
                        _autoscale = automatic;
                        _eegFixedScale = eegScale;
                        _ecgFixedScale = ecgScale;
                        _ppgFixedScale = ppgScale;
                        _syncScaleFactorsList();
                      });
                      _waveformTick.value++;
                      _analyticsTick.value++;
                      _persistDisplaySettings();
                      Navigator.pop(sheetContext);
                    },
                    child: const Text('Done'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (!mounted) return;
    _persistDisplaySettings();
  }

  Widget _buildScaleSlider({
    required String label,
    required String unit,
    required double value,
    required double minimum,
    required double maximum,
    required bool enabled,
    required Color activeColor,
    required ValueChanged<double> onChanged,
  }) {
    final normalized = (math.log(value / minimum) / math.log(maximum / minimum))
        .clamp(0.0, 1.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$label: ±${value.round()} $unit',
          style: TextStyle(
            color: enabled
                ? StudioColors.textPrimary
                : StudioColors.textMuted,
          ),
        ),
        Slider(
          value: normalized,
          activeColor: activeColor,
          onChanged: enabled
              ? (position) => onChanged(
                  (minimum * math.pow(maximum / minimum, position)).toDouble(),
                )
              : null,
        ),
      ],
    );
  }

  Widget _buildEegWorkspace(Color lightTeal) {
    final hasRightSideDock = _showPsdPanel || _showQualityPanel;
    return LayoutBuilder(
      builder: (context, constraints) {
        final wideDock = constraints.maxWidth >= 860 && hasRightSideDock;
        final bottomDock = constraints.maxWidth < 860 && hasRightSideDock;

        if (wideDock) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: _buildEegCanvas(lightTeal)),
              const SizedBox(width: 8),
              SizedBox(
                width: 300,
                child: _buildDockPanelsColumn(verticalSplit: true),
              ),
            ],
          );
        }

        if (bottomDock) {
          return Column(
            children: [
              Expanded(child: _buildEegCanvas(lightTeal)),
              const SizedBox(height: 8),
              SizedBox(
                height: math.min(220.0, constraints.maxHeight * 0.42),
                child: _buildDockPanelsColumn(verticalSplit: false),
              ),
            ],
          );
        }

        return _buildEegCanvas(lightTeal);
      },
    );
  }

  Widget _buildDockPanelsColumn({required bool verticalSplit}) {
    return ValueListenableBuilder<int>(
      valueListenable: _analyticsTick,
      builder: (_, __, ___) {
        final children = <Widget>[
          if (_showQualityPanel)
            Expanded(
              child: SignalQualityPanel(
                channelLabels: _displayChannelLabels,
                metrics: _channelQuality,
                mainsHz: _filterSettings.notchFrequencyHz,
                calibrationFactor: _impedanceCalibration,
                onToggleMainsHz: (hz) {
                  setState(() {
                    _filterSettings = DisplayFilterSettings(
                      eegHighPassHz: _filterSettings.eegHighPassHz,
                      eegLowPassHz: _filterSettings.eegLowPassHz,
                      eogHighPassHz: _filterSettings.eogHighPassHz,
                      eogLowPassHz: _filterSettings.eogLowPassHz,
                      emgHighPassHz: _filterSettings.emgHighPassHz,
                      emgLowPassHz: _filterSettings.emgLowPassHz,
                      ecgHighPassHz: _filterSettings.ecgHighPassHz,
                      ecgLowPassHz: _filterSettings.ecgLowPassHz,
                      notchFrequencyHz: hz,
                      channelOverrides: _channelFilterOverrides,
                    );
                  });
                  _resetDisplayFilterForControlChange();
                  _updateAnalytics();
                  _persistDisplaySettings();
                },
                onCalibrate: _calibrateImpedanceBaseline,
                onSelectChannelForPsd: (idx) {
                  setState(() {
                    _psdChannelIndex = idx;
                    _showPsdPanel = true;
                    _computePsdNow();
                  });
                },
                onClose: () => setState(() => _showQualityPanel = false),
              ),
            ),
          if (_showQualityPanel && _showPsdPanel)
            SizedBox(
              height: verticalSplit ? 8 : 0,
              width: verticalSplit ? 0 : 8,
            ),
          if (_showPsdPanel)
            Expanded(
              child: PsdViewerPanel(
                channelLabels: _displayChannelLabels,
                selectedChannelIndex: _psdChannelIndex,
                onSelectChannel: (idx) {
                  setState(() {
                    _psdChannelIndex = idx;
                    _computePsdNow();
                  });
                },
                psdResult: _latestPsd,
                onClose: () => setState(() => _showPsdPanel = false),
              ),
            ),
        ];

        return verticalSplit
            ? Column(children: children)
            : Row(children: children);
      },
    );
  }

  Widget _buildEegCanvas(Color lightTeal) {
    final settings = context.watch<SettingsService>();
    return Container(
      decoration: BoxDecoration(
        color: StudioColors.card,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: StudioColors.border),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: _eegBuffers.isNotEmpty && _eegBuffers[0].isNotEmpty
            ? LayoutBuilder(
                builder: (context, constraints) {
                  final soloIdx = _soloChannelLabel != null
                      ? _eegChannelLabels.indexOf(_soloChannelLabel!)
                      : -1;
                  final stacked = soloIdx < 0;
                  final visibility = _visibleEegChannels.isNotEmpty
                      ? _visibleEegChannels
                      : List.filled(_eegBuffers.length, true);
                  final visibleIndices = stacked
                      ? [
                          for (var i = 0; i < _eegBuffers.length; i++)
                            if (i < visibility.length && visibility[i]) i,
                        ]
                      : [soloIdx];

                  final weights = List<double>.generate(_eegBuffers.length, (
                    i,
                  ) {
                    final raw = i < _eegChannelLabels.length
                        ? _eegChannelLabels[i]
                        : '';
                    return raw == _prominentChannelLabel ? 2.5 : 1.0;
                  }, growable: false);

                  final hasProminent =
                      stacked &&
                      _prominentChannelLabel != null &&
                      visibleIndices.any(
                        (i) =>
                            i < _eegChannelLabels.length &&
                            _eegChannelLabels[i] == _prominentChannelLabel,
                      );

                  final canvasHeight = stacked
                      ? WaveformPainter.canvasHeightForChannels(
                          channelCount: visibleIndices.length,
                          availableHeight: constraints.maxHeight,
                          extraProminentWeight: hasProminent ? 1.5 : 0.0,
                        )
                      : constraints.maxHeight;

                  final laneHeights = WaveformPainter.laneHeights(
                    visibleIndices: visibleIndices,
                    totalHeight: canvasHeight,
                    channelWeights: stacked ? weights : null,
                  );

                  final traceColors = List<Color>.generate(_eegBuffers.length, (
                    i,
                  ) {
                    final raw = i < _eegChannelLabels.length
                        ? _eegChannelLabels[i]
                        : '';
                    final custom = _channelColorOverrides[raw];
                    if (custom != null) return Color(custom);
                    return WaveformPainter.colors[i %
                        WaveformPainter.colors.length];
                  }, growable: false);

                  final gutterWidth = constraints.maxWidth < 520 ? 92.0 : 122.0;

                  if (visibleIndices.isEmpty) {
                    return Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text(
                            'All channels hidden.',
                            style: TextStyle(color: StudioColors.textSecondary),
                          ),
                          const SizedBox(height: 8),
                          FilledButton(
                            onPressed: () {
                              setState(() {
                                _hiddenChannelLabels.clear();
                                for (var i = 0;
                                    i < _visibleEegChannels.length;
                                    i++) {
                                  _visibleEegChannels[i] = true;
                                }
                              });
                              _persistDisplaySettings();
                            },
                            child: const Text('Show All Channels'),
                          ),
                        ],
                      ),
                    );
                  }

                  return Scrollbar(
                    child: SingleChildScrollView(
                      child: SizedBox(
                        width: constraints.maxWidth,
                        height: canvasHeight,
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _buildInteractiveChannelGutter(
                              width: gutterWidth,
                              visibleIndices: visibleIndices,
                              laneHeights: laneHeights,
                              traceColors: traceColors,
                              isSolo: !stacked,
                            ),
                            Expanded(
                              child: RepaintBoundary(
                                child: CustomPaint(
                                  painter: WaveformPainter(
                                    channels: const [],
                                    ringBuffers: _eegBuffers,
                                    visibleChannels: visibility,
                                    stacked: stacked,
                                    selectedChannel: stacked ? 0 : soloIdx,
                                    gain: _gain,
                                    sampleRate: _eegSampleRate.toDouble(),
                                    durationSeconds: _durationSeconds,
                                    autoscale: false,
                                    channelLabels: _displayChannelLabels,
                                    channelScaleFactors: _scaleFactorsList,
                                    channelColors: traceColors,
                                    channelWeights: weights,
                                    showInlineLabels: false,
                                    markers: _markers,
                                    isPageMode: _viewMode == 'page',
                                    pageStartedAt: _pageStartedAt,
                                    strokeWidth: settings.waveformStrokeWidth,
                                    repaint: _waveformTick,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              )
            : Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(color: lightTeal),
                    const SizedBox(height: 12),
                    const Text(
                      'Waiting for EEG stream...',
                      style: TextStyle(
                        color: StudioColors.textSecondary,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _buildInteractiveChannelGutter({
    required double width,
    required List<int> visibleIndices,
    required List<double> laneHeights,
    required List<Color> traceColors,
    required bool isSolo,
  }) {
    final compact = width < 105;
    return Container(
      width: width,
      decoration: const BoxDecoration(
        color: StudioColors.card,
        border: Border(right: BorderSide(color: StudioColors.border)),
      ),
      child: ValueListenableBuilder<int>(
        valueListenable: _analyticsTick,
        builder: (_, __, ___) => Column(
          children: List.generate(visibleIndices.length, (lane) {
            final chIdx = visibleIndices[lane];
            final h = laneHeights[lane];
            final rawLabel = chIdx < _eegChannelLabels.length
                ? _eegChannelLabels[chIdx]
                : 'Ch ${chIdx + 1}';
            final displayLabel = chIdx < _displayChannelLabels.length
                ? _displayChannelLabels[chIdx]
                : rawLabel;
            final color = chIdx < traceColors.length
                ? traceColors[chIdx]
                : StudioColors.teal;
            final quality = chIdx < _channelQuality.length
                ? _channelQuality[chIdx]
                : null;
            final qColor = quality != null
                ? SignalQualityPanel.gradeColor(quality.grade)
                : StudioColors.textMuted;
            final isProminent = rawLabel == _prominentChannelLabel;

            return Container(
              height: h,
              padding: const EdgeInsets.symmetric(horizontal: 6),
              decoration: BoxDecoration(
                color: isProminent
                    ? color.withValues(alpha: 0.1)
                    : Colors.transparent,
                border: lane < visibleIndices.length - 1
                    ? const Border(
                        bottom: BorderSide(
                          color: StudioColors.border,
                          width: 0.8,
                        ),
                      )
                    : null,
              ),
              child: Row(
                children: [
                  Tooltip(
                    message: quality == null
                        ? 'Quality computing…'
                        : '${quality.formattedImpedance} • SQI ${quality.sqiPercent.round()}%',
                    child: Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        color: qColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                  const SizedBox(width: 5),
                  Expanded(
                    child: InkWell(
                      onTap: () {
                        setState(() {
                          _prominentChannelLabel = isProminent
                              ? null
                              : rawLabel;
                        });
                        _persistDisplaySettings();
                      },
                      onDoubleTap: () {
                        setState(() {
                          _soloChannelLabel = isSolo ? null : rawLabel;
                        });
                        _persistDisplaySettings();
                      },
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            displayLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: color,
                              fontSize: compact ? 10.5 : 11.5,
                              fontWeight: isProminent
                                  ? FontWeight.w800
                                  : FontWeight.w600,
                            ),
                          ),
                          if (_showImpedanceInGutter &&
                              quality != null &&
                              h >= 34)
                            Text(
                              quality.formattedImpedance,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: qColor.withValues(alpha: 0.9),
                                fontSize: 9,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  if (!compact)
                    InkWell(
                      onTap: () {
                        setState(() {
                          _psdChannelIndex = chIdx;
                          _showPsdPanel = true;
                          _computePsdNow();
                        });
                      },
                      child: const Padding(
                        padding: EdgeInsets.all(2),
                        child: Icon(
                          Icons.equalizer,
                          size: 13,
                          color: StudioColors.textMuted,
                        ),
                      ),
                    ),
                  InkWell(
                    onTap: () {
                      setState(() {
                        if (isSolo) {
                          _soloChannelLabel = null;
                        } else {
                          _soloChannelLabel = rawLabel;
                        }
                      });
                      _persistDisplaySettings();
                    },
                    child: Padding(
                      padding: const EdgeInsets.all(2),
                      child: Icon(
                        isSolo
                            ? Icons.fullscreen_exit
                            : Icons.center_focus_strong,
                        size: 13,
                        color: isSolo
                            ? StudioColors.sky
                            : StudioColors.textMuted,
                      ),
                    ),
                  ),
                  if (!isSolo)
                    InkWell(
                      onTap: () {
                        setState(() {
                          _hiddenChannelLabels.add(rawLabel);
                          if (chIdx < _visibleEegChannels.length) {
                            _visibleEegChannels[chIdx] = false;
                          }
                        });
                        _persistDisplaySettings();
                      },
                      child: const Padding(
                        padding: EdgeInsets.all(2),
                        child: Icon(
                          Icons.visibility_off_outlined,
                          size: 13,
                          color: StudioColors.textMuted,
                        ),
                      ),
                    ),
                ],
              ),
            );
          }),
        ),
      ),
    );
  }

  Widget _buildNirsView() {
    return Container(
      decoration: BoxDecoration(
        color: StudioColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: StudioColors.border),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: _nirsBuffers.isNotEmpty && _nirsBuffers.any((b) => b.isNotEmpty)
            ? CustomPaint(
                painter: NirsWaveformPainter(
                  buffers: _nirsBuffers,
                  channelNames: _nirsChannelLabels,
                  hiddenChannels: _hiddenNirsChannels,
                ),
              )
            : const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(color: StudioColors.violet),
                    SizedBox(height: 12),
                    Text(
                      'Waiting for fNIRS stream...',
                      style: TextStyle(
                        color: StudioColors.textSecondary,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _buildDualView(Color lightTeal) {
    return Column(
      children: [
        Expanded(child: _buildEegWorkspace(lightTeal)),
        const SizedBox(height: 6),
        Expanded(child: _buildNirsView()),
      ],
    );
  }

  Widget _buildSlimMetricsBar() {
    return ValueListenableBuilder<int>(
      valueListenable: _analyticsTick,
      builder: (_, __, ___) {
        final receivedRate = widget.eegService?.deliveredSampleRate;
        final expectedRate = widget.eegService?.sampleRate;
        final saturatedChannels =
            widget.eegService?.adcSaturatedChannelLabels ?? const <String>[];
        final rateRatio = receivedRate != null && expectedRate != null
            ? receivedRate / expectedRate
            : null;
        final goodChannels = _channelQuality
            .where((m) => m.grade == SignalQualityGrade.good)
            .length;

        return Container(
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: StudioColors.card,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: StudioColors.border),
          ),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                if (_hasEeg) ...[
                  _slimMetric(
                    'P2P',
                    '${_peakToPeakUv.toStringAsFixed(1)} µV',
                    _peakToPeakUv < 150
                        ? StudioColors.emerald
                        : StudioColors.amber,
                  ),
                  _slimSep(),
                  _slimMetric(
                    'Artifact',
                    '${(_artifactRatio * 100).toStringAsFixed(1)}%',
                    _artifactRatio < 0.1
                        ? StudioColors.emerald
                        : StudioColors.red,
                  ),
                  _slimSep(),
                  _slimMetric(
                    'Signal',
                    saturatedChannels.isNotEmpty
                        ? 'SAT: ${saturatedChannels.join(',')}'
                        : (_channelQuality.isNotEmpty
                              ? '$goodChannels/${_channelQuality.length} Good'
                              : (_signalStable ? 'GOOD' : 'NOISY')),
                    saturatedChannels.isNotEmpty
                        ? StudioColors.red
                        : (_signalStable
                              ? StudioColors.emerald
                              : StudioColors.amber),
                  ),
                  if (_cleanerConfig.enabled) ...[
                    _slimSep(),
                    _slimMetric(
                      'ASR Clean',
                      _asrCalProgress < 100 && _cleanerConfig.enableAsr
                          ? 'Cal $_asrCalProgress%'
                          : '${(_cleaningIntensity * 100).toStringAsFixed(0)}%',
                      StudioColors.amber,
                    ),
                  ],
                  if (receivedRate != null) ...[
                    _slimSep(),
                    _slimMetric(
                      'Rate',
                      '${receivedRate.toStringAsFixed(0)}/${expectedRate!.toStringAsFixed(0)} Hz',
                      rateRatio! >= 0.9
                          ? StudioColors.emerald
                          : rateRatio >= 0.75
                          ? StudioColors.amber
                          : StudioColors.red,
                    ),
                  ],
                  if (_hiddenChannelLabels.isNotEmpty) ...[
                    _slimSep(),
                    InkWell(
                      onTap: () {
                        setState(() {
                          _hiddenChannelLabels.clear();
                          for (var i = 0; i < _visibleEegChannels.length; i++) {
                            _visibleEegChannels[i] = true;
                          }
                        });
                        _persistDisplaySettings();
                      },
                      child: Text(
                        'Show ${_hiddenChannelLabels.length} hidden',
                        style: const TextStyle(
                          color: StudioColors.sky,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ],
                if (_hasNirs && !_hasEeg) ...[
                  _slimMetric(
                    'fNIRS',
                    '${widget.nirsService?.channelCount ?? 0} ch',
                    StudioColors.emerald,
                  ),
                  _slimSep(),
                  _slimMetric(
                    'Stream',
                    widget.nirsService?.connectedStreamName ?? 'N/A',
                    StudioColors.violet,
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _slimSep() => Container(
    width: 1,
    height: 14,
    margin: const EdgeInsets.symmetric(horizontal: 10),
    color: StudioColors.border,
  );

  Widget _slimMetric(String label, String value, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$label ',
          style: const TextStyle(
            color: StudioColors.textMuted,
            fontSize: 11,
          ),
        ),
        Text(
          value,
          style: TextStyle(
            color: color,
            fontWeight: FontWeight.w700,
            fontSize: 11.5,
          ),
        ),
      ],
    );
  }
}
