import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../eeg/acquisition_service.dart';
import '../models/device_profile.dart';
import '../services/multi_device_acquisition_service.dart';
import '../services/multi_stream_lsl_service.dart';
import '../services/nirs_acquisition_service.dart';
import '../services/session_manager.dart';
import '../services/settings_service.dart';
import '../theme/studio_theme.dart';

/// Unified connection status bar showing device connection state, active
/// stream summary, and quick connect/manage/disconnect controls.
class ConnectionStatusBar extends StatelessWidget {
  const ConnectionStatusBar({
    super.key,
    required this.eegState,
    this.nirsState = NirsAcquisitionState.disconnected,
    this.deviceLabel,
    this.onDisconnectEeg,
    this.onDisconnectNirs,
    this.onOpenConnectDialog,
    this.compact = false,
  });

  final AcquisitionState eegState;
  final NirsAcquisitionState? nirsState;
  final String? deviceLabel;
  final VoidCallback? onDisconnectEeg;
  final VoidCallback? onDisconnectNirs;
  final VoidCallback? onOpenConnectDialog;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final eegService = context.watch<AcquisitionService>();
    final multiLsl = context.watch<MultiStreamLslService>();
    final multiDevice = context.watch<MultiDeviceAcquisitionService>();
    final secondaryConnected = multiDevice.readySecondaryServices;
    final eegConnected = eegService.isStreamReady;
    final eegConnecting =
        eegState == AcquisitionState.connecting ||
        eegState == AcquisitionState.scanning;
    final nirsStateVal = nirsState ?? NirsAcquisitionState.disconnected;
    final nirsConnected = nirsStateVal == NirsAcquisitionState.connected;
    final nirsConnecting = nirsStateVal == NirsAcquisitionState.resolving;

    final anythingConnected =
        eegConnected ||
        secondaryConnected.isNotEmpty ||
        nirsConnected ||
        multiLsl.isConnected;
    final anythingConnecting =
        eegConnecting ||
        multiDevice.isBusy ||
        nirsConnecting ||
        multiLsl.state == AcquisitionState.connecting;

    bool rateIsDegraded(AcquisitionService service) {
      final received = service.deliveredSampleRate;
      return received != null && received < service.sampleRate * 0.8;
    }

    final rateDegraded =
        (eegConnected && rateIsDegraded(eegService)) ||
        secondaryConnected.any(rateIsDegraded);

    final Color statusColor;
    final String statusText;
    final IconData statusIcon;

    if (anythingConnected) {
      statusColor = rateDegraded ? StudioColors.amber : StudioColors.emerald;
      statusIcon = rateDegraded ? Icons.warning_amber_rounded : Icons.sensors;
      final parts = <String>[];
      if (eegConnected) {
        final profileName = eegService.connectedDeviceProfile?.name;
        final label = deviceLabel ?? 'EEG';
        parts.add(
          profileName != null && profileName != label
              ? '$label ($profileName)'
              : label,
        );
      }
      if (secondaryConnected.isNotEmpty) {
        parts.add('+${secondaryConnected.length} device(s)');
      }
      if (nirsConnected) parts.add('fNIRS');
      if (multiLsl.isConnected) {
        parts.add('${multiLsl.connectedStreams.length} LSL');
      }
      statusText = parts.join(' • ');
    } else if (anythingConnecting) {
      statusColor = StudioColors.amber;
      statusIcon = Icons.bluetooth_searching;
      statusText = nirsConnecting && !eegConnecting && !multiDevice.isBusy
          ? 'Resolving fNIRS…'
          : (eegState == AcquisitionState.scanning || multiDevice.isScanning)
          ? 'Scanning for amplifiers…'
          : 'Connecting…';
    } else {
      statusColor = StudioColors.red;
      statusIcon = Icons.link_off;
      statusText = 'No hardware connected';
    }

    final openDialog =
        onOpenConnectDialog ?? () => showDeviceConnectionDialog(context);

    if (compact) {
      return InkWell(
        onTap: openDialog,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: statusColor.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: statusColor.withValues(alpha: 0.45)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(statusIcon, color: statusColor, size: 15),
              const SizedBox(width: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 180),
                child: Text(
                  statusText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: statusColor,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              Icon(Icons.expand_more, color: statusColor, size: 15),
            ],
          ),
        ),
      );
    }

    final deliveredRate = eegService.deliveredSampleRate;
    final subtitle = anythingConnected
        ? (rateDegraded
              ? 'Stream rate degraded (${deliveredRate?.toStringAsFixed(0) ?? '?'} / ${eegService.sampleRate.toStringAsFixed(0)} Hz)'
              : deliveredRate != null
              ? 'Live • ${deliveredRate.toStringAsFixed(0)} Hz • ${eegService.channelCount} ch'
              : 'Streaming live data • ${eegService.channelCount} ch')
        : null;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: StudioColors.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: statusColor.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(
              color: statusColor.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(statusIcon, color: statusColor, size: 18),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  statusText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: StudioColors.textPrimary,
                    fontWeight: FontWeight.w600,
                    fontSize: 13.5,
                  ),
                ),
                if (subtitle != null)
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: rateDegraded
                          ? StudioColors.amber
                          : StudioColors.textSecondary,
                      fontSize: 11.5,
                    ),
                  ),
              ],
            ),
          ),
          if (anythingConnected) ...[
            TextButton(
              onPressed: openDialog,
              style: TextButton.styleFrom(
                foregroundColor: StudioColors.sky,
                visualDensity: VisualDensity.compact,
              ),
              child: const Text('Devices'),
            ),
            IconButton(
              tooltip: 'Disconnect all',
              visualDensity: VisualDensity.compact,
              icon: const Icon(
                Icons.power_settings_new,
                color: Color(0xFFFCA5A5),
                size: 19,
              ),
              onPressed: () async {
                await multiDevice.disconnectAll();
                onDisconnectNirs?.call();
                await multiLsl.disconnect();
              },
            ),
          ] else
            FilledButton.icon(
              onPressed: anythingConnecting
                  ? () => multiDevice.disconnectAll()
                  : openDialog,
              icon: Icon(
                anythingConnecting ? Icons.close : Icons.bluetooth_connected,
                size: 16,
              ),
              label: Text(anythingConnecting ? 'Cancel' : 'Connect'),
              style: FilledButton.styleFrom(
                backgroundColor: StudioColors.blue,
                foregroundColor: Colors.white,
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

void showDeviceConnectionDialog(BuildContext context) {
  showDialog<void>(
    context: context,
    builder: (_) => const DeviceConnectionDialog(),
  );
}

enum _ConnectTab { bluetooth, lsl, simulate }

class DeviceConnectionDialog extends StatefulWidget {
  const DeviceConnectionDialog({super.key});

  @override
  State<DeviceConnectionDialog> createState() => _DeviceConnectionDialogState();
}

class _DeviceConnectionDialogState extends State<DeviceConnectionDialog> {
  _ConnectTab _tab = _ConnectTab.bluetooth;
  bool _includeAllBle = false;
  final Map<String, String> _selectedProfileIds = {};
  MultiDeviceAcquisitionService? _multiDevice;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _multiDevice = context.read<MultiDeviceAcquisitionService>();
      if (!_multiDevice!.isScanning && !_multiDevice!.isBusy) {
        unawaited(_multiDevice!.scan(includeAllBle: _includeAllBle));
      }
    });
  }

  @override
  void dispose() {
    final md = _multiDevice;
    if (md != null && md.isScanning) {
      unawaited(md.stopScan());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final eegService = context.watch<AcquisitionService>();
    final multiLsl = context.watch<MultiStreamLslService>();
    final multiDevice = context.watch<MultiDeviceAcquisitionService>();
    final settings = context.watch<SettingsService>();
    final width = math.min(540.0, MediaQuery.sizeOf(context).width - 28);

    return Dialog(
      backgroundColor: StudioColors.elevated,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: StudioColors.border),
      ),
      child: SizedBox(
        width: width,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.settings_input_antenna,
                    color: StudioColors.teal,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Connect Devices',
                      style: TextStyle(
                        color: StudioColors.textPrimary,
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(
                      Icons.close,
                      color: StudioColors.textSecondary,
                      size: 20,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              SegmentedButton<_ConnectTab>(
                showSelectedIcon: false,
                style: ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  backgroundColor: WidgetStateProperty.resolveWith(
                    (states) => states.contains(WidgetState.selected)
                        ? StudioColors.teal.withValues(alpha: 0.22)
                        : StudioColors.card,
                  ),
                  foregroundColor: WidgetStateProperty.resolveWith(
                    (states) => states.contains(WidgetState.selected)
                        ? StudioColors.teal
                        : StudioColors.textSecondary,
                  ),
                ),
                segments: const [
                  ButtonSegment(
                    value: _ConnectTab.bluetooth,
                    icon: Icon(Icons.bluetooth, size: 16),
                    label: Text('Bluetooth'),
                  ),
                  ButtonSegment(
                    value: _ConnectTab.lsl,
                    icon: Icon(Icons.wifi, size: 16),
                    label: Text('WiFi / LSL'),
                  ),
                  ButtonSegment(
                    value: _ConnectTab.simulate,
                    icon: Icon(Icons.waves, size: 16),
                    label: Text('Simulate'),
                  ),
                ],
                selected: {_tab},
                onSelectionChanged: (sel) => setState(() => _tab = sel.first),
              ),
              const SizedBox(height: 14),
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: math.min(
                    440.0,
                    MediaQuery.sizeOf(context).height * 0.62,
                  ),
                ),
                child: SingleChildScrollView(
                  child: switch (_tab) {
                    _ConnectTab.bluetooth => _buildBluetoothTab(
                      context,
                      eegService,
                      multiDevice,
                      settings,
                    ),
                    _ConnectTab.lsl => _buildLslTab(
                      context,
                      multiLsl,
                      settings,
                    ),
                    _ConnectTab.simulate => _buildSimulateTab(
                      context,
                      eegService,
                    ),
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBluetoothTab(
    BuildContext context,
    AcquisitionService eegService,
    MultiDeviceAcquisitionService multiDevice,
    SettingsService settings,
  ) {
    final isScanning = multiDevice.isScanning;
    final scanError = multiDevice.lastScanError;
    final discovered = multiDevice.discoveredDevices
        .where((d) => d.kind != DeviceKind.synthetic)
        .toList(growable: false);

    // Unified list: connected devices first, then available (not yet connected)
    final connectedIds = <String>{
      if (eegService.connectedDeviceId != null) eegService.connectedDeviceId!,
      ...multiDevice.secondaryDevices.keys,
    };
    final available = discovered
        .where((d) => !connectedIds.contains(d.id))
        .toList(growable: false);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: StudioColors.card,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: StudioColors.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(
                    isScanning
                        ? Icons.bluetooth_searching
                        : Icons.bluetooth_audio,
                    color: isScanning ? StudioColors.sky : StudioColors.teal,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          isScanning
                              ? 'Scanning nearby amplifiers…'
                              : 'xAMP-L10 / EpiDome / ORBIT',
                          style: const TextStyle(
                            color: StudioColors.textPrimary,
                            fontWeight: FontWeight.w600,
                            fontSize: 13.5,
                          ),
                        ),
                        Text(
                          available.isEmpty && connectedIds.isEmpty
                              ? 'Ensure the amplifier is powered on and nearby'
                              : '${connectedIds.length} connected • ${available.length} found',
                          style: const TextStyle(
                            color: StudioColors.textSecondary,
                            fontSize: 11.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: isScanning
                          ? StudioColors.elevated
                          : StudioColors.teal,
                      foregroundColor: isScanning
                          ? StudioColors.textPrimary
                          : Colors.black,
                      visualDensity: VisualDensity.compact,
                    ),
                    onPressed: () {
                      if (isScanning) {
                        unawaited(multiDevice.stopScan());
                      } else {
                        unawaited(
                          multiDevice.scan(includeAllBle: _includeAllBle),
                        );
                      }
                    },
                    icon: Icon(
                      isScanning ? Icons.stop : Icons.refresh,
                      size: 16,
                    ),
                    label: Text(isScanning ? 'Stop' : 'Scan'),
                  ),
                ],
              ),
              if (isScanning) ...[
                const SizedBox(height: 8),
                const LinearProgressIndicator(
                  minHeight: 2.5,
                  color: StudioColors.teal,
                  backgroundColor: StudioColors.border,
                ),
              ],
              const SizedBox(height: 6),
              Row(
                children: [
                  SizedBox(
                    height: 24,
                    child: Checkbox(
                      value: _includeAllBle,
                      visualDensity: VisualDensity.compact,
                      activeColor: StudioColors.teal,
                      onChanged: (v) {
                        setState(() => _includeAllBle = v ?? false);
                        unawaited(
                          multiDevice.scan(includeAllBle: _includeAllBle),
                        );
                      },
                    ),
                  ),
                  const Expanded(
                    child: Text(
                      'Include unmatched BLE devices',
                      style: TextStyle(
                        color: StudioColors.textSecondary,
                        fontSize: 11.5,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        if (scanError != null && scanError.isNotEmpty) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: StudioColors.red.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: StudioColors.red.withValues(alpha: 0.45),
              ),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.error_outline,
                  color: StudioColors.red,
                  size: 18,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    scanError,
                    style: const TextStyle(
                      color: StudioColors.textPrimary,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
        if (eegService.connectedDeviceId != null ||
            multiDevice.secondaryDevices.isNotEmpty) ...[
          const SizedBox(height: 12),
          const Text(
            'ACTIVE CONNECTIONS',
            style: TextStyle(
              color: StudioColors.textMuted,
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(height: 6),
          if (eegService.connectedDeviceId != null)
            _buildConnectedTile(
              context,
              service: eegService,
              settings: settings,
              onSelectProfile: multiDevice.switchPrimaryProfile,
              onDisconnect: eegService.disconnect,
            ),
          ...multiDevice.secondaryDevices.entries.map(
            (entry) => _buildConnectedTile(
              context,
              service: entry.value,
              settings: settings,
              onSelectProfile: (p) =>
                  multiDevice.switchDeviceProfile(entry.key, p),
              onDisconnect: () => multiDevice.disconnect(entry.key),
            ),
          ),
        ],
        const SizedBox(height: 12),
        const Text(
          'DISCOVERED DEVICES',
          style: TextStyle(
            color: StudioColors.textMuted,
            fontSize: 10.5,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
          ),
        ),
        const SizedBox(height: 6),
        if (available.isEmpty)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 12),
            decoration: BoxDecoration(
              color: StudioColors.card,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: StudioColors.border),
            ),
            child: Text(
              isScanning
                  ? 'Listening for Bluetooth advertisements…'
                  : 'No additional amplifiers found. Tap Scan to search again.',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: StudioColors.textSecondary,
                fontSize: 12.5,
              ),
            ),
          )
        else
          ...available.map(
            (device) =>
                _buildAvailableTile(context, device, multiDevice, settings),
          ),
      ],
    );
  }

  Widget _buildConnectedTile(
    BuildContext context, {
    required AcquisitionService service,
    required SettingsService settings,
    required ValueChanged<DeviceProfile> onSelectProfile,
    required VoidCallback onDisconnect,
  }) {
    final matching = settings.deviceProfiles
        .where((p) => p.enabled && p.transport != ConnectionTransport.lsl)
        .toList(growable: false);
    final activeProfile = service.connectedDeviceProfile;
    final rate = service.deliveredSampleRate;
    final color = service.isStreamReady
        ? StudioColors.emerald
        : StudioColors.amber;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: StudioColors.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                service.isStreamReady
                    ? Icons.graphic_eq
                    : Icons.bluetooth_connected,
                color: color,
                size: 20,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      service.connectedDeviceLabel,
                      style: const TextStyle(
                        color: StudioColors.textPrimary,
                        fontWeight: FontWeight.w600,
                        fontSize: 13.5,
                      ),
                    ),
                    Text(
                      service.isStreamReady
                          ? '${rate != null ? '${rate.toStringAsFixed(0)} Hz • ' : ''}${service.channelCount} ch streaming'
                          : service.currentState.name,
                      style: TextStyle(color: color, fontSize: 11.5),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Disconnect device',
                visualDensity: VisualDensity.compact,
                icon: const Icon(
                  Icons.link_off,
                  color: StudioColors.red,
                  size: 20,
                ),
                onPressed: onDisconnect,
              ),
            ],
          ),
          if (matching.length > 1) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                const Text(
                  'Profile:',
                  style: TextStyle(
                    color: StudioColors.textSecondary,
                    fontSize: 11.5,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: DropdownButton<String>(
                    isExpanded: true,
                    isDense: true,
                    value: matching.any((p) => p.id == activeProfile?.id)
                        ? activeProfile?.id
                        : null,
                    hint: const Text(
                      'Select device profile',
                      style: TextStyle(
                        color: StudioColors.textMuted,
                        fontSize: 12,
                      ),
                    ),
                    dropdownColor: StudioColors.elevated,
                    style: const TextStyle(
                      color: StudioColors.textPrimary,
                      fontSize: 12,
                    ),
                    items: matching
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
                      if (profile != null) onSelectProfile(profile);
                    },
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildAvailableTile(
    BuildContext context,
    EegDevice device,
    MultiDeviceAcquisitionService multiDevice,
    SettingsService settings,
  ) {
    final matching = multiDevice.matchingProfilesFor(device);
    final selectedId = _selectedProfileIds[device.id] ?? device.profileId;
    final effectiveProfile = selectedId != null
        ? settings.profileById(selectedId)
        : (matching.isNotEmpty ? matching.first : null);
    final connecting = multiDevice.isDeviceConnectedOrConnecting(device.id);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
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
              Icon(
                device.isBle ? Icons.bluetooth : Icons.devices_other,
                color: StudioColors.teal,
                size: 20,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      device.name,
                      style: const TextStyle(
                        color: StudioColors.textPrimary,
                        fontWeight: FontWeight.w600,
                        fontSize: 13.5,
                      ),
                    ),
                    Text(
                      '${device.id} • ${(effectiveProfile?.name ?? device.kind.name).toUpperCase()}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: StudioColors.textSecondary,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: StudioColors.teal,
                  foregroundColor: Colors.black,
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: connecting
                    ? null
                    : () {
                        final target = effectiveProfile == null
                            ? device
                            : EegDevice(
                                name: device.name,
                                id: device.id,
                                kind: switch (effectiveProfile.protocol) {
                                  DeviceProtocol.xampBinary =>
                                    DeviceKind.epidome,
                                  DeviceProtocol.orbitJson => DeviceKind.orbit,
                                  DeviceProtocol.synthetic =>
                                    DeviceKind.synthetic,
                                  _ => DeviceKind.generic,
                                },
                                isBle: device.isBle,
                                profileId: effectiveProfile.id,
                              );
                        unawaited(multiDevice.connect(target));
                      },
                child: Text(connecting ? 'Connecting…' : 'Connect'),
              ),
            ],
          ),
          if (matching.length > 1) ...[
            const SizedBox(height: 6),
            DropdownButtonFormField<String>(
              initialValue: matching.any((p) => p.id == effectiveProfile?.id)
                  ? effectiveProfile!.id
                  : matching.first.id,
              isDense: true,
              dropdownColor: StudioColors.elevated,
              style: const TextStyle(
                color: StudioColors.textPrimary,
                fontSize: 12,
              ),
              decoration: const InputDecoration(
                labelText: 'Project / Channel Profile',
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
              ),
              items: matching
                  .map(
                    (p) => DropdownMenuItem(
                      value: p.id,
                      child: Text(
                        p.projectTag.isNotEmpty
                            ? '${p.name} — ${p.projectTag}'
                            : p.name,
                      ),
                    ),
                  )
                  .toList(),
              onChanged: (id) {
                if (id != null) {
                  setState(() => _selectedProfileIds[device.id] = id);
                }
              },
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildLslTab(
    BuildContext context,
    MultiStreamLslService multiLsl,
    SettingsService settings,
  ) {
    final configuredLslStreams = settings.deviceProfiles
        .where((device) => device.enabled && device.transport == ConnectionTransport.lsl)
        .expand((device) => device.enabledStreams)
        .length;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: StudioColors.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: StudioColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.wifi, color: StudioColors.violet, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      configuredLslStreams == 0
                          ? 'No enabled LSL stream profiles'
                          : '$configuredLslStreams configured LSL stream(s)',
                      style: const TextStyle(
                        color: StudioColors.textPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Text(
                      'Supports EEG, EOG, EMG, fNIRS, physiological, and marker streams over WiFi/LAN.',
                      style: TextStyle(
                        color: StudioColors.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: StudioColors.violet,
              foregroundColor: Colors.white,
            ),
            onPressed:
                configuredLslStreams == 0 ||
                    multiLsl.state == AcquisitionState.connecting
                ? null
                : () {
                    multiLsl.connectConfigured(settings.deviceProfiles);
                    Navigator.of(context).pop();
                  },
            icon: const Icon(Icons.link, size: 18),
            label: Text(
              multiLsl.state == AcquisitionState.connecting
                  ? 'Resolving LSL streams…'
                  : 'Connect LSL Streams',
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSimulateTab(
    BuildContext context,
    AcquisitionService eegService,
  ) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: StudioColors.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: StudioColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Row(
            children: [
              Icon(Icons.waves, color: StudioColors.sky, size: 22),
              SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Synthetic EEG Mode (16-ch)',
                      style: TextStyle(
                        color: StudioColors.textPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      'Simulates 16-ch EpiDome waveforms at 250 Hz for bench testing without hardware.',
                      style: TextStyle(
                        color: StudioColors.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: StudioColors.sky,
              foregroundColor: Colors.black,
            ),
            onPressed: () {
              eegService.addSyntheticDevice();
              final synth = eegService.discoveredDevices.firstWhere(
                (d) => d.kind == DeviceKind.synthetic,
              );
              eegService.connect(synth);
              Navigator.of(context).pop();
            },
            icon: const Icon(Icons.play_arrow, size: 18),
            label: const Text('Start 16-ch Simulation'),
          ),
        ],
      ),
    );
  }
}

void showQuickModuleSwitcher(BuildContext context) {
  showModalBottomSheet(
    context: context,
    backgroundColor: StudioColors.elevated,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => const QuickModuleSwitcherModal(),
  );
}

class QuickModuleSwitcherModal extends StatelessWidget {
  const QuickModuleSwitcherModal({super.key});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.apps, color: StudioColors.blue, size: 24),
                SizedBox(width: 10),
                Text(
                  'Quick Module Switcher',
                  style: TextStyle(
                    color: StudioColors.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              'Switch between research modules without disconnecting EEG hardware.',
              style: TextStyle(color: StudioColors.textSecondary, fontSize: 13),
            ),
            const SizedBox(height: 16),
            _buildModuleOption(
              context,
              title: 'Home Dashboard',
              subtitle: 'Return to main overview & system diagnostics',
              icon: Icons.home_rounded,
              color: StudioColors.blue,
              isHome: true,
            ),
            _buildModuleOption(
              context,
              title: 'EEG & fNIRS Recorder',
              subtitle: '16-channel waveform viewer & EDF+ recording',
              icon: Icons.monitor_heart,
              color: StudioColors.teal,
              routeName: '/standalone',
            ),
            _buildModuleOption(
              context,
              title: 'Train NIDRA',
              subtitle: 'Real-time sleep staging & auditory biofeedback',
              icon: Icons.nightlight_round,
              color: StudioColors.violet,
              routeName: '/nidra',
            ),
            _buildModuleOption(
              context,
              title: 'ANGEL Cognitive Task',
              subtitle: 'Event-Related Potential battery & PDF reports',
              icon: Icons.psychology,
              color: StudioColors.amber,
              routeName: '/angel',
            ),
            _buildModuleOption(
              context,
              title: 'Adaptive Working Memory',
              subtitle: 'N-Back cognitive task with EEG workload tracking',
              icon: Icons.memory,
              color: Color(0xFFEC4899),
              routeName: '/wm',
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildModuleOption(
    BuildContext context, {
    required String title,
    required String subtitle,
    required IconData icon,
    required Color color,
    bool isHome = false,
    String? routeName,
  }) {
    return ListTile(
      leading: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, color: color, size: 22),
      ),
      title: Text(
        title,
        style: const TextStyle(
          color: StudioColors.textPrimary,
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: const TextStyle(color: StudioColors.textSecondary, fontSize: 12),
      ),
      onTap: () {
        Navigator.of(context).pop();
        final session = context.read<SessionManager>();
        void doSwitch() {
          if (isHome) {
            Navigator.of(context).popUntil((route) => route.isFirst);
          } else if (routeName != null) {
            Navigator.of(
              context,
            ).pushNamedAndRemoveUntil(routeName, (route) => route.isFirst);
          }
        }

        if (session.isRecording) {
          showDialog(
            context: context,
            builder: (ctx) => AlertDialog(
              backgroundColor: StudioColors.elevated,
              title: const Text(
                'Active Recording',
                style: TextStyle(color: StudioColors.red),
              ),
              content: Text(
                'An EEG recording is currently active (${session.activeModule?.displayName ?? "Unknown"}). Do you want to stop and save before switching modules?',
                style: const TextStyle(color: StudioColors.textSecondary),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    doSwitch();
                  },
                  child: const Text(
                    'Switch Without Stopping',
                    style: TextStyle(color: StudioColors.amber),
                  ),
                ),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: StudioColors.emerald,
                    foregroundColor: Colors.black,
                  ),
                  onPressed: () {
                    session.stopRecording();
                    Navigator.of(ctx).pop();
                    doSwitch();
                  },
                  child: const Text('Stop & Switch'),
                ),
              ],
            ),
          );
        } else {
          doSwitch();
        }
      },
    );
  }
}
