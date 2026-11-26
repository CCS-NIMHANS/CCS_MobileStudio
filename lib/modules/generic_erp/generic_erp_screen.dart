import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/eeg/acquisition_service.dart';
import '../../core/models/eeg_sample.dart';
import '../../core/models/module_type.dart';
import '../../core/services/alert_service.dart';
import '../../core/services/channel_config_service.dart';
import '../../core/services/file_naming_service.dart';
import '../../core/services/session_manager.dart';
import '../../core/services/settings_service.dart';
import '../../core/theme/studio_theme.dart';
import '../standalone/standalone_screen.dart';
import 'erp_averager.dart';
import 'erp_core_paradigms.dart';

const _classicParadigms = [
  'Visual Oddball',
  'Auditory Oddball',
  'N400',
  'P50',
  'MMN',
  'N170',
];

final _paradigms = [
  ...kErpCoreParadigms.map((p) => p.shortName),
  ..._classicParadigms,
];

class GenericErpScreen extends StatefulWidget {
  const GenericErpScreen({super.key});

  @override
  State<GenericErpScreen> createState() => _GenericErpScreenState();
}

class _GenericErpScreenState extends State<GenericErpScreen> {
  Timer? _nextTrialTimer;
  Timer? _p50PairTimer;
  Timer? _stimOffTimer;
  Timer? _n400TargetTimer;
  final Stopwatch _sessionStopwatch = Stopwatch();
  final Stopwatch _trialRtStopwatch = Stopwatch();
  final FocusNode _keyboardFocus = FocusNode();
  StreamSubscription<EegSample>? _sampleSub;
  final AudioPlayer _player = AudioPlayer();
  ErpAverager? _averager;
  bool _running = false;
  bool _rare = false;
  int _trial = 0;
  bool _ownsRecording = false;
  List<bool> _trialPlan = const [];
  List<ErpCoreTrial> _corePlan = const [];
  ErpCoreTrial? _activeCoreTrial;
  bool _coreStimulusVisible = false;
  String? _n400PrimeVisibleWord;
  bool _coreTrialResponded = false;
  String? _mmnStdPath;
  String? _mmnDevPath;
  bool _frequentFileExists = false;
  bool _rareFileExists = false;
  bool _showDifferenceWave = true;
  int _correctResponses = 0;
  int _totalResponses = 0;
  final List<String> _behavioralCsvRows = [];

  @override
  void initState() {
    super.initState();
    final acquisition = context.read<AcquisitionService>();
    _averager = ErpAverager(sampleRate: acquisition.sampleRate);
    _sampleSub = acquisition.samples.listen((sample) {
      _averager?.push(sample);
    });
  }

  @override
  void dispose() {
    _nextTrialTimer?.cancel();
    _p50PairTimer?.cancel();
    _stimOffTimer?.cancel();
    _n400TargetTimer?.cancel();
    _sessionStopwatch.stop();
    _trialRtStopwatch.stop();
    _keyboardFocus.dispose();
    _sampleSub?.cancel();
    _averager?.dispose();
    unawaited(_player.dispose());
    super.dispose();
  }

  Future<void> _pickFile(bool rare) async {
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: rare
          ? 'Choose rare / target stimulus'
          : 'Choose frequent / standard stimulus',
    );
    final path = result?.files.single.path;
    if (path == null || !mounted) return;
    context.read<SettingsService>().update((settings) {
      if (rare) {
        settings.genericErpRareFilePath = path;
      } else {
        settings.genericErpFrequentFilePath = path;
      }
    });
  }

  Future<void> _start() async {
    final acquisition = context.read<AcquisitionService>();
    final session = context.read<SessionManager>();
    final settings = context.read<SettingsService>();
    final channels = context.read<ChannelConfigService>();

    _averager?.dispose();
    _averager = ErpAverager(sampleRate: acquisition.sampleRate);
    _trial = 0;
    _activeCoreTrial = null;
    _coreStimulusVisible = false;
    _n400PrimeVisibleWord = null;
    _coreTrialResponded = false;
    _correctResponses = 0;
    _totalResponses = 0;
    _behavioralCsvRows
      ..clear()
      ..add('trial,paradigm,condition,marker,responded_left,expected_left,correct,rt_ms');

    final coreSpec = erpCoreSpecByName(settings.genericErpParadigm);
    if (coreSpec != null) {
      if (coreSpec.id == ErpCoreParadigmId.mmn) {
        final tones = await ensureMmnToneFiles();
        _mmnStdPath = tones.standardPath;
        _mmnDevPath = tones.deviantPath;
      }
      _corePlan = buildErpCoreTrialPlan(
        coreSpec.id,
        settings.genericErpTrials,
      );
      _trialPlan = const [];
    } else {
      _corePlan = const [];
      // Pre-check file existence once before trial loop to avoid disk I/O jitter.
      _frequentFileExists =
          settings.genericErpFrequentFilePath.isNotEmpty &&
          await File(settings.genericErpFrequentFilePath).exists();
      _rareFileExists =
          settings.genericErpRareFilePath.isNotEmpty &&
          await File(settings.genericErpRareFilePath).exists();

      final rareCount =
          (settings.genericErpTrials * settings.genericErpRareProbability)
              .round();
      _trialPlan = [
        ...List<bool>.filled(rareCount, true),
        ...List<bool>.filled(settings.genericErpTrials - rareCount, false),
      ]..shuffle(Random());
    }

    _ownsRecording = !session.isRecording;
    if (_ownsRecording) {
      await session.startRecording(
        module: ModuleType.erp,
        subjectId: settings.subjectCode,
        channelCount: acquisition.channelCount,
        sampleRate: acquisition.sampleRate.round(),
        channelLabels: acquisition.recordingChannelLabels(channels.labels),
        enabledChannels: acquisition.recordingEnabledChannels(channels.enabled),
      );
    }
    if (!mounted) return;
    setState(() => _running = true);
    _keyboardFocus.requestFocus();
    _sessionStopwatch
      ..reset()
      ..start();
    if (coreSpec != null) {
      _scheduleCoreTrial(0, coreSpec);
    } else {
      _scheduleTrialAt(0);
    }
  }

  void _scheduleCoreTrial(int delayMs, ErpCoreParadigmSpec spec) {
    _nextTrialTimer?.cancel();
    _nextTrialTimer = Timer(Duration(milliseconds: delayMs), () {
      if (!_running || !mounted) return;
      _presentCoreTrial(spec);
    });
  }

  void _presentCoreTrial(ErpCoreParadigmSpec spec) {
    if (!_running || !mounted) return;
    if (_trial >= _corePlan.length) {
      unawaited(_stop());
      return;
    }
    final trial = _corePlan[_trial];
    final rng = Random();
    final isi =
        spec.minIsiMs +
        rng.nextInt(max(1, spec.maxIsiMs - spec.minIsiMs + 1));

    _stimOffTimer?.cancel();
    _n400TargetTimer?.cancel();

    if (spec.id == ErpCoreParadigmId.mmn) {
      final path = trial.isDeviantTone ? _mmnDevPath : _mmnStdPath;
      if (path != null) {
        unawaited(_player.play(DeviceFileSource(path)));
      }
      context.read<SessionManager>().recordEvent(
        'MMN_${trial.conditionLabel}',
        trial.markerCode,
      );
      _averager?.mark(trial.avgClass);
      setState(() {
        _activeCoreTrial = trial;
        _coreStimulusVisible = true;
        _coreTrialResponded = false;
        _trial++;
      });
      _stimOffTimer = Timer(Duration(milliseconds: spec.stimDurationMs), () {
        if (mounted) setState(() => _coreStimulusVisible = false);
      });
      final totalSoa = spec.stimDurationMs + isi;
      if (_trial < _corePlan.length) {
        _scheduleCoreTrial(totalSoa, spec);
      } else {
        _nextTrialTimer = Timer(Duration(milliseconds: totalSoa + 400), () {
          if (_running && mounted) unawaited(_stop());
        });
      }
      return;
    }

    if (spec.id == ErpCoreParadigmId.n400) {
      // Phase 1: Prime word (200 ms) -> Phase 2: ISI (800 ms) -> Phase 3: Target word (200 ms)
      setState(() {
        _activeCoreTrial = trial;
        _n400PrimeVisibleWord = trial.primeWord;
        _coreStimulusVisible = false;
        _coreTrialResponded = false;
        _trial++;
      });
      _stimOffTimer = Timer(const Duration(milliseconds: 200), () {
        if (!mounted || !_running) return;
        setState(() => _n400PrimeVisibleWord = null);
      });
      _n400TargetTimer = Timer(const Duration(milliseconds: 1000), () {
        if (!mounted || !_running) return;
        setState(() {
          _coreStimulusVisible = true;
        });
        SchedulerBinding.instance.addPostFrameCallback((_) {
          if (!_running || !mounted) return;
          _trialRtStopwatch
            ..reset()
            ..start();
          context.read<SessionManager>().recordEvent(
            'N400_${trial.conditionLabel}',
            trial.markerCode,
          );
          _averager?.mark(trial.avgClass);
        });
        _stimOffTimer = Timer(Duration(milliseconds: spec.stimDurationMs), () {
          if (mounted) setState(() => _coreStimulusVisible = false);
        });
      });
      final totalMs = 1000 + spec.stimDurationMs + isi;
      if (_trial < _corePlan.length) {
        _scheduleCoreTrial(totalMs, spec);
      } else {
        _nextTrialTimer = Timer(Duration(milliseconds: totalMs + 400), () {
          if (_running && mounted) unawaited(_stop());
        });
      }
      return;
    }

    // Visual ERP CORE tasks (N170, N2pc, P3b, ERN/LRP Flankers)
    setState(() {
      _activeCoreTrial = trial;
      _n400PrimeVisibleWord = null;
      _coreStimulusVisible = true;
      _coreTrialResponded = false;
      _trial++;
    });
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!_running || !mounted) return;
      _trialRtStopwatch
        ..reset()
        ..start();
      context.read<SessionManager>().recordEvent(
        '${spec.component}_${trial.conditionLabel}',
        trial.markerCode,
      );
      _averager?.mark(trial.avgClass);
    });
    _stimOffTimer = Timer(Duration(milliseconds: spec.stimDurationMs), () {
      if (mounted) setState(() => _coreStimulusVisible = false);
    });
    final totalMs = spec.stimDurationMs + isi;
    if (_trial < _corePlan.length) {
      _scheduleCoreTrial(totalMs, spec);
    } else {
      _nextTrialTimer = Timer(Duration(milliseconds: totalMs + 500), () {
        if (_running && mounted) unawaited(_stop());
      });
    }
  }

  void _recordCoreResponse(bool pressedLeft) {
    final active = _activeCoreTrial;
    final settings = context.read<SettingsService>();
    final spec = erpCoreSpecByName(settings.genericErpParadigm);
    if (!_running || active == null || spec == null || !spec.requiresResponse) {
      return;
    }
    if (_coreTrialResponded) return;
    _coreTrialResponded = true;
    final rtMs = _trialRtStopwatch.elapsedMilliseconds;
    final correct = pressedLeft == active.expectedLeftResponse;
    final respBase = switch (spec.id) {
      ErpCoreParadigmId.n170 => 110,
      ErpCoreParadigmId.mmn => 210,
      ErpCoreParadigmId.n2pc => 310,
      ErpCoreParadigmId.n400 => 410,
      ErpCoreParadigmId.p3b => 510,
      ErpCoreParadigmId.flankers => 610,
    };
    final respCode = correct ? respBase : respBase + 1;
    final session = context.read<SessionManager>();
    session.recordEvent(
      '${spec.component}_${correct ? 'Correct' : 'Error'}',
      respCode,
    );
    if (spec.id == ErpCoreParadigmId.flankers) {
      _averager?.mark(correct ? 'Correct' : 'Error');
    }
    _behavioralCsvRows.add(
      '$_trial,${spec.component},${active.conditionLabel},${active.markerCode},$pressedLeft,${active.expectedLeftResponse},$correct,$rtMs',
    );
    setState(() {
      _totalResponses++;
      if (correct) _correctResponses++;
    });
  }

  void _scheduleTrialAt(int targetElapsedMs) {
    if (!_running || !mounted) return;
    final remaining = targetElapsedMs - _sessionStopwatch.elapsedMilliseconds;
    _nextTrialTimer?.cancel();
    _nextTrialTimer = Timer(
      Duration(milliseconds: remaining > 0 ? remaining : 0),
      () {
        if (!_running || !mounted) return;
        final settings = context.read<SettingsService>();
        final nextTargetMs = targetElapsedMs + settings.genericErpIntervalMs;
        _presentTrial();
        if (_running && _trial < settings.genericErpTrials) {
          _scheduleTrialAt(nextTargetMs);
        }
      },
    );
  }

  void _presentTrial() {
    if (!_running || !mounted) return;
    final settings = context.read<SettingsService>();
    if (_trial >= settings.genericErpTrials) {
      unawaited(_stop());
      return;
    }
    if (settings.genericErpParadigm == 'P50') {
      setState(() => _trial++);
      _presentP50Pair(settings);
      return;
    }

    final rare = _trialPlan[_trial];
    final code = rare
        ? settings.genericErpRareMarker
        : settings.genericErpFrequentMarker;
    final label =
        '${settings.genericErpParadigm}_${rare ? 'rare' : 'frequent'}';
    final avgClass = rare ? 'Rare' : 'Frequent';
    final isAuditory = _isAuditory(settings.genericErpParadigm);

    if (isAuditory) {
      // Auditory: dispatch audio + emit marker together without I/O delay.
      _playAuditoryImmediate(
        rare ? settings.genericErpRareFilePath : settings.genericErpFrequentFilePath,
        exists: rare ? _rareFileExists : _frequentFileExists,
      );
      context.read<SessionManager>().recordEvent(label, code);
      _averager?.mark(avgClass);
      setState(() {
        _rare = rare;
        _trial++;
      });
    } else {
      // Visual: update frame first, then lock marker to painted VSync frame.
      setState(() {
        _rare = rare;
        _trial++;
      });
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (!_running || !mounted) return;
        context.read<SessionManager>().recordEvent(label, code);
        _averager?.mark(avgClass);
      });
    }

    if (_trial >= settings.genericErpTrials) {
      final finishDelay = settings.genericErpIntervalMs;
      _nextTrialTimer?.cancel();
      _nextTrialTimer = Timer(Duration(milliseconds: finishDelay), () {
        if (_running && mounted) unawaited(_stop());
      });
    }
  }

  void _presentP50Pair(SettingsService settings) {
    final session = context.read<SessionManager>();
    _playAuditoryImmediate(
      settings.genericErpFrequentFilePath,
      exists: _frequentFileExists,
    );
    session.recordEvent('P50_S1', settings.genericErpFrequentMarker);
    _averager?.mark('S1');
    setState(() => _rare = false);

    _p50PairTimer?.cancel();
    _p50PairTimer = Timer(const Duration(milliseconds: 500), () {
      if (!_running || !mounted) return;
      _playAuditoryImmediate(
        settings.genericErpRareFilePath,
        exists: _rareFileExists,
      );
      session.recordEvent('P50_S2', settings.genericErpRareMarker);
      _averager?.mark('S2');
      setState(() => _rare = true);
    });
  }

  void _playAuditoryImmediate(String path, {required bool exists}) {
    if (exists && path.isNotEmpty) {
      unawaited(_player.play(DeviceFileSource(path)));
    } else if (mounted) {
      unawaited(context.read<AlertService>().playBeep());
    }
  }

  Future<void> _stop() async {
    _nextTrialTimer?.cancel();
    _nextTrialTimer = null;
    _p50PairTimer?.cancel();
    _p50PairTimer = null;
    _stimOffTimer?.cancel();
    _stimOffTimer = null;
    _n400TargetTimer?.cancel();
    _n400TargetTimer = null;
    _sessionStopwatch.stop();
    _trialRtStopwatch.stop();
    if (_behavioralCsvRows.length > 1) {
      final session = context.read<SessionManager>();
      final settings = context.read<SettingsService>();
      final start = session.sessionStart ?? DateTime.now();
      try {
        final path = await FileNamingService.csvPath(
          settings.subjectCode,
          ModuleType.erp,
          start,
        );
        await File(path).writeAsString(
          '${_behavioralCsvRows.join('\n')}\n',
          flush: true,
        );
        await FileNamingService.exportToDownloads(
          path,
          subject: settings.subjectCode,
          sessionStem: session.currentSessionStem,
        );
      } catch (e) {
        debugPrint('[GenericERP] Behavioral CSV export error: $e');
      }
    }
    if (_ownsRecording && mounted) {
      await context.read<SessionManager>().stopRecording();
    }
    if (mounted) {
      setState(() {
        _running = false;
        _coreStimulusVisible = false;
        _n400PrimeVisibleWord = null;
      });
    }
  }

  bool _isAuditory(String paradigm) =>
      paradigm.contains('Auditory') ||
      paradigm == 'P50' ||
      paradigm == 'MMN' ||
      paradigm == 'ERP CORE: MMN';

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsService>();
    final averager = _averager;
    final coreSpec = erpCoreSpecByName(settings.genericErpParadigm);
    final selectedParadigm = _paradigms.contains(settings.genericErpParadigm)
        ? settings.genericErpParadigm
        : _paradigms.first;
    const components = [
      'P300',
      'P3b',
      'N400',
      'P50',
      'MMN',
      'N170',
      'N2pc',
      'ERN',
      'LRP',
    ];
    final selectedComponent = components.contains(settings.genericErpComponent)
        ? settings.genericErpComponent
        : 'P300';

    return KeyboardListener(
      focusNode: _keyboardFocus,
      onKeyEvent: (event) {
        if (event is! KeyDownEvent) return;
        if (event.logicalKey == LogicalKeyboardKey.keyF) {
          _recordCoreResponse(true);
        } else if (event.logicalKey == LogicalKeyboardKey.keyJ) {
          _recordCoreResponse(false);
        }
      },
      child: Scaffold(
        backgroundColor: StudioColors.canvas,
        appBar: AppBar(
          title: const Text('ERP & ERP CORE Laboratory'),
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
        body: Theme(
          data: Theme.of(context).copyWith(
            inputDecorationTheme: InputDecorationTheme(
              filled: true,
              fillColor: StudioColors.card,
              labelStyle: const TextStyle(color: StudioColors.textSecondary),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: StudioColors.border),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: StudioColors.teal),
              ),
              disabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: StudioColors.border),
              ),
            ),
            outlinedButtonTheme: OutlinedButtonThemeData(
              style: OutlinedButton.styleFrom(
                foregroundColor: StudioColors.teal,
                side: const BorderSide(color: StudioColors.border),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 15),
              ),
            ),
          ),
          child: DefaultTextStyle(
            style: const TextStyle(color: StudioColors.textPrimary),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _panel(
                  title: 'Task configuration',
                  icon: Icons.tune,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          SizedBox(
                            width: 240,
                            child: DropdownButtonFormField<String>(
                              initialValue: selectedParadigm,
                              dropdownColor: StudioColors.card,
                              style: const TextStyle(color: StudioColors.textPrimary),
                              decoration: const InputDecoration(
                                labelText: 'ERP paradigm',
                              ),
                              items: _paradigms
                                  .map(
                                    (value) => DropdownMenuItem(
                                      value: value,
                                      child: Text(value),
                                    ),
                                  )
                                  .toList(),
                              onChanged: _running
                                  ? null
                                  : (value) => settings.update((s) {
                                      s.genericErpParadigm = value!;
                                      final spec = erpCoreSpecByName(value);
                                      if (spec != null) {
                                        s.genericErpComponent = spec.component;
                                        s.genericErpTrials = spec.quickTrials;
                                      } else {
                                        s.genericErpComponent =
                                            _defaultComponent(value);
                                      }
                                    }),
                            ),
                          ),
                          SizedBox(
                            width: 165,
                            child: DropdownButtonFormField<String>(
                              initialValue: selectedComponent,
                              dropdownColor: StudioColors.card,
                              style: const TextStyle(color: StudioColors.textPrimary),
                              decoration: const InputDecoration(
                                labelText: 'ERP waveform',
                              ),
                              items: components
                                  .map(
                                    (value) => DropdownMenuItem(
                                      value: value,
                                      child: Text(value),
                                    ),
                                  )
                                  .toList(),
                              onChanged: (value) => settings.update(
                                (s) => s.genericErpComponent = value!,
                              ),
                            ),
                          ),
                          _numberField(
                            'Trials',
                            settings.genericErpTrials,
                            (value) => settings.update(
                              (s) => s.genericErpTrials = value.clamp(10, 1200),
                            ),
                          ),
                          if (coreSpec == null) ...[
                            _numberField(
                              'Interval (ms)',
                              settings.genericErpIntervalMs,
                              (value) => settings.update(
                                (s) => s.genericErpIntervalMs = value.clamp(
                                  200,
                                  10000,
                                ),
                              ),
                            ),
                            _numberField(
                              'Standard code',
                              settings.genericErpFrequentMarker,
                              (value) => settings.update(
                                (s) => s.genericErpFrequentMarker = value.clamp(
                                  1,
                                  32767,
                                ),
                              ),
                            ),
                            _numberField(
                              'Target code',
                              settings.genericErpRareMarker,
                              (value) => settings.update(
                                (s) => s.genericErpRareMarker = value.clamp(
                                  1,
                                  32767,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      if (coreSpec != null) ...[
                        const SizedBox(height: 12),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: StudioColors.surface,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: StudioColors.teal.withValues(alpha: 0.35),
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Text(
                                    coreSpec.title,
                                    style: const TextStyle(
                                      color: StudioColors.teal,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13.5,
                                    ),
                                  ),
                                  const Spacer(),
                                  TextButton(
                                    onPressed: _running
                                        ? null
                                        : () => settings.update(
                                            (s) => s.genericErpTrials =
                                                coreSpec.quickTrials,
                                          ),
                                    child: Text(
                                      'Quick (${coreSpec.quickTrials})',
                                    ),
                                  ),
                                  TextButton(
                                    onPressed: _running
                                        ? null
                                        : () => settings.update(
                                            (s) => s.genericErpTrials =
                                                coreSpec.fullTrials,
                                          ),
                                    child: Text(
                                      'Full ERP CORE (${coreSpec.fullTrials})',
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Text(
                                coreSpec.instructions,
                                style: const TextStyle(
                                  color: StudioColors.textSecondary,
                                  fontSize: 12,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Timing: ${coreSpec.stimDurationMs} ms stim • ${coreSpec.minIsiMs}–${coreSpec.maxIsiMs} ms ISI'
                                '${_totalResponses > 0 ? ' • Accuracy: ${(_correctResponses * 100 / _totalResponses).round()}% ($_correctResponses/$_totalResponses)' : ''}',
                                style: const TextStyle(
                                  color: StudioColors.textMuted,
                                  fontSize: 11.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ] else ...[
                        const SizedBox(height: 14),
                        Text(
                          'Target probability ${(settings.genericErpRareProbability * 100).round()}%',
                          style: const TextStyle(color: StudioColors.textSecondary),
                        ),
                        Slider(
                          value: settings.genericErpRareProbability,
                          min: 0.05,
                          max: 0.5,
                          divisions: 9,
                          onChanged: _running
                              ? null
                              : (value) => settings.update(
                                  (s) => s.genericErpRareProbability = value,
                                ),
                        ),
                        LayoutBuilder(
                          builder: (context, constraints) {
                            final tiles = [
                              _fileTile(
                                'Standard stimulus',
                                settings.genericErpFrequentFilePath,
                                false,
                              ),
                              _fileTile(
                                'Target stimulus',
                                settings.genericErpRareFilePath,
                                true,
                              ),
                            ];
                            if (constraints.maxWidth < 650) {
                              return Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  tiles.first,
                                  const SizedBox(height: 8),
                                  tiles.last,
                                ],
                              );
                            }
                            return Row(
                              children: [
                                Expanded(child: tiles.first),
                                const SizedBox(width: 10),
                                Expanded(child: tiles.last),
                              ],
                            );
                          },
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                _panel(
                  title: coreSpec == null
                      ? 'Stimulus preview'
                      : 'ERP CORE stimulus & response',
                  icon: Icons.visibility_outlined,
                  child: Column(
                    children: [
                      Container(
                        height: 210,
                        width: double.infinity,
                        decoration: BoxDecoration(
                          color: const Color(0xFF111827),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: Colors.white10),
                        ),
                        child: coreSpec != null
                            ? _coreStimulusCanvas(coreSpec)
                            : (_isAuditory(settings.genericErpParadigm)
                                  ? Center(
                                      child: Icon(
                                        _rare
                                            ? Icons.notifications_active
                                            : Icons.volume_up,
                                        size: _rare ? 110 : 70,
                                        color: _rare
                                            ? Colors.orange
                                            : Colors.tealAccent,
                                      ),
                                    )
                                  : _visualStimulus(settings)),
                      ),
                      if (coreSpec != null && coreSpec.requiresResponse) ...[
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton(
                                onPressed: _running
                                    ? () => _recordCoreResponse(true)
                                    : null,
                                child: Text(coreSpec.leftResponseLabel),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: OutlinedButton(
                                onPressed: _running
                                    ? () => _recordCoreResponse(false)
                                    : null,
                                child: Text(coreSpec.rightResponseLabel),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                _panel(
                  title: 'Realtime ERP',
                  icon: Icons.show_chart,
                  child: Column(
                    children: [
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text(
                          'Show waveform while recording',
                          style: TextStyle(color: StudioColors.textPrimary),
                        ),
                        subtitle: Text(
                          '$selectedComponent • baseline −100 to 0 ms • epoch to 800 ms',
                          style: const TextStyle(color: StudioColors.textSecondary),
                        ),
                        value: settings.genericErpShowRealtime,
                        onChanged: (value) => settings.update(
                          (s) => s.genericErpShowRealtime = value,
                        ),
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text(
                          'Overlay difference wave (Target − Standard)',
                          style: TextStyle(color: StudioColors.textPrimary),
                        ),
                        value: _showDifferenceWave,
                        onChanged: (v) =>
                            setState(() => _showDifferenceWave = v),
                      ),
                      if (settings.genericErpShowRealtime && averager != null)
                        SizedBox(
                          height: 240,
                          child: ValueListenableBuilder<int>(
                            valueListenable: averager.version,
                            builder: (_, __, ___) => ErpWaveformPlot(
                              averages: averager.averages,
                              counts: averager.counts,
                              sampleRate: context
                                  .read<AcquisitionService>()
                                  .sampleRate,
                              component: selectedComponent,
                              showDifferenceWave: _showDifferenceWave,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(50),
                  ),
                  onPressed: _running ? _stop : _start,
                  icon: Icon(_running ? Icons.stop : Icons.play_arrow),
                  label: Text(
                    _running
                        ? 'Stop • trial $_trial/${settings.genericErpTrials}'
                        : 'Start ${coreSpec?.shortName ?? "ERP task"}',
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _coreStimulusCanvas(ErpCoreParadigmSpec spec) {
    final active = _activeCoreTrial;
    if (spec.id == ErpCoreParadigmId.mmn) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _coreStimulusVisible
                  ? (active?.isDeviantTone == true
                        ? Icons.graphic_eq
                        : Icons.volume_up)
                  : Icons.add,
              size: _coreStimulusVisible ? 88 : 36,
              color: _coreStimulusVisible
                  ? (active?.isDeviantTone == true
                        ? Colors.orangeAccent
                        : Colors.tealAccent)
                  : Colors.white38,
            ),
            if (_coreStimulusVisible && active != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  active.conditionLabel,
                  style: const TextStyle(color: Colors.white60, fontSize: 12),
                ),
              ),
          ],
        ),
      );
    }

    if (spec.id == ErpCoreParadigmId.n400) {
      if (_n400PrimeVisibleWord != null) {
        return Center(
          child: Text(
            _n400PrimeVisibleWord!,
            style: const TextStyle(
              color: Colors.redAccent,
              fontSize: 34,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.5,
            ),
          ),
        );
      }
      if (_coreStimulusVisible && active != null) {
        return Center(
          child: Text(
            active.targetWord,
            style: const TextStyle(
              color: Colors.tealAccent,
              fontSize: 34,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.5,
            ),
          ),
        );
      }
      return const Center(
        child: Text('+', style: TextStyle(color: Colors.white54, fontSize: 28)),
      );
    }

    if (!_coreStimulusVisible || active == null) {
      return const Center(
        child: Text('+', style: TextStyle(color: Colors.white54, fontSize: 28)),
      );
    }

    return switch (spec.id) {
      ErpCoreParadigmId.n170 => CustomPaint(
        size: const Size(220, 190),
        painter: N170StimulusPainter(kind: active.n170Kind, seed: active.seed),
      ),
      ErpCoreParadigmId.n2pc => CustomPaint(
        size: const Size(340, 190),
        painter: N2pcSearchPainter(
          targetOnLeft: active.targetOnLeft,
          targetGapTop: active.targetGapTop,
          seed: active.seed,
        ),
      ),
      ErpCoreParadigmId.p3b || ErpCoreParadigmId.flankers => Center(
        child: Text(
          active.displayText,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 48,
            fontWeight: FontWeight.w800,
            letterSpacing: 6,
          ),
        ),
      ),
      ErpCoreParadigmId.mmn || ErpCoreParadigmId.n400 => const SizedBox.shrink(),
    };
  }

  Widget _panel({
    required String title,
    required IconData icon,
    required Widget child,
  }) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: StudioColors.card,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: StudioColors.border),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, color: StudioColors.teal, size: 20),
            const SizedBox(width: 8),
            Text(
              title,
              style: const TextStyle(
                color: StudioColors.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        child,
      ],
    ),
  );

  Widget _numberField(String label, int value, ValueChanged<int> changed) =>
      SizedBox(
        width: 150,
        child: TextFormField(
          key: ValueKey('$label-$value'),
          initialValue: '$value',
          enabled: !_running,
          keyboardType: TextInputType.number,
          style: const TextStyle(color: StudioColors.textPrimary),
          decoration: InputDecoration(labelText: label),
          onFieldSubmitted: (text) {
            final parsed = int.tryParse(text);
            if (parsed != null) changed(parsed);
          },
        ),
      );

  Widget _fileTile(String label, String path, bool rare) => OutlinedButton.icon(
    onPressed: _running ? null : () => _pickFile(rare),
    icon: const Icon(Icons.folder_open),
    label: Text(
      path.isEmpty
          ? '$label: use default'
          : '$label: ${path.split(Platform.pathSeparator).last}',
    ),
  );

  Widget _visualStimulus(SettingsService settings) {
    final path = _rare
        ? settings.genericErpRareFilePath
        : settings.genericErpFrequentFilePath;
    if (path.isNotEmpty &&
        ( _rare ? _rareFileExists : _frequentFileExists )) {
      return Image.file(File(path), fit: BoxFit.contain, gaplessPlayback: true);
    }
    return Center(
      child: Container(
        width: _rare ? 150 : 90,
        height: _rare ? 150 : 90,
        decoration: BoxDecoration(
          color: _rare ? Colors.orange : Colors.teal,
          shape: _rare ? BoxShape.circle : BoxShape.rectangle,
        ),
      ),
    );
  }

  String _defaultComponent(String paradigm) => switch (paradigm) {
    'N400' => 'N400',
    'P50' => 'P50',
    'MMN' => 'MMN',
    'N170' => 'N170',
    _ => 'P300',
  };
}

class ErpWaveformPlot extends StatelessWidget {
  const ErpWaveformPlot({
    super.key,
    required this.averages,
    required this.sampleRate,
    required this.component,
    this.counts = const {},
    this.showDifferenceWave = false,
  });

  final Map<String, List<double>> averages;
  final Map<String, int> counts;
  final double sampleRate;
  final String component;
  final bool showDifferenceWave;

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: CustomPaint(
      painter: _ErpPainter(
        averages: averages,
        counts: counts,
        sampleRate: sampleRate,
        component: component,
        showDifferenceWave: showDifferenceWave,
      ),
    ),
  );
}

class _ErpPainter extends CustomPainter {
  const _ErpPainter({
    required this.averages,
    required this.counts,
    required this.sampleRate,
    required this.component,
    this.showDifferenceWave = false,
  });
  final Map<String, List<double>> averages;
  final Map<String, int> counts;
  final double sampleRate;
  final String component;
  final bool showDifferenceWave;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawColor(StudioColors.card, BlendMode.src);
    final grid = Paint()..color = StudioColors.border;
    canvas.drawLine(
      Offset(0, size.height / 2),
      Offset(size.width, size.height / 2),
      grid,
    );
    double xForMs(double ms) => size.width * (ms + 100) / 900;
    // 0 ms stimulus onset vertical line
    canvas.drawLine(
      Offset(xForMs(0), 0),
      Offset(xForMs(0), size.height),
      Paint()
        ..color = StudioColors.textMuted
        ..strokeWidth = 1,
    );

    final window = switch (component) {
      'P50' => (40.0, 80.0),
      'N170' => (110.0, 210.0),
      'N2pc' => (200.0, 300.0),
      'N400' => (300.0, 500.0),
      'MMN' => (100.0, 250.0),
      'ERN' || 'LRP' => (0.0, 150.0),
      'CDA' => (300.0, 800.0),
      'P3b' => (300.0, 600.0),
      _ => (250.0, 500.0),
    };
    canvas.drawRect(
      Rect.fromLTRB(xForMs(window.$1), 0, xForMs(window.$2), size.height),
      Paint()..color = StudioColors.teal.withValues(alpha: 0.08),
    );
    final entries = averages.entries.toList(growable: false);
    List<double>? diffWave;
    if (showDifferenceWave && entries.length >= 2) {
      final a = entries[0].value;
      final b = entries[1].value;
      final n = min(a.length, b.length);
      if (n >= 2) {
        diffWave = List<double>.generate(n, (i) => b[i] - a[i], growable: false);
      }
    }
    final all = [
      ...averages.values.expand((value) => value),
      if (diffWave != null) ...diffWave,
    ];
    final scale = all.isEmpty
        ? 1.0
        : all.map((v) => v.abs()).fold<double>(1, max);
    for (var idx = 0; idx < entries.length; idx++) {
      final entry = entries[idx];
      if (entry.value.length < 2) continue;
      final path = Path();
      for (var index = 0; index < entry.value.length; index++) {
        final x = size.width * index / (entry.value.length - 1);
        final y =
            size.height / 2 - entry.value[index] / scale * size.height * 0.42;
        index == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
      }
      final isSecondary =
          entry.key == 'Rare' ||
          entry.key == 'Deviant' ||
          entry.key == 'Target' ||
          entry.key == 'Unrelated' ||
          entry.key == 'Error' ||
          entry.key == 'S2' ||
          entry.key == 'Right' ||
          idx == 1;
      canvas.drawPath(
        path,
        Paint()
          ..color = isSecondary ? StudioColors.red : StudioColors.teal
          ..strokeWidth = 2
          ..style = PaintingStyle.stroke,
      );
    }
    if (diffWave != null) {
      final path = Path();
      for (var index = 0; index < diffWave.length; index++) {
        final x = size.width * index / (diffWave.length - 1);
        final y =
            size.height / 2 - diffWave[index] / scale * size.height * 0.42;
        index == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = StudioColors.amber
          ..strokeWidth = 1.6
          ..style = PaintingStyle.stroke,
      );
    }
    final summary = counts.isEmpty
        ? component
        : '$component  •  ${counts.entries.map((e) => '${e.key} (n=${e.value})').join(' / ')}';
    final text = TextPainter(
      text: TextSpan(
        text: summary,
        style: const TextStyle(color: StudioColors.textSecondary, fontSize: 10.5),
      ),
      maxLines: 1,
      ellipsis: '…',
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: size.width - 16);
    text.paint(canvas, const Offset(8, 6));
  }

  @override
  bool shouldRepaint(covariant _ErpPainter oldDelegate) =>
      oldDelegate.averages != averages ||
      oldDelegate.component != component ||
      oldDelegate.showDifferenceWave != showDifferenceWave;
}
