import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'core/eeg/acquisition_service.dart';
import 'core/eeg/edf_recorder.dart';
import 'core/eeg/lsl_eeg_acquisition_service.dart';
import 'core/eeg/native_core.dart';
import 'core/services/ble_coordinator.dart';
import 'core/services/settings_service.dart';
import 'core/services/channel_config_service.dart';
import 'core/services/permission_service.dart';
import 'core/services/session_manager.dart';
import 'core/services/alert_service.dart';
import 'core/services/av_sync_service.dart';
import 'core/services/nirs_acquisition_service.dart';
import 'core/services/multi_stream_lsl_service.dart';
import 'core/services/multi_device_acquisition_service.dart';
import 'core/eeg/nirs_edf_recorder.dart';
import 'core/theme/studio_theme.dart';
import 'modules/home/home_screen.dart';
import 'modules/standalone/standalone_screen.dart';
import 'modules/nidra/nidra_screen.dart';
import 'modules/angel/angel_screen.dart';
import 'modules/adaptive_wm/wm_screen.dart';
import 'modules/heartsync/heartsync_screen.dart';
import 'modules/hrd/hrd_screen.dart';
import 'modules/hep/hep_screen.dart';
import 'modules/speech_tracking/speech_tracking_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const CcsMobileStudioApp());
}

class CcsMobileStudioApp extends StatelessWidget {
  const CcsMobileStudioApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        // ── Core singletons ──────────────────────────────────────────────
        Provider<NativeCore>(create: (_) => NativeCore.instance),
        ChangeNotifierProvider<SettingsService>(
          create: (_) => SettingsService()..load(),
        ),
        Provider<PermissionService>(create: (_) => PermissionService()),
        Provider<AlertService>(create: (_) => AlertService()),

        // ── EEG Acquisition (shared singleton) ───────────────────────────
        ChangeNotifierProxyProvider2<
          AlertService,
          SettingsService,
          AcquisitionService
        >(
          create: (_) => AcquisitionService(),
          update: (_, alert, settings, prev) => (prev ?? AcquisitionService())
            ..updateAlertService(alert)
            ..updateSettings(settings),
        ),
        ChangeNotifierProxyProvider2<
          SettingsService,
          AcquisitionService,
          ChannelConfigService
        >(
          create: (_) => ChannelConfigService(),
          update: (_, settings, acquisition, previous) =>
              (previous ?? ChannelConfigService())
                ..updateDependencies(settings, acquisition),
        ),
        ChangeNotifierProvider<LslEegAcquisitionService>(
          create: (_) => LslEegAcquisitionService(),
        ),
        ChangeNotifierProvider<NirsAcquisitionService>(
          create: (_) => NirsAcquisitionService(),
        ),
        ChangeNotifierProvider<MultiStreamLslService>(
          create: (_) => MultiStreamLslService(),
        ),
        ChangeNotifierProxyProvider3<
          AcquisitionService,
          SettingsService,
          AlertService,
          MultiDeviceAcquisitionService
        >(
          create: (_) => MultiDeviceAcquisitionService(),
          update: (_, acq, settings, alerts, previous) =>
              (previous ?? MultiDeviceAcquisitionService())
                ..update(acq, settings, alerts),
        ),

        // ── Recorders ────────────────────────────────────────────────────
        ChangeNotifierProvider<EdfRecorder>(create: (_) => EdfRecorder()),
        ChangeNotifierProvider<NirsEdfRecorder>(
          create: (_) => NirsEdfRecorder(),
        ),
        ChangeNotifierProvider<AvSyncService>(create: (_) => AvSyncService()),

        // ── BLE Coordinator (exclusive streaming access) ─────────────────
        ChangeNotifierProxyProvider<AcquisitionService, BleCoordinator>(
          create: (_) => BleCoordinator(),
          update: (_, acq, prev) =>
              (prev ?? BleCoordinator())..updateAcquisition(acq),
        ),

        // ── Session Manager (EDF lifecycle, segment tracking) ─────────────
        ChangeNotifierProxyProvider6<
          AcquisitionService,
          EdfRecorder,
          SettingsService,
          MultiStreamLslService,
          MultiDeviceAcquisitionService,
          AvSyncService,
          SessionManager
        >(
          create: (_) => SessionManager(),
          update: (_, acq, rec, settings, multiLsl, multiDevice, avSync, prev) =>
              (prev ?? SessionManager())
                ..update(acq, rec, settings, multiLsl, multiDevice)
                ..attachAvSync(avSync),
        ),
      ],
      child: Consumer<SettingsService>(
        builder: (context, settings, _) => MaterialApp(
          title: 'CCS Mobile Studio',
          debugShowCheckedModeBanner: false,
          builder: (context, child) {
            final media = MediaQuery.of(context);
            return MediaQuery(
              data: media.copyWith(
                textScaler: TextScaler.linear(settings.textScaleFactor),
              ),
              child: child ?? const SizedBox.shrink(),
            );
          },
          theme: StudioTheme.light(),
          home: const HomeScreen(),
          routes: {
            '/standalone': (_) => const StandaloneScreen(),
            '/nidra': (_) => const NidraScreen(),
            '/angel': (_) => const AngelScreen(),
            '/wm': (_) => const WmScreen(),
            '/heartsync': (_) => const HeartSyncScreen(),
            '/hrd': (_) => const HrdScreen(),
            '/hep': (_) => const HepScreen(),
            '/speech-tracking': (_) => const SpeechTrackingScreen(),
          },
        ),
      ),
    );
  }
}
