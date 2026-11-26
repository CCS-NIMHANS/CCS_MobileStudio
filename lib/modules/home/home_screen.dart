import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/eeg/acquisition_service.dart';
import '../../core/models/device_profile.dart';
import '../../core/models/module_type.dart';
import '../../core/services/alert_service.dart';
import '../../core/services/app_update_service.dart';
import '../../core/services/auto_update_monitor.dart';
import '../../core/services/file_naming_service.dart';
import '../../core/services/multi_device_acquisition_service.dart';
import '../../core/services/nirs_acquisition_service.dart';
import '../../core/services/permission_service.dart';
import '../../core/services/session_manager.dart';
import '../../core/services/settings_service.dart';
import '../../core/theme/studio_theme.dart';
import '../../core/widgets/connection_status_bar.dart';
import '../adaptive_wm/wm_screen.dart';
import '../angel/angel_screen.dart';
import '../generic_erp/generic_erp_screen.dart';
import '../heartsync/heartsync_screen.dart';
import '../hep/hep_screen.dart';
import '../hrd/hrd_screen.dart';
import '../nidra/nidra_screen.dart';
import '../resonance/resonance_screen.dart';
import '../settings/settings_screen.dart';
import '../sleepiness/sleepiness_screen.dart';
import '../standalone/standalone_screen.dart';
import '../speech_tracking/speech_tracking_screen.dart';

/// Main unified dashboard for CCS Mobile Studio, responsive across mobile,
/// tablet, and laptop/desktop displays.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  late TextEditingController _subjectCtrl;
  bool _hasUpdate = false;
  final _updates = AutoUpdateMonitor();
  Timer? _updateTimer;
  SessionManager? _updateSessions;
  bool _updateDialogOpen = false;
  bool _foreground = true;

  void _queueUpdatePrompt() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybePromptUpdate());
  }

  void _onUpdateState() {
    if (!mounted) return;
    setState(() => _hasUpdate = _updates.hasUpdate);
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybePromptUpdate());
  }

  void _maybePromptUpdate() {
    if (!mounted) return;
    final candidate = _updates.takePrompt(
      dashboardVisible: ModalRoute.of(context)?.isCurrent ?? false,
      recording: _updateSessions?.isRecording ?? true,
      foreground: _foreground,
      dialogOpen: _updateDialogOpen,
    );
    if (candidate == null) return;
    _updateDialogOpen = true;
    unawaited(
      showDialog<void>(
        context: context,
        builder: (_) => AppUpdateDialog(info: candidate),
      ).whenComplete(() => _updateDialogOpen = false),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) {
      unawaited(_updates.check());
      _maybePromptUpdate();
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _updates.addListener(_onUpdateState);
    _updateSessions = context.read<SessionManager>()
      ..addListener(_queueUpdatePrompt);
    _updateTimer = Timer.periodic(const Duration(hours: 6), (_) {
      if (_foreground) unawaited(_updates.check());
    });
    final settings = context.read<SettingsService>();
    _subjectCtrl = TextEditingController(text: settings.subjectCode);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_initializeStorageAndRecovery());
      unawaited(_updates.check());
      final code = context.read<SettingsService>().subjectCode;
      if (_subjectCtrl.text != code) {
        setState(() => _subjectCtrl.text = code);
      }
    });
  }

  Future<void> _initializeStorageAndRecovery() async {
    final permissions = context.read<PermissionService>();
    final eegService = context.read<AcquisitionService>();
    final settings = context.read<SettingsService>();
    await settings.ready;
    await permissions.requestAll();
    final autoConnectEnabled = settings.deviceProfiles.any(
      (profile) => profile.enabled && profile.autoConnect,
    );
    if (autoConnectEnabled &&
        eegService.currentState == AcquisitionState.disconnected) {
      await eegService.scan(autoConnect: true);
    }
    final recovered = await FileNamingService.recoverPendingFiles();
    if (mounted && recovered.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Recovered ${recovered.length} recording file${recovered.length == 1 ? '' : 's'} '
            'from an interrupted session.',
          ),
          duration: const Duration(seconds: 8),
        ),
      );
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _updateTimer?.cancel();
    _updateSessions?.removeListener(_queueUpdatePrompt);
    _updates.dispose();
    _subjectCtrl.dispose();
    super.dispose();
  }

  Future<void> _confirmGlobalExit(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: StudioColors.elevated,
        title: const Text(
          'Exit CCS Mobile Studio?',
          style: TextStyle(
            color: StudioColors.textPrimary,
            fontWeight: FontWeight.bold,
          ),
        ),
        content: const Text(
          'This will disconnect active hardware, cleanly stop any ongoing session, and close the application.',
          style: TextStyle(color: StudioColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: StudioColors.red),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Exit App'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      final sessionManager = context.read<SessionManager>();
      final multiDevice = context.read<MultiDeviceAcquisitionService>();
      final nirsService = context.read<NirsAcquisitionService>();

      if (sessionManager.isRecording) {
        await sessionManager.stopRecording();
      }
      await multiDevice.disconnectAll();
      nirsService.disconnect();

      exit(0);
    }
  }

  Future<void> _checkForUpdates() async {
    if (context.read<SessionManager>().isRecording) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Stop the active recording before updating the app.'),
        ),
      );
      return;
    }
    if (_updateDialogOpen) return;
    _updateDialogOpen = true;
    try {
      await showAppUpdateFlow(context);
    } finally {
      _updateDialogOpen = false;
    }
  }

  void _openSettings({int initialTabIndex = 0}) {
    Navigator.of(context)
        .push(
          MaterialPageRoute(
            builder: (_) => SettingsScreen(initialTabIndex: initialTabIndex),
          ),
        )
        .then((_) => _maybePromptUpdate());
  }

  @override
  Widget build(BuildContext context) {
    final eegService = context.watch<AcquisitionService>();
    final nirsService = context.watch<NirsAcquisitionService>();
    final multiDevice = context.watch<MultiDeviceAcquisitionService>();
    final sessionManager = context.watch<SessionManager>();
    final alertService = context.watch<AlertService>();
    final settings = context.watch<SettingsService>();
    final screenWidth = MediaQuery.sizeOf(context).width;
    final wideTitle = screenWidth >= 720;

    if (_subjectCtrl.text != settings.subjectCode) {
      _subjectCtrl.value = _subjectCtrl.value.copyWith(
        text: settings.subjectCode,
        selection: TextSelection.collapsed(offset: settings.subjectCode.length),
      );
    }

    return Scaffold(
      backgroundColor: StudioColors.canvas,
      appBar: AppBar(
        backgroundColor: StudioColors.surface,
        elevation: 0,
        toolbarHeight: 58,
        shape: const Border(bottom: BorderSide(color: StudioColors.border)),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(7),
              decoration: BoxDecoration(
                color: StudioColors.teal.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: StudioColors.teal.withValues(alpha: 0.3),
                ),
              ),
              child: const Icon(Icons.hub, color: StudioColors.teal, size: 20),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'CCS Mobile Studio',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: StudioColors.textPrimary,
                      fontWeight: FontWeight.w700,
                      fontSize: 16.5,
                      letterSpacing: -0.2,
                    ),
                  ),
                  if (wideTitle)
                    const Text(
                      'Unified Neuro-Cognitive & Electrophysiology Suite • NIMHANS / IAM',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: StudioColors.textSecondary,
                        fontSize: 11,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          if (wideTitle) ...[
            ConnectionStatusBar(
              eegState: eegService.currentState,
              nirsState: nirsService.currentState,
              deviceLabel: eegService.connectedDeviceLabel,
              onDisconnectEeg: () => eegService.disconnect(),
              onDisconnectNirs: () => nirsService.disconnect(),
              onOpenConnectDialog: () => showDeviceConnectionDialog(context),
              compact: true,
            ),
            const SizedBox(width: 6),
          ],
          IconButton(
            icon: Badge(
              isLabelVisible: _hasUpdate,
              backgroundColor: StudioColors.teal,
              child: const Icon(
                Icons.system_update_alt,
                color: StudioColors.textSecondary,
                size: 20,
              ),
            ),
            tooltip: _hasUpdate
                ? 'App update available! Tap to install'
                : 'Check for App Updates',
            onPressed: _checkForUpdates,
          ),
          IconButton(
            icon: const Icon(
              Icons.volume_up_outlined,
              color: StudioColors.textSecondary,
              size: 20,
            ),
            tooltip: 'Test Audio Beep',
            onPressed: () => alertService.playBeep(),
          ),
          IconButton(
            icon: const Icon(
              Icons.tune,
              color: StudioColors.textSecondary,
              size: 20,
            ),
            tooltip: 'Settings & Device Profiles',
            onPressed: _openSettings,
          ),
          IconButton(
            icon: const Icon(
              Icons.power_settings_new,
              color: StudioColors.red,
              size: 20,
            ),
            tooltip: 'Exit App & Disconnect Hardware',
            onPressed: () => _confirmGlobalExit(context),
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final isDesktop = constraints.maxWidth >= 900;
            if (isDesktop) {
              return Padding(
                padding: const EdgeInsets.all(18),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: Column(
                        children: [
                          if (sessionManager.isRecording) ...[
                            _buildRecordingBanner(sessionManager),
                            const SizedBox(height: 14),
                          ],
                          Expanded(
                            child: _buildStudySequencePanel(
                              context,
                              settings,
                              columns: constraints.maxWidth >= 1220 ? 3 : 2,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 16),
                    SizedBox(
                      width: 318,
                      child: _buildSessionSidebar(
                        context,
                        settings,
                        eegService,
                        nirsService,
                        multiDevice,
                        alertService,
                      ),
                    ),
                  ],
                ),
              );
            }

            // Mobile / narrow tablet layout
            final compact = constraints.maxWidth < 600;
            return Padding(
              padding: EdgeInsets.all(compact ? 10 : 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (!wideTitle) ...[
                    ConnectionStatusBar(
                      eegState: eegService.currentState,
                      nirsState: nirsService.currentState,
                      deviceLabel: eegService.connectedDeviceLabel,
                      onDisconnectEeg: () => eegService.disconnect(),
                      onDisconnectNirs: () => nirsService.disconnect(),
                      onOpenConnectDialog: () =>
                          showDeviceConnectionDialog(context),
                    ),
                    const SizedBox(height: 10),
                  ],
                  _buildCompactSessionStrip(context, settings, compact),
                  const SizedBox(height: 10),
                  if (sessionManager.isRecording) ...[
                    _buildRecordingBanner(sessionManager),
                    const SizedBox(height: 10),
                  ],
                  Expanded(
                    child: _buildStudySequencePanel(
                      context,
                      settings,
                      columns: constraints.maxWidth >= 640 ? 2 : 1,
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildRecordingBanner(SessionManager sessionManager) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: StudioColors.red.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: StudioColors.red, width: 1.3),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.fiber_manual_record,
            color: StudioColors.red,
            size: 18,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Recording active (${sessionManager.activeModule?.displayName ?? "Module"}) • Segment #${sessionManager.currentSegment}',
              style: const TextStyle(
                color: StudioColors.textPrimary,
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
          ),
          FilledButton(
            onPressed: () => sessionManager.stopRecording(),
            style: FilledButton.styleFrom(
              backgroundColor: StudioColors.red,
              foregroundColor: Colors.white,
              visualDensity: VisualDensity.compact,
            ),
            child: const Text('STOP & SAVE'),
          ),
        ],
      ),
    );
  }

  Widget _buildSessionSidebar(
    BuildContext context,
    SettingsService settings,
    AcquisitionService eegService,
    NirsAcquisitionService nirsService,
    MultiDeviceAcquisitionService multiDevice,
    AlertService alertService,
  ) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Session Setup Card
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: StudioColors.card,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: StudioColors.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(
                      Icons.badge_outlined,
                      color: StudioColors.teal,
                      size: 18,
                    ),
                    SizedBox(width: 8),
                    Text(
                      'SESSION SETUP',
                      style: TextStyle(
                        color: StudioColors.textSecondary,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.8,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                const Text(
                  'Subject ID / Session Tag',
                  style: TextStyle(
                    color: StudioColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: _subjectCtrl,
                  style: const TextStyle(
                    color: StudioColors.textPrimary,
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                  ),
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: 'S001',
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 11,
                    ),
                  ),
                  onChanged: (val) {
                    final code = val.trim().isEmpty ? 'S001' : val.trim();
                    settings.updateSubjectCode(code);
                  },
                ),
                const SizedBox(height: 14),
                const Text(
                  'Output Save Location',
                  style: TextStyle(
                    color: StudioColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 6),
                FutureBuilder<String>(
                  future: settings.effectiveOutputDirectory(),
                  builder: (context, snapshot) {
                    final path = snapshot.data ?? 'Resolving…';
                    return Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: StudioColors.canvas,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: StudioColors.border),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            path,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: StudioColors.textPrimary,
                              fontFamily: 'monospace',
                              fontSize: 11,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: OutlinedButton.icon(
                                  onPressed: () =>
                                      settings.chooseOutputDirectory(),
                                  icon: const Icon(
                                    Icons.folder_outlined,
                                    size: 15,
                                  ),
                                  label: const Text('Change'),
                                  style: OutlinedButton.styleFrom(
                                    visualDensity: VisualDensity.compact,
                                    foregroundColor: StudioColors.teal,
                                    side: const BorderSide(
                                      color: StudioColors.border,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: OutlinedButton.icon(
                                  onPressed: () =>
                                      settings.openOutputDirectory(),
                                  icon: const Icon(Icons.open_in_new, size: 15),
                                  label: const Text('Open'),
                                  style: OutlinedButton.styleFrom(
                                    visualDensity: VisualDensity.compact,
                                    foregroundColor: StudioColors.textSecondary,
                                    side: const BorderSide(
                                      color: StudioColors.border,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),

          // Hardware & Profile Card
          Container(
            padding: const EdgeInsets.all(16),
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
                    const Icon(
                      Icons.sensors,
                      color: StudioColors.sky,
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'HARDWARE & PROFILES',
                        style: TextStyle(
                          color: StudioColors.textSecondary,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.8,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: _openSettings,
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        foregroundColor: StudioColors.teal,
                      ),
                      child: const Text('Manage'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                ConnectionStatusBar(
                  eegState: eegService.currentState,
                  nirsState: nirsService.currentState,
                  deviceLabel: eegService.connectedDeviceLabel,
                  onDisconnectEeg: () => eegService.disconnect(),
                  onDisconnectNirs: () => nirsService.disconnect(),
                  onOpenConnectDialog: () =>
                      showDeviceConnectionDialog(context),
                ),
                if (eegService.isStreamReady) ...[
                  const SizedBox(height: 12),
                  _buildQuickProfileSwitcher(
                    settings,
                    eegService,
                    multiDevice,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 14),

          // Utilities Card
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: StudioColors.card,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: StudioColors.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'SYSTEM TOOLS',
                  style: TextStyle(
                    color: StudioColors.textSecondary,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ActionChip(
                      avatar: const Icon(
                        Icons.build_circle_outlined,
                        size: 16,
                        color: StudioColors.blue,
                      ),
                      label: const Text('Diagnostics'),
                      backgroundColor: StudioColors.surface,
                      side: const BorderSide(color: StudioColors.border),
                      onPressed: () => _showDiagnosticsModal(context),
                    ),
                    ActionChip(
                      avatar: const Icon(
                        Icons.volume_up_outlined,
                        size: 16,
                        color: StudioColors.teal,
                      ),
                      label: const Text('Audio Beep'),
                      backgroundColor: StudioColors.surface,
                      side: const BorderSide(color: StudioColors.border),
                      onPressed: () => alertService.playBeep(),
                    ),
                    ActionChip(
                      avatar: const Icon(
                        Icons.tune,
                        size: 16,
                        color: StudioColors.amber,
                      ),
                      label: const Text('All Settings'),
                      backgroundColor: StudioColors.surface,
                      side: const BorderSide(color: StudioColors.border),
                      onPressed: _openSettings,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQuickProfileSwitcher(
    SettingsService settings,
    AcquisitionService eegService,
    MultiDeviceAcquisitionService multiDevice,
  ) {
    final profiles = settings.deviceProfiles
        .where((p) => p.enabled && p.transport != ConnectionTransport.lsl)
        .toList(growable: false);
    if (profiles.isEmpty) return const SizedBox.shrink();
    final currentId = eegService.connectedDeviceProfile?.id;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Active Montage / Channel Profile',
          style: TextStyle(color: StudioColors.textSecondary, fontSize: 11.5),
        ),
        const SizedBox(height: 6),
        DropdownButtonFormField<String>(
          initialValue: profiles.any((p) => p.id == currentId)
              ? currentId
              : null,
          isDense: true,
          dropdownColor: StudioColors.elevated,
          style: const TextStyle(color: StudioColors.textPrimary, fontSize: 12.5),
          decoration: const InputDecoration(
            contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          ),
          hint: const Text('Select profile'),
          items: profiles
              .map(
                (p) => DropdownMenuItem(
                  value: p.id,
                  child: Text(
                    p.projectTag.isNotEmpty
                        ? '${p.name} (${p.projectTag})'
                        : p.name,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              )
              .toList(),
          onChanged: (id) {
            if (id == null) return;
            final profile = settings.profileById(id);
            if (profile != null) multiDevice.switchPrimaryProfile(profile);
          },
        ),
      ],
    );
  }

  Widget _buildCompactSessionStrip(
    BuildContext context,
    SettingsService settings,
    bool compact,
  ) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: compact ? 10 : 14, vertical: 8),
      decoration: BoxDecoration(
        color: StudioColors.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: StudioColors.border),
      ),
      child: Row(
        children: [
          const Icon(Icons.badge_outlined, color: StudioColors.teal, size: 18),
          const SizedBox(width: 8),
          SizedBox(
            width: compact ? 110 : 160,
            child: TextField(
              controller: _subjectCtrl,
              style: const TextStyle(
                color: StudioColors.textPrimary,
                fontWeight: FontWeight.w700,
                fontSize: 14,
              ),
              decoration: const InputDecoration(
                isDense: true,
                labelText: 'Subject ID',
                hintText: 'S001',
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
              ),
              onChanged: (val) {
                final code = val.trim().isEmpty ? 'S001' : val.trim();
                settings.updateSubjectCode(code);
              },
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: FutureBuilder<String>(
              future: settings.effectiveOutputDirectory(),
              builder: (context, snapshot) {
                final path = snapshot.data ?? 'Output folder';
                final folderName = path.split(Platform.pathSeparator).last;
                return OutlinedButton.icon(
                  onPressed: () => settings.chooseOutputDirectory(),
                  icon: const Icon(Icons.folder_outlined, size: 16),
                  label: Text(
                    folderName.isEmpty ? path : folderName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: StudioColors.textSecondary,
                    side: const BorderSide(color: StudioColors.border),
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 10,
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            tooltip: 'Diagnostics',
            visualDensity: VisualDensity.compact,
            onPressed: () => _showDiagnosticsModal(context),
            icon: const Icon(
              Icons.build_circle_outlined,
              color: StudioColors.blue,
              size: 20,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStudySequencePanel(
    BuildContext context,
    SettingsService settings, {
    required int columns,
  }) {
    final steps = settings.studySequence.toList(growable: false);
    if (steps.isEmpty) return const SizedBox.shrink();
    final compact = MediaQuery.sizeOf(context).width < 600;

    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(compact ? 12 : 16),
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
              const Icon(Icons.route, color: StudioColors.teal, size: 19),
              const SizedBox(width: 8),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Study Run Sequence',
                      style: TextStyle(
                        color: StudioColors.textPrimary,
                        fontWeight: FontWeight.w700,
                        fontSize: 16.5,
                      ),
                    ),
                    Text(
                      'Select a module to begin recording or run an assessment.',
                      style: TextStyle(
                        color: StudioColors.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              TextButton.icon(
                onPressed: () => _openSettings(initialTabIndex: 2),
                icon: const Icon(Icons.edit_outlined, size: 15),
                label: const Text('Edit Flow'),
                style: TextButton.styleFrom(
                  foregroundColor: StudioColors.teal,
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: columns <= 1
                ? ListView.separated(
                    itemCount: steps.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (context, index) => _buildSequenceStep(
                      context,
                      steps[index],
                      index,
                      compact: true,
                    ),
                  )
                : GridView.builder(
                    itemCount: steps.length,
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: columns,
                      crossAxisSpacing: 12,
                      mainAxisSpacing: 12,
                      mainAxisExtent: 108,
                    ),
                    itemBuilder: (context, index) => _buildSequenceStep(
                      context,
                      steps[index],
                      index,
                      compact: false,
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildSequenceStep(
    BuildContext context,
    ModuleType module,
    int index, {
    required bool compact,
  }) {
    final color = switch (module) {
      ModuleType.standalone => StudioColors.teal,
      ModuleType.nidra => const Color(0xFF818CF8),
      ModuleType.angel => StudioColors.amber,
      ModuleType.erp => const Color(0xFF22D3EE),
      ModuleType.wm => const Color(0xFFEC4899),
      ModuleType.heartsync => const Color(0xFFF43F5E),
      ModuleType.hrd => const Color(0xFFFB7185),
      ModuleType.hep => const Color(0xFF22D3EE),
      ModuleType.resonance => const Color(0xFF2DD4BF),
      ModuleType.sleepiness => StudioColors.emerald,
      ModuleType.speechTracking => const Color(0xFF38BDF8),
    };
    final icon = switch (module) {
      ModuleType.standalone => Icons.monitor_heart,
      ModuleType.nidra => Icons.bedtime,
      ModuleType.angel => Icons.psychology,
      ModuleType.erp => Icons.multiline_chart,
      ModuleType.wm => Icons.memory,
      ModuleType.heartsync => Icons.favorite,
      ModuleType.hrd => Icons.favorite_border,
      ModuleType.hep => Icons.monitor_heart_outlined,
      ModuleType.resonance => Icons.air,
      ModuleType.sleepiness => Icons.assignment_turned_in,
      ModuleType.speechTracking => Icons.headphones,
    };
    final subtitle = switch (module) {
      ModuleType.standalone =>
        'Multi-channel waveform viewer, PSD, impedance & EDF+ recorder',
      ModuleType.nidra => 'Sleep staging and closed-loop auditory stimulation',
      ModuleType.angel => 'Cognitive ERP battery',
      ModuleType.erp =>
        'ERP CORE (N170, MMN, N2pc, N400, P3b, ERN/LRP) & classic paradigms',
      ModuleType.wm => 'Adaptive working memory task',
      ModuleType.heartsync => 'Heartbeat-locked cardiac oddball task',
      ModuleType.hrd => 'Bayesian Psi interoceptive heart-rate task',
      ModuleType.hep => '5-minute live EEG + ECG heartbeat-locked analysis',
      ModuleType.resonance =>
        'Paced breathing • quick sweep or adaptive Bayesian assessment',
      ModuleType.sleepiness => 'Stanford Sleepiness Scale assessment & logs',
      ModuleType.speechTracking =>
        'Dichotic stereo audio & block-wise TRF neural speech decoding',
    };

    return Material(
      color: StudioColors.surface,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: () => _launchModule(context, module),
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 12 : 14,
            vertical: compact ? 12 : 12,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: color.withValues(alpha: 0.35)),
          ),
          child: Row(
            children: [
              Container(
                width: 4,
                height: compact ? 44 : 56,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              const SizedBox(width: 12),
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(10),
                ),
                alignment: Alignment.center,
                child: Icon(icon, color: color, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 1.5,
                          ),
                          decoration: BoxDecoration(
                            color: color.withValues(alpha: 0.16),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            'STEP ${index + 1}',
                            style: TextStyle(
                              color: color,
                              fontSize: 9.5,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            module.displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: StudioColors.textPrimary,
                              fontWeight: FontWeight.w700,
                              fontSize: compact ? 15.5 : 16,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 5),
                    Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: StudioColors.textSecondary,
                        fontSize: 12,
                        height: 1.25,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                Icons.chevron_right_rounded,
                color: color.withValues(alpha: 0.85),
                size: 22,
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _launchModule(BuildContext context, ModuleType module) {
    final page = switch (module) {
      ModuleType.standalone => const StandaloneScreen(),
      ModuleType.nidra => const NidraScreen(),
      ModuleType.angel => const AngelScreen(),
      ModuleType.erp => const GenericErpScreen(),
      ModuleType.wm => const WmScreen(),
      ModuleType.heartsync => const HeartSyncScreen(),
      ModuleType.hrd => const HrdScreen(),
      ModuleType.hep => const HepScreen(),
      ModuleType.resonance => const ResonanceScreen(),
      ModuleType.sleepiness => const SleepinessScreen(),
      ModuleType.speechTracking => const SpeechTrackingScreen(),
    };
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => page))
        .then((_) => _maybePromptUpdate());
  }

  void _showDiagnosticsModal(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: StudioColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      isScrollControlled: true,
      builder: (_) => _DiagnosticsDrawer(),
    );
  }
}

class _DiagnosticsDrawer extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final alertService = context.watch<AlertService>();
    final settings = context.watch<SettingsService>();

    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Module Diagnostics & Troubleshooting',
                style: TextStyle(
                  color: StudioColors.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, color: StudioColors.textSecondary),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Text(
            'Verify hardware audio output, recording storage paths, and LSL multicast status without restarting.',
            style: TextStyle(color: StudioColors.textSecondary, fontSize: 13),
          ),
          const SizedBox(height: 16),
          ListTile(
            leading: const Icon(Icons.volume_up, color: StudioColors.blue),
            title: const Text(
              'Audio Latency & Beep Test',
              style: TextStyle(color: StudioColors.textPrimary),
            ),
            subtitle: const Text(
              'Test auditory closed-loop stimulation speaker output',
              style: TextStyle(color: StudioColors.textSecondary, fontSize: 12),
            ),
            trailing: FilledButton(
              style: FilledButton.styleFrom(backgroundColor: StudioColors.blue),
              onPressed: () => alertService.playBeep(),
              child: const Text('Play Beep'),
            ),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.folder_special, color: StudioColors.emerald),
            title: const Text(
              'Storage & Recording Exporter',
              style: TextStyle(color: StudioColors.textPrimary),
            ),
            subtitle: FutureBuilder<String>(
              future: settings.effectiveOutputDirectory(),
              builder: (context, snapshot) => Text(
                'Output folder: ${snapshot.data ?? "Resolving…"}',
                style: const TextStyle(color: StudioColors.textSecondary, fontSize: 12),
              ),
            ),
            trailing: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: StudioColors.emerald,
                foregroundColor: Colors.white,
              ),
              onPressed: () async {
                final opened = await settings.openOutputDirectory();
                if (!context.mounted || opened) return;
                final path = await settings.effectiveOutputDirectory();
                if (!context.mounted) return;
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text('Output folder: $path')));
              },
              child: const Text('Open Folder'),
            ),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.network_check, color: StudioColors.amber),
            title: const Text(
              'LSL Multicast Lock Status',
              style: TextStyle(color: StudioColors.textPrimary),
            ),
            subtitle: const Text(
              'Required for WiFi LSL stream discovery on Android 10+',
              style: TextStyle(color: StudioColors.textSecondary, fontSize: 12),
            ),
            trailing: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: StudioColors.emerald.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                'ACTIVE',
                style: TextStyle(
                  color: StudioColors.emerald,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}
