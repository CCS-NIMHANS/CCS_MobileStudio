import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/eeg/acquisition_service.dart';
import '../../core/eeg/native_cleaner.dart';
import '../../core/models/eeg_sample.dart';
import '../../core/models/module_type.dart';
import '../../core/services/channel_config_service.dart';
import '../../core/services/file_naming_service.dart';
import '../../core/services/session_manager.dart';
import '../../core/services/settings_service.dart';
import '../../core/theme/studio_theme.dart';
import '../standalone/standalone_screen.dart';
import 'native_speech_tracker.dart';
import 'stereo_audio_mixer.dart';

class SpeechBlockReport {
  const SpeechBlockReport({
    required this.blockIndex,
    required this.instructedSide,
    required this.score,
    required this.channelsUsed,
    required this.durationSeconds,
    required this.multiFeature,
  });

  final int blockIndex;
  final int instructedSide; // 0 = Left, 1 = Right
  final SpeechDecodeScore score;
  final List<String> channelsUsed;
  final double durationSeconds;
  final bool multiFeature;

  bool get correct => score.predictedSide == instructedSide;

  Map<String, dynamic> toJson() => {
    'block_index': blockIndex,
    'instructed_side': instructedSide == 0 ? 'LEFT' : 'RIGHT',
    'predicted_side': score.predictedLabel,
    'correct': correct,
    'r_left': score.rLeft,
    'r_right': score.rRight,
    'diff_r': score.diffR,
    'confidence': score.confidence,
    'snr_db': score.snrDb,
    'n_features': score.nFeatures,
    'channels_used': channelsUsed,
    'duration_seconds': durationSeconds,
    'multi_feature': multiFeature,
  };
}

class SpeechTrackingScreen extends StatefulWidget {
  const SpeechTrackingScreen({super.key});

  @override
  State<SpeechTrackingScreen> createState() => _SpeechTrackingScreenState();
}

class _SpeechTrackingScreenState extends State<SpeechTrackingScreen> {
  final AudioPlayer _player = AudioPlayer();
  StreamSubscription<EegSample>? _sampleSub;
  Timer? _blockTickTimer;
  final Stopwatch _blockStopwatch = Stopwatch();

  String? _leftWavPath;
  String? _rightWavPath;
  int _blockCount = 6;
  int _blockDurationSec = 25;
  bool _multiFeature = true;
  bool _useOnlineCleaning = true;
  bool _allChannels = true;
  final Set<int> _selectedChannels = {};

  bool _running = false;
  bool _preparing = false;
  bool _ownsRecording = false;
  bool _showingCueBreak = false;
  int _currentBlock = 0; // 0-based
  int _currentInstructedSide = 0; // 0 = Left, 1 = Right
  double _blockProgress = 0.0;
  DichoticAudioBundle? _bundle;

  List<List<double>> _blockEegBuffers = [];
  List<String> _activeChannelNames = [];
  NativeOnlineEegCleaner? _cleaner;
  List<double> _cleanScratch = const [];

  SpeechDecodeScore? _liveScore;
  final List<SpeechBlockReport> _reports = [];
  int _samplesSinceLiveDecode = 0;
  DateTime? _sessionStartTime;

  @override
  void dispose() {
    _blockTickTimer?.cancel();
    _sampleSub?.cancel();
    _blockStopwatch.stop();
    _cleaner?.dispose();
    unawaited(_player.dispose());
    super.dispose();
  }

  Future<void> _pickAudio(bool left) async {
    final res = await FilePicker.platform.pickFiles(
      dialogTitle: left
          ? 'Select Audio A (Left Ear WAV)'
          : 'Select Audio B (Right Ear WAV)',
      type: FileType.custom,
      allowedExtensions: const ['wav'],
    );
    final path = res?.files.single.path;
    if (path == null || !mounted) return;
    setState(() {
      if (left) {
        _leftWavPath = path;
      } else {
        _rightWavPath = path;
      }
    });
  }

  List<int> _resolvedChannelIndices(
    int totalChannels,
    List<bool> enabledMask,
  ) {
    if (_allChannels || _selectedChannels.isEmpty) {
      final enabled = [
        for (var i = 0; i < totalChannels; i++)
          if (i >= enabledMask.length || enabledMask[i]) i,
      ];
      return enabled.isEmpty
          ? List<int>.generate(math.max(1, totalChannels), (i) => i)
          : enabled;
    }
    return _selectedChannels
        .where((idx) => idx < totalChannels)
        .toList()
      ..sort();
  }

  Future<void> _startSession() async {
    if (_running || _preparing) return;
    setState(() {
      _preparing = true;
      _reports.clear();
      _liveScore = null;
    });

    try {
      final acquisition = context.read<AcquisitionService>();
      final channels = context.read<ChannelConfigService>();
      final settings = context.read<SettingsService>();
      final session = context.read<SessionManager>();

      final bundle = await StereoAudioMixer.prepareDichoticAudio(
        leftWavPath: _leftWavPath,
        rightWavPath: _rightWavPath,
        targetDurationSec: _blockDurationSec + 5.0,
      );
      if (!mounted) return;
      _bundle = bundle;

      final indices = _resolvedChannelIndices(
        acquisition.channelCount,
        channels.enabled,
      );
      final labels = acquisition.displayChannelLabels(acquisition.channelCount);
      _activeChannelNames = [
        for (final i in indices) i < labels.length ? labels[i] : 'Ch ${i + 1}',
      ];

      _ownsRecording = !session.isRecording;
      if (_ownsRecording) {
        await session.startRecording(
          module: ModuleType.speechTracking,
          subjectId: settings.subjectCode,
          channelCount: acquisition.channelCount,
          sampleRate: acquisition.sampleRate.round(),
          channelLabels: acquisition.recordingChannelLabels(channels.labels),
          enabledChannels: acquisition.recordingEnabledChannels(channels.enabled),
        );
      }
      _sessionStartTime = session.sessionStart ?? DateTime.now();

      _cleaner?.dispose();
      if (_useOnlineCleaning) {
        _cleaner = NativeOnlineEegCleaner(
          channelCount: indices.length,
          sampleRate: acquisition.sampleRate,
        )..applyConfig(const OnlineCleanerConfig(enabled: true));
        _cleanScratch = List<double>.filled(indices.length, 0.0);
      } else {
        _cleaner = null;
      }

      _blockEegBuffers = List.generate(indices.length, (_) => <double>[]);
      _samplesSinceLiveDecode = 0;

      await _sampleSub?.cancel();
      _sampleSub = acquisition.samples.listen((sample) {
        if (!_running || _showingCueBreak) return;
        final rawSel = List<double>.generate(
          indices.length,
          (i) => indices[i] < sample.channels.length
              ? sample.channels[indices[i]]
              : 0.0,
          growable: false,
        );
        List<double> processed = rawSel;
        if (_cleaner != null) {
          _cleaner!.processSample(rawSel, _cleanScratch);
          processed = _cleanScratch;
        }
        for (var i = 0; i < indices.length; i++) {
          _blockEegBuffers[i].add(processed[i]);
        }
        _samplesSinceLiveDecode++;
        final sr = acquisition.sampleRate;
        if (_samplesSinceLiveDecode >= (sr * 5.0).round() &&
            _blockEegBuffers[0].length >= (sr * 8.0).round()) {
          _samplesSinceLiveDecode = 0;
          _evaluateCurrentBuffer(isFinalBlockResult: false, eegSr: sr);
        }
      });

      setState(() {
        _preparing = false;
        _running = true;
        _currentBlock = 0;
      });
      await _runBlock(0);
    } catch (e) {
      if (mounted) {
        setState(() => _preparing = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Speech tracking setup error: $e')),
        );
      }
    }
  }

  Future<void> _runBlock(int blockIndex) async {
    if (!_running || !mounted) return;
    if (blockIndex >= _blockCount) {
      await _finishSession();
      return;
    }

    final side = blockIndex % 2; // Alternate 0=LEFT, 1=RIGHT
    setState(() {
      _currentBlock = blockIndex;
      _currentInstructedSide = side;
      _showingCueBreak = true;
      _blockProgress = 0.0;
      _liveScore = null;
    });

    // Brief 3-second attention instruction screen before stereo playback starts
    await Future<void>.delayed(const Duration(seconds: 3));
    if (!_running || !mounted) return;

    for (final buf in _blockEegBuffers) {
      buf.clear();
    }
    _samplesSinceLiveDecode = 0;
    setState(() => _showingCueBreak = false);

    final session = context.read<SessionManager>();
    session.recordEvent(
      side == 0 ? 'SPEECH_BLOCK_LEFT' : 'SPEECH_BLOCK_RIGHT',
      700 + side + 1,
    );

    final bundle = _bundle;
    if (bundle != null) {
      await _player.stop();
      await _player.setReleaseMode(ReleaseMode.loop);
      await _player.play(DeviceFileSource(bundle.stereoWavPath));
    }

    _blockStopwatch
      ..reset()
      ..start();
    _blockTickTimer?.cancel();
    _blockTickTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (!_running || !mounted) return;
      final elapsedSec = _blockStopwatch.elapsedMilliseconds / 1000.0;
      final prog = (elapsedSec / _blockDurationSec).clamp(0.0, 1.0);
      setState(() => _blockProgress = prog);
      if (elapsedSec >= _blockDurationSec) {
        _blockTickTimer?.cancel();
        unawaited(_completeCurrentBlock());
      }
    });
  }

  void _evaluateCurrentBuffer({
    required bool isFinalBlockResult,
    required double eegSr,
  }) {
    final bundle = _bundle;
    if (bundle == null || _blockEegBuffers.isEmpty) return;
    final score = NativeSpeechTracker.instance.decodeBlock(
      eegChannels: _blockEegBuffers,
      eegSampleRate: eegSr,
      envLeft: bundle.leftEnvelope,
      envRight: bundle.rightEnvelope,
      envSampleRate: bundle.envelopeRateHz,
      multiFeature: _multiFeature,
    );
    if (!mounted) return;
    if (isFinalBlockResult) {
      final session = context.read<SessionManager>();
      session.recordEvent(
        score.predictedSide == 0
            ? 'SPEECH_DECODE_LEFT'
            : 'SPEECH_DECODE_RIGHT',
        710 + score.predictedSide + 1,
      );
      setState(() {
        _liveScore = score;
        _reports.add(
          SpeechBlockReport(
            blockIndex: _currentBlock + 1,
            instructedSide: _currentInstructedSide,
            score: score,
            channelsUsed: List<String>.from(_activeChannelNames),
            durationSeconds: _blockDurationSec.toDouble(),
            multiFeature: _multiFeature,
          ),
        );
      });
    } else {
      setState(() => _liveScore = score);
    }
  }

  Future<void> _completeCurrentBlock() async {
    _blockStopwatch.stop();
    await _player.stop();
    if (!_running || !mounted) return;
    final eegSr = context.read<AcquisitionService>().sampleRate;
    _evaluateCurrentBuffer(isFinalBlockResult: true, eegSr: eegSr);

    // Pause briefly to let participant read block score before next block
    await Future<void>.delayed(const Duration(seconds: 2));
    if (!_running || !mounted) return;
    await _runBlock(_currentBlock + 1);
  }

  Future<void> _finishSession() async {
    _blockTickTimer?.cancel();
    _blockStopwatch.stop();
    await _player.stop();
    await _sampleSub?.cancel();
    _sampleSub = null;

    if (_reports.isNotEmpty) {
      await _exportReports();
    }
    if (_ownsRecording && mounted) {
      await context.read<SessionManager>().stopRecording();
    }
    if (mounted) {
      setState(() {
        _running = false;
        _showingCueBreak = false;
      });
    }
  }

  Future<void> _exportReports() async {
    try {
      final settings = context.read<SettingsService>();
      final session = context.read<SessionManager>();
      final start = _sessionStartTime ?? DateTime.now();
      final stem = FileNamingService.stem(
        settings.subjectCode,
        ModuleType.speechTracking,
        start,
      );
      final csvPath = await FileNamingService.csvPath(
        settings.subjectCode,
        ModuleType.speechTracking,
        start,
      );
      final rows = <String>[
        'block,instructed,predicted,correct,r_left,r_right,diff_r,confidence,snr_db,channels,multi_feature',
        ..._reports.map(
          (r) => [
            r.blockIndex,
            r.instructedSide == 0 ? 'LEFT' : 'RIGHT',
            r.score.predictedLabel,
            r.correct,
            r.score.rLeft.toStringAsFixed(5),
            r.score.rRight.toStringAsFixed(5),
            r.score.diffR.toStringAsFixed(5),
            r.score.confidence.toStringAsFixed(4),
            r.score.snrDb.toStringAsFixed(2),
            '"${r.channelsUsed.join(';')}"',
            r.multiFeature,
          ].join(','),
        ),
      ];
      await File(csvPath).writeAsString('${rows.join('\n')}\n', flush: true);
      await FileNamingService.exportToDownloads(
        csvPath,
        subject: settings.subjectCode,
        sessionStem: stem,
      );

      final jsonPath = csvPath.replaceFirst('.csv', '_speech_tracking.json');
      final correctCount = _reports.where((r) => r.correct).length;
      await File(jsonPath).writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'subject': settings.subjectCode,
          'session_stem': stem,
          'left_audio': _bundle?.leftLabel,
          'right_audio': _bundle?.rightLabel,
          'blocks_completed': _reports.length,
          'accuracy_percent': _reports.isEmpty
              ? 0.0
              : (correctCount * 100.0 / _reports.length),
          'blocks': _reports.map((r) => r.toJson()).toList(),
        }),
        flush: true,
      );
      await FileNamingService.exportToDownloads(
        jsonPath,
        subject: settings.subjectCode,
        sessionStem: stem,
      );
      final _ = session;
    } catch (e) {
      debugPrint('[SpeechTracking] Export error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final acq = context.watch<AcquisitionService>();
    final channels = context.watch<ChannelConfigService>();
    final labels = acq.displayChannelLabels(acq.channelCount);
    final correctCount = _reports.where((r) => r.correct).length;

    return Scaffold(
      backgroundColor: StudioColors.canvas,
      appBar: AppBar(
        title: const Text('Neural Speech Tracking'),
        backgroundColor: StudioColors.surface,
        actions: [
          IconButton(
            tooltip: 'Live EEG viewer',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => const StandaloneScreen(viewerOnly: true),
              ),
            ),
            icon: const Icon(Icons.waves),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _card(
            title: 'Dichotic Stereo Setup & EEG Channels',
            icon: Icons.headphones,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Play two distinct speech streams simultaneously (Left vs. Right ear stereo). '
                  'Select any subset of EEG channels — Multi-Feature TRF works even with 1–4 electrodes.',
                  style: TextStyle(color: StudioColors.textSecondary, fontSize: 12.5),
                ),
                const SizedBox(height: 12),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final pickers = [
                      _audioPickerTile(
                        title: 'Left Channel Audio (.wav)',
                        path: _leftWavPath,
                        fallback: 'Built-in Voice A (3.4 Hz syllabic)',
                        color: StudioColors.sky,
                        onPick: _running ? null : () => _pickAudio(true),
                        onClear: _running || _leftWavPath == null
                            ? null
                            : () => setState(() => _leftWavPath = null),
                      ),
                      _audioPickerTile(
                        title: 'Right Channel Audio (.wav)',
                        path: _rightWavPath,
                        fallback: 'Built-in Voice B (5.1 Hz syllabic)',
                        color: StudioColors.amber,
                        onPick: _running ? null : () => _pickAudio(false),
                        onClear: _running || _rightWavPath == null
                            ? null
                            : () => setState(() => _rightWavPath = null),
                      ),
                    ];
                    if (constraints.maxWidth < 640) {
                      return Column(
                        children: [
                          pickers[0],
                          const SizedBox(height: 8),
                          pickers[1],
                        ],
                      );
                    }
                    return Row(
                      children: [
                        Expanded(child: pickers[0]),
                        const SizedBox(width: 10),
                        Expanded(child: pickers[1]),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 16,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          'Blocks: ',
                          style: TextStyle(color: StudioColors.textSecondary),
                        ),
                        DropdownButton<int>(
                          value: _blockCount,
                          dropdownColor: StudioColors.elevated,
                          items: const [2, 4, 6, 8, 10]
                              .map(
                                (v) => DropdownMenuItem(
                                  value: v,
                                  child: Text('$v blocks'),
                                ),
                              )
                              .toList(),
                          onChanged: _running
                              ? null
                              : (v) => setState(() => _blockCount = v ?? 6),
                        ),
                      ],
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          'Block duration: ',
                          style: TextStyle(color: StudioColors.textSecondary),
                        ),
                        DropdownButton<int>(
                          value: _blockDurationSec,
                          dropdownColor: StudioColors.elevated,
                          items: const [15, 25, 30, 45, 60]
                              .map(
                                (v) => DropdownMenuItem(
                                  value: v,
                                  child: Text('${v}s'),
                                ),
                              )
                              .toList(),
                          onChanged: _running
                              ? null
                              : (v) =>
                                    setState(() => _blockDurationSec = v ?? 25),
                        ),
                      ],
                    ),
                    FilterChip(
                      selected: _multiFeature,
                      label: const Text('Multi-Feature (1–16 ch)'),
                      onSelected: _running
                          ? null
                          : (v) => setState(() => _multiFeature = v),
                    ),
                    FilterChip(
                      selected: _useOnlineCleaning,
                      label: const Text('Rust ASR + CleanLine'),
                      onSelected: _running
                          ? null
                          : (v) => setState(() => _useOnlineCleaning = v),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                const Text(
                  'EEG Channels for Decoding:',
                  style: TextStyle(
                    color: StudioColors.textSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    ChoiceChip(
                      label: const Text('All Enabled'),
                      selected: _allChannels,
                      onSelected: _running
                          ? null
                          : (v) => setState(() => _allChannels = v),
                    ),
                    ...List.generate(acq.channelCount, (idx) {
                      final lbl = idx < labels.length
                          ? labels[idx]
                          : 'Ch ${idx + 1}';
                      final enabledInProfile =
                          idx >= channels.enabled.length ||
                          channels.enabled[idx];
                      final selected = !_allChannels &&
                          _selectedChannels.contains(idx);
                      return FilterChip(
                        label: Text(lbl),
                        selected: _allChannels ? enabledInProfile : selected,
                        onSelected: _running
                            ? null
                            : (v) {
                                setState(() {
                                  _allChannels = false;
                                  if (v) {
                                    _selectedChannels.add(idx);
                                  } else {
                                    _selectedChannels.remove(idx);
                                  }
                                });
                              },
                      );
                    }),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          if (_running || _liveScore != null) ...[
            _card(
              title: _running
                  ? 'Live Block ${_currentBlock + 1} / $_blockCount'
                  : 'Latest Decoding Score',
              icon: Icons.graphic_eq,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 20,
                    ),
                    decoration: BoxDecoration(
                      color:
                          (_currentInstructedSide == 0
                                  ? StudioColors.sky
                                  : StudioColors.amber)
                              .withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: _currentInstructedSide == 0
                            ? StudioColors.sky
                            : StudioColors.amber,
                      ),
                    ),
                    child: Column(
                      children: [
                        Text(
                          _running
                              ? (_showingCueBreak
                                    ? 'GET READY — FOCUS ON:'
                                    : 'ATTEND TO:')
                              : 'LAST INSTRUCTION',
                          style: const TextStyle(
                            color: StudioColors.textSecondary,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _currentInstructedSide == 0
                              ? '← LEFT EAR AUDIO'
                              : 'RIGHT EAR AUDIO →',
                          style: TextStyle(
                            color: _currentInstructedSide == 0
                                ? StudioColors.sky
                                : StudioColors.amber,
                            fontSize: 26,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        if (_running && !_showingCueBreak) ...[
                          const SizedBox(height: 12),
                          LinearProgressIndicator(
                            value: _blockProgress,
                            minHeight: 8,
                            backgroundColor: StudioColors.surface,
                            color: _currentInstructedSide == 0
                                ? StudioColors.sky
                                : StudioColors.amber,
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (_liveScore != null) ...[
                    const SizedBox(height: 14),
                    _scoreSummaryRow(_liveScore!),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 14),
          ],
          if (_reports.isNotEmpty) ...[
            _card(
              title:
                  'Block Decoding Results • Accuracy: ${(correctCount * 100 / _reports.length).round()}% ($correctCount/${_reports.length})',
              icon: Icons.assessment_outlined,
              child: Column(
                children: _reports.map((r) {
                  return Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: StudioColors.surface,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: r.correct
                            ? StudioColors.emerald.withValues(alpha: 0.55)
                            : StudioColors.red.withValues(alpha: 0.55),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          r.correct ? Icons.check_circle : Icons.cancel,
                          color: r.correct
                              ? StudioColors.emerald
                              : StudioColors.red,
                          size: 20,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Block ${r.blockIndex}: Focus ${r.instructedSide == 0 ? "LEFT" : "RIGHT"}  →  Decoded ${r.score.predictedLabel}',
                                style: const TextStyle(
                                  color: StudioColors.textPrimary,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 13,
                                ),
                              ),
                              Text(
                                'r_Left: ${r.score.rLeft.toStringAsFixed(3)} • r_Right: ${r.score.rRight.toStringAsFixed(3)} • '
                                'Conf ${(r.score.confidence * 100).round()}% • ${r.channelsUsed.length} ch (${r.score.nFeatures} feat)',
                                style: const TextStyle(
                                  color: StudioColors.textSecondary,
                                  fontSize: 11.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                }).toList(),
              ),
            ),
            const SizedBox(height: 14),
          ],
          FilledButton.icon(
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(50),
              backgroundColor: _running ? StudioColors.red : StudioColors.teal,
              foregroundColor: Colors.white,
            ),
            onPressed: _preparing
                ? null
                : (_running ? _finishSession : _startSession),
            icon: Icon(_running ? Icons.stop : Icons.play_arrow),
            label: Text(
              _preparing
                  ? 'Preparing dichotic audio & speech envelopes...'
                  : (_running
                        ? 'Stop Speech Tracking (Block ${_currentBlock + 1}/$_blockCount)'
                        : 'Start Dichotic Neural Speech Tracking'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _scoreSummaryRow(SpeechDecodeScore s) {
    return Row(
      children: [
        Expanded(
          child: _metricTile(
            'r (Left Audio)',
            s.rLeft.toStringAsFixed(3),
            StudioColors.sky,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _metricTile(
            'r (Right Audio)',
            s.rRight.toStringAsFixed(3),
            StudioColors.amber,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _metricTile(
            'Decoded Focus',
            '${s.predictedLabel} (${(s.confidence * 100).round()}%)',
            s.predictedSide == 0 ? StudioColors.sky : StudioColors.amber,
          ),
        ),
      ],
    );
  }

  Widget _metricTile(String title, String value, Color color) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: StudioColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: StudioColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(color: StudioColors.textMuted, fontSize: 11),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w700,
              fontSize: 15,
            ),
          ),
        ],
      ),
    );
  }

  Widget _audioPickerTile({
    required String title,
    required String? path,
    required String fallback,
    required Color color,
    required VoidCallback? onPick,
    required VoidCallback? onClear,
  }) {
    final name = path == null
        ? fallback
        : path.split(Platform.pathSeparator).last;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: StudioColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Row(
        children: [
          Icon(Icons.audiotrack, color: color, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: color,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: StudioColors.textPrimary,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          if (onClear != null)
            IconButton(
              tooltip: 'Use built-in voice',
              onPressed: onClear,
              icon: const Icon(Icons.close, size: 16),
            ),
          TextButton(onPressed: onPick, child: const Text('Browse')),
        ],
      ),
    );
  }

  Widget _card({
    required String title,
    required IconData icon,
    required Widget child,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: StudioColors.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: StudioColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: StudioColors.teal, size: 19),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    color: StudioColors.textPrimary,
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}
