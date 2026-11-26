import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/eeg/acquisition_service.dart';
import '../../core/models/device_profile.dart';
import '../../core/models/manual_marker.dart';
import '../../core/models/module_type.dart';
import '../../core/models/stream_marker.dart';
import '../../core/services/av_sync_service.dart';
import '../../core/services/channel_config_service.dart';
import '../../core/services/multi_device_acquisition_service.dart';
import '../../core/services/multi_stream_lsl_service.dart';
import '../../core/services/permission_service.dart';
import '../../core/services/session_manager.dart';
import '../../core/services/settings_service.dart';
import '../../core/theme/studio_theme.dart';
import '../../core/widgets/connection_status_bar.dart';
import '../../core/widgets/eeg_viewer.dart';

/// Standalone EEG & Multi-signal Recorder cum Viewer.
///
/// Optimized for maximum waveform screen area on both mobile and laptop
/// displays, with integrated save-folder selection, marker/annotation bank,
/// real-time PSD, and per-channel quality/montage controls.
class StandaloneScreen extends StatefulWidget {
  const StandaloneScreen({super.key, this.viewerOnly = false});

  final bool viewerOnly;

  @override
  State<StandaloneScreen> createState() => _StandaloneScreenState();
}

class _StandaloneScreenState extends State<StandaloneScreen> {
  late TextEditingController _subjectController;
  Timer? _uiRefreshTimer;
  StreamSubscription<AcquisitionState>? _acqStateSub;
  bool _eegDisconnected = false;
  bool _showMarkerBar = false;
  final List<StreamMarker> _sessionMarkers = [];
  StreamSubscription<StreamMarker>? _markerSub;

  @override
  void initState() {
    super.initState();
    final settings = context.read<SettingsService>();
    _subjectController = TextEditingController(text: settings.subjectCode);

    _uiRefreshTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (context.read<SessionManager>().isRecording) {
        setState(() {});
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final code = context.read<SettingsService>().subjectCode;
      if (code.isNotEmpty && _subjectController.text != code) {
        setState(() => _subjectController.text = code);
      }
      final eegService = context.read<AcquisitionService>();
      _acqStateSub = eegService.state.listen(_handleAcqState);
      _handleAcqState(eegService.currentState);

      final session = context.read<SessionManager>();
      if (session.isRecording) {
        setState(() => _showMarkerBar = true);
      }
      _markerSub = session.eventMarkers.listen((marker) {
        if (!mounted) return;
        setState(() {
          final existing = _sessionMarkers.indexWhere(
            (m) => m.receivedAt == marker.receivedAt && m.code == marker.code,
          );
          if (existing >= 0) {
            _sessionMarkers[existing] = marker;
          } else {
            _sessionMarkers.add(marker);
          }
        });
      });
    });
  }

  void _handleAcqState(AcquisitionState state) {
    final disconnected = state != AcquisitionState.streaming;
    if (disconnected != _eegDisconnected && mounted) {
      setState(() => _eegDisconnected = disconnected);
    }
  }

  @override
  void dispose() {
    _uiRefreshTimer?.cancel();
    _acqStateSub?.cancel();
    _markerSub?.cancel();
    _subjectController.dispose();
    super.dispose();
  }

  Future<void> _toggleRecording({
    required SessionManager sessionManager,
    required AcquisitionService eegService,
    required SettingsService settings,
    required ChannelConfigService channelConfig,
  }) async {
    if (sessionManager.isRecording) {
      await sessionManager.stopRecording();
      return;
    }
    final hasStorage = await context
        .read<PermissionService>()
        .requestManageExternalStorage(context);
    if (!hasStorage) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Cannot start recording: storage permission is required.',
            ),
          ),
        );
      }
      return;
    }
    final code = _subjectController.text.trim().isEmpty
        ? 'S001'
        : _subjectController.text.trim();
    if (!mounted) return;
    settings.updateSubjectCode(code);
    setState(() => _showMarkerBar = true);
    await sessionManager.startRecording(
      module: ModuleType.standalone,
      subjectId: code,
      channelCount: eegService.channelCount,
      sampleRate: eegService.sampleRate.toInt(),
      channelLabels: eegService.recordingChannelLabels(channelConfig.labels),
      enabledChannels: eegService.recordingEnabledChannels(
        channelConfig.enabled,
      ),
    );
  }

  Future<void> _showOutputFolderSheet(SettingsService settings) async {
    final currentPath = await settings.effectiveOutputDirectory();
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: StudioColors.elevated,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Recording Save Location',
                style: TextStyle(
                  color: StudioColors.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: StudioColors.canvas,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: StudioColors.border),
                ),
                child: SelectableText(
                  currentPath,
                  style: const TextStyle(
                    color: StudioColors.textSecondary,
                    fontFamily: 'monospace',
                    fontSize: 12,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: () async {
                      final changed = await settings.chooseOutputDirectory();
                      if (!ctx.mounted) return;
                      Navigator.pop(ctx);
                      if (changed && mounted) {
                        final next = await settings.effectiveOutputDirectory();
                        if (!mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Save folder: $next')),
                        );
                      }
                    },
                    icon: const Icon(Icons.drive_folder_upload_outlined),
                    label: const Text('Choose Folder'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () {
                      settings.openOutputDirectory();
                      Navigator.pop(ctx);
                    },
                    icon: const Icon(Icons.folder_open),
                    label: const Text('Open Folder'),
                  ),
                  TextButton.icon(
                    onPressed: settings.outputDirectoryPath.isEmpty
                        ? null
                        : () async {
                            await settings.resetOutputDirectory();
                            if (ctx.mounted) Navigator.pop(ctx);
                          },
                    icon: const Icon(Icons.restore),
                    label: const Text('Reset Default'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showCustomMarkerDialog(
    SessionManager sessionManager,
    SettingsService settings,
  ) async {
    final nameCtrl = TextEditingController();
    final nextCode =
        (settings.activeManualMarkers
                .map((m) => m.code)
                .fold<int>(0, (a, b) => a > b ? a : b) +
            1)
        .clamp(1, 32767);
    final codeCtrl = TextEditingController(text: '$nextCode');
    var saveToProfile = true;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: StudioColors.elevated,
          title: const Text(
            'Add Annotation / Marker',
            style: TextStyle(color: StudioColors.textPrimary),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                autofocus: true,
                style: const TextStyle(color: StudioColors.textPrimary),
                decoration: const InputDecoration(
                  labelText: 'Annotation / Event Name',
                  hintText: 'e.g. Eyes Closed, Blink, Artifact',
                ),
                onSubmitted: (_) => Navigator.pop(ctx, true),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: codeCtrl,
                keyboardType: TextInputType.number,
                style: const TextStyle(color: StudioColors.textPrimary),
                decoration: const InputDecoration(
                  labelText: 'Numeric Marker Code (1–32767)',
                ),
              ),
              const SizedBox(height: 6),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: saveToProfile,
                activeColor: StudioColors.teal,
                title: Text(
                  'Save button to "${settings.activeMarkerProfile}" profile',
                  style: const TextStyle(
                    color: StudioColors.textSecondary,
                    fontSize: 12.5,
                  ),
                ),
                onChanged: (v) =>
                    setDialogState(() => saveToProfile = v ?? true),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Emit Marker'),
            ),
          ],
        ),
      ),
    );

    final rawName = nameCtrl.text.trim();
    final code = (int.tryParse(codeCtrl.text.trim()) ?? nextCode).clamp(
      1,
      32767,
    );
    nameCtrl.dispose();
    codeCtrl.dispose();

    if (confirmed != true || rawName.isEmpty || !mounted) return;
    _emitMarker(sessionManager, rawName, code);

    if (saveToProfile) {
      final updated = List<ManualMarkerDefinition>.from(
        settings.activeManualMarkers,
      );
      if (!updated.any((m) => m.name == rawName && m.code == code)) {
        updated.add(
          ManualMarkerDefinition(
            name: rawName,
            code: code,
            colorValue: StudioColors.sky.toARGB32(),
          ),
        );
        settings.saveMarkerProfile(settings.activeMarkerProfile, updated);
      }
    }
  }

  void _emitMarker(SessionManager sessionManager, String name, int code) {
    final event = StreamMarker(
      streamId: 'manual',
      source: 'CCS Mobile Studio',
      value: name,
      code: code,
      receivedAt: DateTime.now(),
    );
    sessionManager.recordEvent(name, code, marker: event);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Tagged "$name" (code $code)'),
        duration: const Duration(seconds: 3),
        action: SnackBarAction(
          label: 'Rename',
          onPressed: () => _editRecordedMarker(sessionManager, event),
        ),
      ),
    );
  }

  Future<void> _editRecordedMarker(
    SessionManager sessionManager,
    StreamMarker marker,
  ) async {
    final controller = TextEditingController(text: marker.value);
    final value = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: StudioColors.elevated,
        title: Text('Edit marker ${marker.code}'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Marker name'),
          onSubmitted: (text) => Navigator.pop(dialogContext, text),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value != null && value.trim().isNotEmpty) {
      sessionManager.renameEvent(marker, value.trim());
    }
  }

  Future<void> _showMarkerLogDialog(SessionManager sessionManager) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: StudioColors.elevated,
        title: Text(
          'Session Annotations (${_sessionMarkers.length})',
          style: const TextStyle(color: StudioColors.textPrimary),
        ),
        content: SizedBox(
          width: 420,
          height: 300,
          child: _sessionMarkers.isEmpty
              ? const Center(
                  child: Text(
                    'No markers recorded in this session yet.',
                    style: TextStyle(color: StudioColors.textSecondary),
                  ),
                )
              : ListView.separated(
                  itemCount: _sessionMarkers.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, idx) {
                    final m = _sessionMarkers[_sessionMarkers.length - 1 - idx];
                    final ts = m.receivedAt.toIso8601String().substring(11, 19);
                    return ListTile(
                      dense: true,
                      title: Text(
                        m.value,
                        style: const TextStyle(
                          color: StudioColors.textPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      subtitle: Text(
                        '$ts • Code ${m.code} • ${m.source}',
                        style: const TextStyle(
                          color: StudioColors.textSecondary,
                          fontSize: 11.5,
                        ),
                      ),
                      trailing: IconButton(
                        icon: const Icon(
                          Icons.edit_outlined,
                          size: 17,
                          color: StudioColors.teal,
                        ),
                        onPressed: () {
                          Navigator.pop(ctx);
                          _editRecordedMarker(sessionManager, m);
                        },
                      ),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Widget _buildMarkerStrip(
    SessionManager sessionManager,
    SettingsService settings,
  ) {
    final markers = settings.activeManualMarkers;
    final profileNames = settings.markerProfiles.keys.toList(growable: false);

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: StudioColors.card,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: StudioColors.border),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            if (profileNames.length > 1) ...[
              DropdownButton<String>(
                value: settings.activeMarkerProfile,
                isDense: true,
                dropdownColor: StudioColors.elevated,
                underline: const SizedBox.shrink(),
                style: const TextStyle(
                  color: StudioColors.teal,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
                items: profileNames
                    .map((n) => DropdownMenuItem(value: n, child: Text(n)))
                    .toList(),
                onChanged: (next) {
                  if (next != null) {
                    settings.update((s) => s.activeMarkerProfile = next);
                  }
                },
              ),
              const SizedBox(width: 8),
            ],
            ...markers.map(
              (def) => Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ActionChip(
                  backgroundColor: def.color.withValues(alpha: 0.16),
                  side: BorderSide(color: def.color.withValues(alpha: 0.5)),
                  label: Text(
                    '${def.name} (${def.code})',
                    style: TextStyle(
                      color: def.color,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  onPressed: () =>
                      _emitMarker(sessionManager, def.name, def.code),
                ),
              ),
            ),
            ActionChip(
              avatar: const Icon(Icons.add, size: 15, color: StudioColors.sky),
              backgroundColor: StudioColors.surface,
              side: const BorderSide(color: StudioColors.border),
              label: const Text(
                'Custom',
                style: TextStyle(color: StudioColors.sky, fontSize: 11.5),
              ),
              onPressed: () =>
                  _showCustomMarkerDialog(sessionManager, settings),
            ),
            const SizedBox(width: 6),
            ActionChip(
              avatar: const Icon(
                Icons.history,
                size: 15,
                color: StudioColors.textSecondary,
              ),
              backgroundColor: StudioColors.surface,
              side: const BorderSide(color: StudioColors.border),
              label: Text(
                'Log (${_sessionMarkers.length})',
                style: const TextStyle(
                  color: StudioColors.textSecondary,
                  fontSize: 11.5,
                ),
              ),
              onPressed: () => _showMarkerLogDialog(sessionManager),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConnectedStreamTabs(
    AcquisitionService eegService,
    MultiStreamLslService multiLsl,
    MultiDeviceAcquisitionService multiDevice,
  ) {
    final markerAction = InkWell(
      onTap: () => setState(() => _showMarkerBar = !_showMarkerBar),
      borderRadius: BorderRadius.circular(7),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: _showMarkerBar
              ? StudioColors.amber.withValues(alpha: 0.16)
              : StudioColors.surface,
          borderRadius: BorderRadius.circular(7),
          border: Border.all(
            color: _showMarkerBar
                ? StudioColors.amber.withValues(alpha: 0.65)
                : StudioColors.border,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.bookmark_add_outlined,
              size: 14,
              color: _showMarkerBar
                  ? StudioColors.amber
                  : StudioColors.textSecondary,
            ),
            const SizedBox(width: 4),
            Text(
              'Markers',
              style: TextStyle(
                color: _showMarkerBar
                    ? StudioColors.amber
                    : StudioColors.textSecondary,
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );

    final entries = multiLsl.connectedStreamProfiles.entries
        .where((entry) => entry.value.signalType != SignalType.marker)
        .toList(growable: false);
    final showPrimary = eegService.isStreamReady;
    final secondary = multiDevice.readySecondaryServices;
    final labels = <String>[
      if (showPrimary) eegService.connectedDeviceLabel,
      ...secondary.map((service) => service.connectedDeviceLabel),
      ...entries.map((entry) => entry.value.name),
    ];
    final viewers = <Widget>[
      if (showPrimary)
        EegViewer(
          key: ValueKey('device-${eegService.connectedDeviceId}'),
          eegService: eegService,
          displayStateKey: 'device:${eegService.connectedDeviceId}',
          initialDurationSeconds: 10,
          showControls: true,
          showMetrics: true,
          markerStream: context.read<SessionManager>().eventMarkers,
          extraToolbarActions: [markerAction],
        ),
      ...secondary.map(
        (service) => EegViewer(
          key: ValueKey('direct-${service.connectedDeviceId}'),
          eegService: service,
          displayStateKey: 'device:${service.connectedDeviceId}',
          initialDurationSeconds: 10,
          showControls: true,
          showMetrics: true,
          markerStream: context.read<SessionManager>().eventMarkers,
          extraToolbarActions: [markerAction],
        ),
      ),
      ...entries.map((entry) {
        final runtime = SignalStreamProfile.fromJson(entry.value.toJson())
          ..id = entry.key;
        return EegViewer(
          key: ValueKey(entry.key),
          signalStream: multiLsl.samples,
          signalProfile: runtime,
          displayStateKey: 'stream:${entry.key}',
          initialDurationSeconds: 10,
          showControls: true,
          showMetrics: runtime.signalType != SignalType.fnirs,
          markerStream: context.read<SessionManager>().eventMarkers,
          extraToolbarActions: [markerAction],
        );
      }),
    ];
    if (viewers.isEmpty) {
      return Center(
        child: Container(
          padding: const EdgeInsets.all(24),
          constraints: const BoxConstraints(maxWidth: 420),
          decoration: BoxDecoration(
            color: StudioColors.card,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: StudioColors.border),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.bluetooth_searching,
                color: StudioColors.teal,
                size: 36,
              ),
              const SizedBox(height: 12),
              const Text(
                'No validated signal stream connected',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: StudioColors.textPrimary,
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                'Connect an amplifier, LSL stream, or 16-ch synthetic simulator to begin viewing waveforms and recording EDF+.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: StudioColors.textSecondary,
                  fontSize: 12.5,
                ),
              ),
              const SizedBox(height: 14),
              FilledButton.icon(
                onPressed: () => showDeviceConnectionDialog(context),
                icon: const Icon(Icons.link, size: 18),
                label: const Text('Connect Device'),
              ),
            ],
          ),
        ),
      );
    }
    if (viewers.length == 1) return viewers.single;
    return DefaultTabController(
      key: ValueKey(labels.join('|')),
      length: viewers.length,
      child: Column(
        children: [
          Container(
            height: 34,
            color: StudioColors.surface,
            child: TabBar(
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              indicatorColor: StudioColors.teal,
              labelColor: StudioColors.teal,
              unselectedLabelColor: StudioColors.textSecondary,
              tabs: labels.map((label) => Tab(text: label)).toList(),
            ),
          ),
          Expanded(child: TabBarView(children: viewers)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final eegService = context.watch<AcquisitionService>();
    final multiLsl = context.watch<MultiStreamLslService>();
    final multiDevice = context.watch<MultiDeviceAcquisitionService>();
    final sessionManager = context.watch<SessionManager>();
    final avSync = context.watch<AvSyncService>();
    final settings = context.watch<SettingsService>();
    final channelConfig = context.watch<ChannelConfigService>();
    final width = MediaQuery.sizeOf(context).width;
    final compact = width < 720;
    final isRecording = sessionManager.isRecording;

    if (_subjectController.text != settings.subjectCode) {
      _subjectController.value = _subjectController.value.copyWith(
        text: settings.subjectCode,
        selection: TextSelection.collapsed(offset: settings.subjectCode.length),
      );
    }

    final avSyncButton = Tooltip(
      message: avSync.isRecording
          ? 'Time-synched Webcam + Audio recording (${avSync.currentTelemetry?.frameCount ?? 0} frames)'
          : (avSync.lastError != null
                ? 'AV Sync issue: ${avSync.lastError}'
                : (avSync.armed
                      ? 'Time-synched Webcam + Audio ARMED (starts with REC)'
                      : 'Arm time-synched Webcam Video + Audio recording')),
      child: InkWell(
        onTap: isRecording || !avSync.isSupported
            ? null
            : () => avSync.setArmed(!avSync.armed),
        borderRadius: BorderRadius.circular(8),
        child: Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: avSync.isRecording
                ? StudioColors.red.withValues(alpha: 0.22)
                : (avSync.armed
                      ? StudioColors.amber.withValues(alpha: 0.16)
                      : StudioColors.canvas),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: avSync.isRecording
                  ? StudioColors.red
                  : (avSync.armed ? StudioColors.amber : StudioColors.border),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                avSync.isRecording ? Icons.videocam : Icons.videocam_outlined,
                size: 15,
                color: avSync.isRecording
                    ? StudioColors.red
                    : (avSync.armed
                          ? StudioColors.amber
                          : StudioColors.textSecondary),
              ),
              const SizedBox(width: 4),
              Text(
                avSync.isRecording
                    ? 'AV ${avSync.currentTelemetry?.frameCount ?? 0}'
                    : (avSync.armed ? 'AV On' : 'AV'),
                style: TextStyle(
                  color: avSync.isRecording
                      ? StudioColors.red
                      : (avSync.armed
                            ? StudioColors.amber
                            : StudioColors.textSecondary),
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );

    final recordButton = FilledButton.icon(
      style: FilledButton.styleFrom(
        backgroundColor: isRecording ? StudioColors.red : StudioColors.teal,
        foregroundColor: Colors.white,
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      onPressed: () => _toggleRecording(
        sessionManager: sessionManager,
        eegService: eegService,
        settings: settings,
        channelConfig: channelConfig,
      ),
      icon: Icon(isRecording ? Icons.stop : Icons.fiber_manual_record, size: 16),
      label: Text(
        isRecording
            ? (sessionManager.timerPaused
                  ? 'PAUSED'
                  : 'STOP ${sessionManager.formattedDuration}')
            : 'REC',
        style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12.5),
      ),
    );

    final subjectField = SizedBox(
      width: compact ? 92 : 120,
      height: 32,
      child: TextField(
        controller: _subjectController,
        enabled: !isRecording,
        style: const TextStyle(
          color: StudioColors.textPrimary,
          fontWeight: FontWeight.w700,
          fontSize: 12.5,
        ),
        decoration: InputDecoration(
          isDense: true,
          prefixText: 'ID ',
          prefixStyle: const TextStyle(
            color: StudioColors.textMuted,
            fontSize: 11,
          ),
          filled: true,
          fillColor: StudioColors.canvas,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 8,
            vertical: 6,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: StudioColors.border),
          ),
        ),
        onChanged: (value) {
          final code = value.trim().isEmpty ? 'S001' : value.trim();
          settings.updateSubjectCode(code);
        },
      ),
    );

    final folderButton = FutureBuilder<String>(
      future: settings.effectiveOutputDirectory(),
      builder: (context, snapshot) {
        final path = snapshot.data ?? 'Output';
        final folderName = path.split(Platform.pathSeparator).last;
        return Tooltip(
          message: 'Save location: $path\nTap to change',
          child: InkWell(
            onTap: () => _showOutputFolderSheet(settings),
            borderRadius: BorderRadius.circular(8),
            child: Container(
              height: 32,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: StudioColors.canvas,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: StudioColors.border),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.folder_outlined,
                    size: 14,
                    color: StudioColors.teal,
                  ),
                  const SizedBox(width: 5),
                  ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: compact ? 80 : 140),
                    child: Text(
                      folderName.isEmpty ? path : folderName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: StudioColors.textSecondary,
                        fontSize: 11.5,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );

    return Scaffold(
      resizeToAvoidBottomInset: false,
      backgroundColor: StudioColors.canvas,
      appBar: AppBar(
        toolbarHeight: 50,
        backgroundColor: StudioColors.surface,
        elevation: 0,
        shape: const Border(bottom: BorderSide(color: StudioColors.border)),
        iconTheme: const IconThemeData(color: StudioColors.textPrimary),
        title: Text(
          widget.viewerOnly ? 'Live EEG Viewer' : 'EEG Recorder',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: StudioColors.textPrimary,
            fontWeight: FontWeight.w700,
            fontSize: 15.5,
          ),
        ),
        actions: [
          ConnectionStatusBar(
            eegState: eegService.currentState,
            nirsState: null,
            deviceLabel: eegService.connectedDeviceLabel,
            onDisconnectEeg: () => eegService.disconnect(),
            compact: true,
          ),
          if (!compact && !widget.viewerOnly) ...[
            const SizedBox(width: 8),
            subjectField,
            const SizedBox(width: 6),
            folderButton,
            const SizedBox(width: 6),
            avSyncButton,
            const SizedBox(width: 6),
            recordButton,
          ],
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: Stack(
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(
                compact ? 6 : 10,
                6,
                compact ? 6 : 10,
                6,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (compact && !widget.viewerOnly)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(
                        children: [
                          subjectField,
                          const SizedBox(width: 6),
                          folderButton,
                          const Spacer(),
                          avSyncButton,
                          const SizedBox(width: 6),
                          recordButton,
                        ],
                      ),
                    ),
                  if (widget.viewerOnly)
                    Container(
                      margin: const EdgeInsets.only(bottom: 6),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 7,
                      ),
                      decoration: BoxDecoration(
                        color: StudioColors.teal.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: StudioColors.teal),
                      ),
                      child: Text(
                        isRecording
                            ? '${sessionManager.module.displayName} recording active (${sessionManager.formattedDuration}). Controls locked.'
                            : 'Viewer-only mode. Return to module to record.',
                        style: const TextStyle(
                          color: StudioColors.textPrimary,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  if (multiLsl.recentMarkers.isNotEmpty)
                    Container(
                      margin: const EdgeInsets.only(bottom: 6),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: StudioColors.violet.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: StudioColors.violet),
                      ),
                      child: Text(
                        'LSL marker: ${multiLsl.recentMarkers.last.value} (code ${multiLsl.recentMarkers.last.code})',
                        style: const TextStyle(
                          color: StudioColors.textPrimary,
                          fontSize: 11.5,
                        ),
                      ),
                    ),
                  if (_showMarkerBar) _buildMarkerStrip(sessionManager, settings),
                  Expanded(
                    child: _buildConnectedStreamTabs(
                      eegService,
                      multiLsl,
                      multiDevice,
                    ),
                  ),
                ],
              ),
            ),
            if (_eegDisconnected && isRecording) _buildConnectionLostOverlay(),
          ],
        ),
      ),
    );
  }

  Widget _buildConnectionLostOverlay() {
    return Positioned.fill(
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 5, sigmaY: 5),
        child: Container(
          color: Colors.black.withValues(alpha: 0.55),
          child: Center(
            child: Container(
              decoration: BoxDecoration(
                color: StudioColors.surface,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: StudioColors.red, width: 2),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 36, vertical: 28),
              child: const Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: StudioColors.red),
                  SizedBox(height: 18),
                  Text(
                    'EEG Amplifier Disconnected',
                    style: TextStyle(
                      color: StudioColors.textPrimary,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Recording timer paused.\nRestart your amplifier — it will reconnect automatically.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: StudioColors.textSecondary,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
