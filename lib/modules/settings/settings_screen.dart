import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../../core/theme/studio_theme.dart';
import 'package:provider/provider.dart';

import 'package:package_info_plus/package_info_plus.dart';

import '../../core/services/settings_service.dart';
import '../../core/services/channel_config_service.dart';
import '../../core/services/alert_service.dart';
import '../../core/services/permission_service.dart';
import '../../core/services/app_update_service.dart';
import '../../core/models/module_type.dart';
import '../../core/models/device_profile.dart';
import '../../core/models/manual_marker.dart';
import '../../core/eeg/acquisition_service.dart';

/// Global settings & channel configuration screen.
///
/// Controls LSL streaming properties, EEG/fNIRS channel names and enablement,
/// and auditory alert test functions.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, this.initialTabIndex = 0});

  final int initialTabIndex;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  late TextEditingController _xampPrefixCtrl;
  late TextEditingController _eegStreamNameCtrl;
  late TextEditingController _eegStreamTypeCtrl;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: 3,
      vsync: this,
      initialIndex: widget.initialTabIndex.clamp(0, 2),
    );
    final settings = context.read<SettingsService>();
    _xampPrefixCtrl = TextEditingController(text: settings.xampPrefix);
    _eegStreamNameCtrl = TextEditingController(
      text: settings.lslConfig.eegStreamName,
    );
    _eegStreamTypeCtrl = TextEditingController(
      text: settings.lslConfig.eegStreamType,
    );
  }

  @override
  void dispose() {
    _tabController.dispose();
    _xampPrefixCtrl.dispose();
    _eegStreamNameCtrl.dispose();
    _eegStreamTypeCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final channelConfig = context.watch<ChannelConfigService>();
    final settings = context.watch<SettingsService>();
    final alertService = context.watch<AlertService>();
    final lightTeal = StudioColors.teal;
    final compact = MediaQuery.sizeOf(context).width < 600;

    return Scaffold(
      backgroundColor: StudioColors.canvas,
      appBar: AppBar(
        title: Text(
          compact ? 'Settings' : 'Global Settings & Channels',
          style: TextStyle(color: StudioColors.textPrimary),
        ),
        backgroundColor: StudioColors.surface,
        elevation: 0,
        iconTheme: const IconThemeData(color: StudioColors.textPrimary),
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          indicatorColor: lightTeal,
          labelColor: lightTeal,
          unselectedLabelColor: StudioColors.textMuted,
          tabs: const [
            Tab(text: 'Channel Configuration'),
            Tab(text: 'Device & Network Settings'),
            Tab(text: 'Output & Study Flow'),
          ],
        ),
      ),
      body: SafeArea(
        child: TabBarView(
          controller: _tabController,
          children: [
            _buildChannelTab(channelConfig, lightTeal),
            _buildLslTab(settings, alertService, lightTeal),
            _buildStudyFlowTab(settings, lightTeal),
          ],
        ),
      ),
    );
  }

  Widget _buildChannelTab(ChannelConfigService config, Color lightTeal) {
    final settings = context.watch<SettingsService>();
    final compact = MediaQuery.sizeOf(context).width < 600;
    return ListView(
      padding: EdgeInsets.all(compact ? 12 : 20),
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          alignment: WrapAlignment.spaceBetween,
          children: [
            const Text(
              'Device & Project Profiles',
              style: TextStyle(
                color: StudioColors.textPrimary,
                fontSize: 17,
                fontWeight: FontWeight.bold,
              ),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                OutlinedButton.icon(
                  onPressed: () async {
                    try {
                      final imported = await settings.importDeviceProfileJson();
                      if (!mounted || imported == null) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Imported profile "${imported.name}"'),
                        ),
                      );
                    } catch (e) {
                      if (!mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Import failed: $e')),
                      );
                    }
                  },
                  icon: const Icon(Icons.file_upload_outlined, size: 17),
                  label: const Text('Import'),
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  onPressed: () => _createDeviceProfile(settings),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('New Profile'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: lightTeal,
                    foregroundColor: Colors.white,
                  ),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 8),
        const Text(
          'Create multiple profiles for the same amplifier (e.g., Sleep PSG vs. '
          'Resting EEG vs. ERP). Duplicate a profile, set an active default for '
          'auto-matching, or switch profiles directly in the Connect dialog.',
          style: TextStyle(color: StudioColors.textMuted, fontSize: 13),
        ),
        const SizedBox(height: 14),
        ...settings.deviceProfiles.map((profile) {
          final isCore = profile.id == 'xamp_l10' || profile.id == 'orbit';
          return Card(
            color: StudioColors.card,
            margin: const EdgeInsets.only(bottom: 10),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(
                color: profile.isDefaultForHardware
                    ? lightTeal.withValues(alpha: 0.7)
                    : StudioColors.border,
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        profile.transport == ConnectionTransport.lsl
                            ? Icons.wifi
                            : Icons.bluetooth,
                        color: profile.enabled ? lightTeal : Colors.white30,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Wrap(
                              spacing: 8,
                              runSpacing: 4,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                Text(
                                  profile.name,
                                  style: TextStyle(
                                    color: profile.enabled
                                        ? StudioColors.textPrimary
                                        : StudioColors.textMuted,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 15,
                                  ),
                                ),
                                if (profile.projectTag.trim().isNotEmpty)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 7,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: const Color(
                                        0xFF38BDF8,
                                      ).withValues(alpha: 0.16),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Text(
                                      profile.projectTag,
                                      style: const TextStyle(
                                        color: Color(0xFF38BDF8),
                                        fontSize: 10.5,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                if (profile.isDefaultForHardware)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 7,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: lightTeal.withValues(alpha: 0.18),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Text(
                                      'ACTIVE DEFAULT',
                                      style: TextStyle(
                                        color: lightTeal,
                                        fontSize: 10,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 3),
                            Text(
                              '${profile.transport.label} • ${profile.protocol.label}'
                              '${profile.advertisedNamePattern.isNotEmpty ? ' • Match "${profile.advertisedNamePattern}"' : ''}\n'
                              '${profile.enabledStreams.map((stream) => '${stream.signalType.label}: ${stream.channelCount} ch @ ${stream.sampleRate} Hz').join('  •  ')}',
                              style: const TextStyle(
                                color: StudioColors.textMuted,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      if (!profile.isDefaultForHardware &&
                          profile.transport != ConnectionTransport.lsl)
                        ActionChip(
                          avatar: Icon(Icons.check_circle_outline,
                              size: 15, color: lightTeal),
                          label: const Text('Set Active Default',
                              style: TextStyle(fontSize: 11.5)),
                          onPressed: () =>
                              settings.setDefaultDeviceProfile(profile.id),
                        ),
                      ActionChip(
                        avatar: const Icon(Icons.copy_outlined,
                            size: 15, color: Color(0xFF38BDF8)),
                        label: const Text('Duplicate for Project',
                            style: TextStyle(fontSize: 11.5)),
                        onPressed: () =>
                            _promptDuplicateProfile(settings, profile),
                      ),
                      ActionChip(
                        avatar: const Icon(Icons.edit_outlined,
                            size: 15, color: StudioColors.textSecondary),
                        label: const Text('Edit Channels',
                            style: TextStyle(fontSize: 11.5)),
                        onPressed: () =>
                            _showDeviceProfileDialog(settings, profile),
                      ),
                      ActionChip(
                        avatar: const Icon(Icons.download_outlined,
                            size: 15, color: StudioColors.textSecondary),
                        label: const Text('Export',
                            style: TextStyle(fontSize: 11.5)),
                        onPressed: () async {
                          final path = await settings.exportDeviceProfileJson(
                            profile,
                          );
                          if (!mounted || path == null) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Profile saved to $path')),
                          );
                        },
                      ),
                      if (!isCore)
                        ActionChip(
                          avatar: const Icon(Icons.delete_outline,
                              size: 15, color: Colors.redAccent),
                          label: const Text('Delete',
                              style: TextStyle(
                                  fontSize: 11.5, color: Colors.redAccent)),
                          onPressed: () =>
                              settings.removeDeviceProfile(profile.id),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          );
        }),
        SwitchListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 4),
          title: const Text(
            'Combine Orbit EEG + interpolated PPG',
            style: TextStyle(color: StudioColors.textPrimary),
          ),
          subtitle: const Text(
            'On: one 250 Hz EDF with AF7, AF8, PPG, and Marker. Off: EEG at 250 Hz plus a synchronized native 62.5 Hz PPG EDF. Other independently clocked streams remain separate.',
            style: TextStyle(color: StudioColors.textMuted, fontSize: 12),
          ),
          value: settings.combineCompatibleStreams,
          activeThumbColor: lightTeal,
          onChanged: (value) =>
              settings.update((item) => item.combineCompatibleStreams = value),
        ),
      ],
    );
  }

  Future<void> _promptDuplicateProfile(
    SettingsService settings,
    DeviceProfile source,
  ) async {
    final nameCtrl = TextEditingController(text: '${source.name} • Study 2');
    final projectCtrl = TextEditingController(text: source.projectTag);
    var makeDefault = true;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: StudioColors.card,
          title: Text(
            'Duplicate ${source.name}',
            style: const TextStyle(color: StudioColors.textPrimary),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                style: const TextStyle(color: StudioColors.textPrimary),
                decoration: const InputDecoration(labelText: 'Profile Name'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: projectCtrl,
                style: const TextStyle(color: StudioColors.textPrimary),
                decoration: const InputDecoration(
                  labelText: 'Research Project / Study Tag',
                  hintText: 'e.g. Sleep PSG, Oddball ERP, Meditation',
                ),
              ),
              const SizedBox(height: 6),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: makeDefault,
                title: const Text(
                  'Make active default for this hardware',
                  style: TextStyle(color: StudioColors.textSecondary, fontSize: 13),
                ),
                onChanged: (v) =>
                    setDialogState(() => makeDefault = v ?? true),
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
              child: const Text('Create & Edit'),
            ),
          ],
        ),
      ),
    );

    final name = nameCtrl.text.trim();
    final project = projectCtrl.text.trim();
    nameCtrl.dispose();
    projectCtrl.dispose();
    if (confirmed != true || !mounted) return;

    final copy = settings.duplicateDeviceProfile(
      source.id,
      newName: name.isEmpty ? '${source.name} Copy' : name,
      projectTag: project,
    );
    if (makeDefault) {
      settings.setDefaultDeviceProfile(copy.id);
    }
    await _showDeviceProfileDialog(settings, copy);
  }

  void _createDeviceProfile(SettingsService settings) {
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final profile = DeviceProfile(
      id: 'device_$stamp',
      name: 'Other device',
      enabled: false,
      transport: ConnectionTransport.bluetoothLe,
      protocol: DeviceProtocol.delimitedText,
      streams: [
        SignalStreamProfile(
          id: 'stream_$stamp',
          name: 'Signal stream',
          signalType: SignalType.eeg,
          sampleRate: 250,
          channelLabels: const ['Ch 1'],
        ),
      ],
    );
    _showDeviceProfileDialog(settings, profile, isNew: true);
  }

  Future<void> _showDeviceProfileDialog(
    SettingsService settings,
    DeviceProfile source, {
    bool isNew = false,
  }) async {
    final profile = DeviceProfile.fromJson(source.toJson());
    _mergeXampStreams(profile);
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: StudioColors.card,
          title: Text(
            isNew ? 'Add Device Profile' : 'Edit ${profile.name}',
            style: const TextStyle(color: StudioColors.textPrimary),
          ),
          content: SizedBox(
            width: 680,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text(
                      'Profile enabled',
                      style: TextStyle(color: StudioColors.textPrimary),
                    ),
                    value: profile.enabled,
                    onChanged: (value) =>
                        setDialogState(() => profile.enabled = value),
                  ),
                  TextFormField(
                    initialValue: profile.name,
                    style: const TextStyle(color: StudioColors.textPrimary),
                    decoration: const InputDecoration(labelText: 'Device / profile name'),
                    onChanged: (value) => profile.name = value,
                  ),
                  const SizedBox(height: 10),
                  TextFormField(
                    initialValue: profile.projectTag,
                    style: const TextStyle(color: StudioColors.textPrimary),
                    decoration: const InputDecoration(
                      labelText: 'Research project / study tag (optional)',
                      hintText: 'e.g. Sleep PSG, Resting EEG, Oddball ERP',
                    ),
                    onChanged: (value) => profile.projectTag = value,
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      SizedBox(
                        width: 260,
                        child: DropdownButtonFormField<ConnectionTransport>(
                          initialValue: profile.transport,
                          dropdownColor: StudioColors.surface,
                          decoration: const InputDecoration(
                            labelText: 'Connection transport',
                          ),
                          items: ConnectionTransport.values
                              .map(
                                (value) => DropdownMenuItem(
                                  value: value,
                                  child: Text(value.label),
                                ),
                              )
                              .toList(),
                          onChanged: (value) => setDialogState(() {
                            if (value == null) return;
                            profile.transport = value;
                            if (value == ConnectionTransport.lsl) {
                              profile.protocol = DeviceProtocol.lsl;
                            }
                          }),
                        ),
                      ),
                      SizedBox(
                        width: 260,
                        child: DropdownButtonFormField<DeviceProtocol>(
                          initialValue: profile.protocol,
                          dropdownColor: StudioColors.surface,
                          decoration: const InputDecoration(
                            labelText: 'Decoder / protocol',
                          ),
                          items: DeviceProtocol.values
                              .map(
                                (value) => DropdownMenuItem(
                                  value: value,
                                  child: Text(value.label),
                                ),
                              )
                              .toList(),
                          onChanged: (value) {
                            if (value == null) return;
                            setDialogState(() {
                              profile.protocol = value;
                              _mergeXampStreams(profile);
                            });
                          },
                        ),
                      ),
                    ],
                  ),
                  if (profile.transport != ConnectionTransport.lsl) ...[
                    const SizedBox(height: 12),
                    TextFormField(
                      initialValue: profile.advertisedNamePattern,
                      style: const TextStyle(color: StudioColors.textPrimary),
                      decoration: const InputDecoration(
                        labelText: 'Advertised-name match',
                        hintText: 'e.g. ORBIT_ or AXXSPU',
                      ),
                      onChanged: (value) =>
                          profile.advertisedNamePattern = value,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      initialValue: profile.addressPattern,
                      style: const TextStyle(color: StudioColors.textPrimary),
                      decoration: const InputDecoration(
                        labelText: 'MAC/address match (optional)',
                      ),
                      onChanged: (value) => profile.addressPattern = value,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      initialValue: profile.startCommand,
                      style: const TextStyle(color: StudioColors.textPrimary),
                      decoration: const InputDecoration(
                        labelText: 'Start-stream command (optional)',
                      ),
                      onChanged: (value) => profile.startCommand = value,
                    ),
                    if (profile.protocol == DeviceProtocol.delimitedText) ...[
                      const SizedBox(height: 12),
                      TextFormField(
                        initialValue: profile.delimiter,
                        style: const TextStyle(color: StudioColors.textPrimary),
                        decoration: const InputDecoration(
                          labelText: 'Field delimiter',
                        ),
                        onChanged: (value) => profile.delimiter = value,
                      ),
                    ],
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text(
                        'Auto-connect when matched',
                        style: TextStyle(color: StudioColors.textPrimary),
                      ),
                      value: profile.autoConnect,
                      onChanged: (value) => setDialogState(
                        () => profile.autoConnect = value ?? false,
                      ),
                    ),
                  ],
                  const Divider(color: StudioColors.border, height: 32),
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Signal streams',
                          style: TextStyle(
                            color: StudioColors.textPrimary,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: profile.protocol == DeviceProtocol.xampBinary
                            ? null
                            : () => setDialogState(() {
                                final id =
                                    'stream_${DateTime.now().microsecondsSinceEpoch}';
                                profile.streams.add(
                                  SignalStreamProfile(
                                    id: id,
                                    name: 'Signal stream',
                                    signalType: SignalType.eeg,
                                    sampleRate: 250,
                                    channelLabels: const ['Ch 1'],
                                  ),
                                );
                              }),
                        icon: const Icon(Icons.add),
                        label: const Text('Add stream'),
                      ),
                    ],
                  ),
                  const Text(
                    'One stream represents one independently sampled hardware clock. '
                    'A single xAMP is therefore one stream: assign EEG, EOG and EMG '
                    'roles below in decoder/hardware channel order.',
                    style: TextStyle(color: StudioColors.textMuted, fontSize: 12),
                  ),
                  ...profile.streams.asMap().entries.map(
                    (entry) => _buildStreamProfileEditor(
                      profile,
                      entry.key,
                      setDialogState,
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            if (!isNew && source.id != 'xamp_l10' && source.id != 'orbit')
              TextButton(
                onPressed: () {
                  settings.removeDeviceProfile(source.id);
                  Navigator.of(dialogContext).pop();
                },
                child: const Text(
                  'Delete',
                  style: TextStyle(color: Colors.redAccent),
                ),
              ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed:
                  profile.streams.isEmpty ||
                      !profile.streams
                          .where((stream) => stream.enabled)
                          .every(
                            (stream) =>
                                List.generate(
                                  stream.channelCount,
                                  (index) => index,
                                ).any(
                                  (index) =>
                                      stream.channelEnabled[index] &&
                                      stream.channelLabels[index]
                                          .trim()
                                          .isNotEmpty,
                                ),
                          )
                  ? null
                  : () {
                      _mergeXampStreams(profile);
                      settings.updateDeviceProfile(profile);
                      Navigator.of(dialogContext).pop();
                    },
              child: const Text('Save profile'),
            ),
          ],
        ),
      ),
    );
  }

  void _mergeXampStreams(DeviceProfile profile) {
    if (profile.protocol != DeviceProtocol.xampBinary ||
        profile.streams.length < 2) {
      return;
    }
    final first = profile.streams.first;
    for (final stream in profile.streams.skip(1)) {
      stream.synchronizeChannelTypes();
      first.channelLabels.addAll(stream.channelLabels);
      first.channelTypes.addAll(stream.channelTypes);
      first.channelEnabled.addAll(stream.channelEnabled);
    }
    first
      ..name = 'Signals'
      ..signalType = SignalType.eeg;
    profile.streams
      ..clear()
      ..add(first);
  }

  Widget _buildStreamProfileEditor(
    DeviceProfile device,
    int index,
    StateSetter setDialogState,
  ) {
    final stream = device.streams[index];
    Widget numberField(
      String label,
      double value,
      ValueChanged<double> onChanged,
    ) => SizedBox(
      width: 145,
      child: TextFormField(
        initialValue: value.toString(),
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        style: const TextStyle(color: StudioColors.textPrimary),
        decoration: InputDecoration(labelText: label),
        onChanged: (text) {
          final parsed = double.tryParse(text);
          if (parsed != null) onChanged(parsed);
        },
      ),
    );

    return Card(
      color: StudioColors.surface,
      margin: const EdgeInsets.only(top: 10),
      child: ExpansionTile(
        initiallyExpanded: true,
        title: Text(
          'Stream ${index + 1}: ${stream.name} • ${stream.channelCount} ordered ch @ ${stream.sampleRate} Hz',
          style: const TextStyle(color: StudioColors.textPrimary, fontSize: 14),
        ),
        subtitle: Text(
          stream.enabled
              ? 'Connected and recorded on this sample clock'
              : 'Disabled — not connected or captured',
          style: const TextStyle(color: StudioColors.textMuted, fontSize: 11),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Switch(
              value: stream.enabled,
              onChanged: (value) =>
                  setDialogState(() => stream.enabled = value),
            ),
            if (device.streams.length > 1)
              IconButton(
                tooltip: 'Remove stream',
                onPressed: () =>
                    setDialogState(() => device.streams.removeAt(index)),
                icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
              ),
          ],
        ),
        childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 16),
        children: [
          TextFormField(
            initialValue: stream.name,
            style: const TextStyle(color: StudioColors.textPrimary),
            decoration: const InputDecoration(labelText: 'Stream name'),
            onChanged: (value) => stream.name = value,
          ),
          const SizedBox(height: 10),
          if (device.transport == ConnectionTransport.lsl) ...[
            DropdownButtonFormField<SignalType>(
              initialValue: stream.signalType,
              dropdownColor: StudioColors.surface,
              decoration: const InputDecoration(
                labelText: 'LSL stream type / default channel role',
              ),
              items: SignalType.values
                  .map(
                    (value) => DropdownMenuItem(
                      value: value,
                      child: Text(value.label),
                    ),
                  )
                  .toList(),
              onChanged: (value) {
                if (value != null) {
                  setDialogState(() {
                    stream.signalType = value;
                    if (value == SignalType.marker) {
                      stream.channelTypes = List.filled(
                        stream.channelCount,
                        SignalType.marker,
                      );
                    }
                  });
                }
              },
            ),
            const SizedBox(height: 10),
          ],
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Hardware channel mapping',
                  style: TextStyle(
                    color: StudioColors.textPrimary,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: () => _bulkEditStreamChannels(
                  context,
                  stream,
                  setDialogState,
                ),
                icon: const Icon(Icons.playlist_add, size: 18),
                label: const Text('Bulk Paste'),
              ),
              TextButton.icon(
                onPressed: () => setDialogState(() {
                  stream.channelLabels.add(
                    'Ch ${stream.channelLabels.length + 1}',
                  );
                  stream.channelTypes.add(
                    stream.signalType == SignalType.marker
                        ? SignalType.marker
                        : stream.signalType,
                  );
                  stream.channelEnabled.add(true);
                }),
                icon: const Icon(Icons.add),
                label: const Text('Channel'),
              ),
              if (stream.channelCount > 1)
                IconButton(
                  tooltip: 'Remove last hardware channel',
                  onPressed: () => setDialogState(() {
                    stream.channelLabels.removeLast();
                    stream.channelTypes.removeLast();
                    stream.channelEnabled.removeLast();
                  }),
                  icon: const Icon(Icons.remove_circle_outline),
                ),
            ],
          ),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              ActionChip(
                label: const Text('10-20 (16-ch)', style: TextStyle(fontSize: 11)),
                onPressed: () => setDialogState(() {
                  _applyChannelTemplate(stream, kDefaultEpiDomeLabels);
                }),
              ),
              ActionChip(
                label: const Text('Sleep PSG (6-ch)', style: TextStyle(fontSize: 11)),
                onPressed: () => setDialogState(() {
                  _applyChannelTemplate(
                    stream,
                    const ['F3', 'C3', 'O1', 'Reog', 'Leog', 'EMG'],
                  );
                }),
              ),
              ActionChip(
                label: const Text('xAMP 8-ch', style: TextStyle(fontSize: 11)),
                onPressed: () => setDialogState(() {
                  _applyChannelTemplate(
                    stream,
                    const ['Fp1', 'Fp2', 'F3', 'F4', 'C3', 'C4', 'O1', 'O2'],
                  );
                }),
              ),
              ActionChip(
                label: Text(
                  stream.channelEnabled.every((e) => e)
                      ? 'Deselect All'
                      : 'Select All',
                  style: const TextStyle(fontSize: 11),
                ),
                onPressed: () => setDialogState(() {
                  final next = !stream.channelEnabled.every((e) => e);
                  stream.channelEnabled = List<bool>.filled(
                    stream.channelCount,
                    next,
                  );
                }),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            'Rows map by order: Ch 1 is the first value emitted by the decoder, '
            'Ch 2 the second, and so on. “Capture” controls EDF inclusion; role '
            'controls display filtering.',
            style: TextStyle(color: StudioColors.textMuted, fontSize: 11),
          ),
          const SizedBox(height: 8),
          ...List<Widget>.generate(stream.channelCount, (channel) {
            stream.synchronizeChannelTypes();
            const selectable = [
              SignalType.eeg,
              SignalType.eog,
              SignalType.emg,
              SignalType.ecg,
              SignalType.ppg,
              SignalType.fnirs,
              SignalType.auxiliary,
            ];
            final type = stream.channelTypes[channel];
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  SizedBox(
                    width: 46,
                    child: Text(
                      'Ch ${channel + 1}',
                      style: const TextStyle(
                        color: StudioColors.textSecondary,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  Tooltip(
                    message: 'Capture this channel in EDF',
                    child: Checkbox(
                      value: stream.channelEnabled[channel],
                      onChanged: (value) => setDialogState(
                        () => stream.channelEnabled[channel] = value ?? false,
                      ),
                    ),
                  ),
                  Expanded(
                    child: TextFormField(
                      key: ValueKey(
                        '${stream.id}:label:$channel:${stream.channelLabels[channel]}',
                      ),
                      initialValue: stream.channelLabels[channel],
                      style: const TextStyle(color: StudioColors.textPrimary),
                      decoration: const InputDecoration(
                        labelText: 'Channel label',
                        isDense: true,
                      ),
                      onChanged: (value) =>
                          stream.channelLabels[channel] = value,
                    ),
                  ),
                  if (stream.signalType != SignalType.marker) ...[
                    const SizedBox(width: 8),
                    DropdownButton<SignalType>(
                      value: selectable.contains(type)
                          ? type
                          : SignalType.auxiliary,
                      dropdownColor: StudioColors.surface,
                      style: const TextStyle(color: StudioColors.textPrimary),
                      items: selectable
                          .map(
                            (value) => DropdownMenuItem(
                              value: value,
                              child: Text(value.label),
                            ),
                          )
                          .toList(),
                      onChanged: (value) {
                        if (value == null) return;
                        setDialogState(
                          () => stream.channelTypes[channel] = value,
                        );
                      },
                    ),
                  ],
                  if (stream.channelCount > 1)
                    IconButton(
                      tooltip: 'Remove channel row',
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(
                        Icons.close,
                        size: 16,
                        color: StudioColors.textMuted,
                      ),
                      onPressed: () => setDialogState(() {
                        stream.channelLabels.removeAt(channel);
                        stream.channelTypes.removeAt(channel);
                        stream.channelEnabled.removeAt(channel);
                      }),
                    ),
                ],
              ),
            );
          }),
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              numberField(
                'Sampling rate (Hz)',
                stream.sampleRate,
                (value) => stream.sampleRate = value.clamp(0.1, 10000),
              ),
              SizedBox(
                width: 130,
                child: TextFormField(
                  initialValue: stream.unit,
                  style: const TextStyle(color: StudioColors.textPrimary),
                  decoration: const InputDecoration(labelText: 'Unit'),
                  onChanged: (value) => stream.unit = value,
                ),
              ),
              numberField(
                'EDF minimum',
                stream.physicalMinimum,
                (value) => stream.physicalMinimum = value,
              ),
              numberField(
                'EDF maximum',
                stream.physicalMaximum,
                (value) => stream.physicalMaximum = value,
              ),
            ],
          ),
          if (device.transport == ConnectionTransport.lsl) ...[
            const SizedBox(height: 10),
            TextFormField(
              initialValue: stream.lslName,
              style: const TextStyle(color: StudioColors.textPrimary),
              decoration: const InputDecoration(
                labelText: 'LSL stream name (optional)',
              ),
              onChanged: (value) => stream.lslName = value,
            ),
            const SizedBox(height: 10),
            TextFormField(
              initialValue: stream.lslType.isEmpty
                  ? stream.signalType.label
                  : stream.lslType,
              style: const TextStyle(color: StudioColors.textPrimary),
              decoration: const InputDecoration(labelText: 'LSL stream type'),
              onChanged: (value) => stream.lslType = value,
            ),
          ],
        ],
      ),
    );
  }

  void _applyChannelTemplate(
    SignalStreamProfile stream,
    List<String> templateLabels,
  ) {
    stream.channelLabels = List<String>.from(templateLabels);
    stream.channelTypes = SignalStreamProfile.normalizeChannelTypes(
      stream.channelLabels,
      null,
    );
    stream.channelEnabled = List<bool>.filled(
      stream.channelLabels.length,
      true,
    );
  }

  Future<void> _bulkEditStreamChannels(
    BuildContext context,
    SignalStreamProfile stream,
    StateSetter setParentDialogState,
  ) async {
    final ctrl = TextEditingController(text: stream.channelLabels.join(', '));
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: StudioColors.card,
        title: const Text(
          'Bulk Edit Channels',
          style: TextStyle(color: StudioColors.textPrimary),
        ),
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Enter or paste channel names separated by commas, spaces, or newlines. Roles (EEG, EOG, EMG, ECG, PPG) are inferred automatically.',
                style: TextStyle(color: StudioColors.textSecondary, fontSize: 12),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: ctrl,
                maxLines: 5,
                style: const TextStyle(color: StudioColors.textPrimary),
                decoration: const InputDecoration(
                  hintText: 'Fp1, Fp2, F3, F4, C3, C4, O1, O2, Reog, Leog, EMG',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('Apply Channels'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (result == null) return;
    final parsed = result
        .split(RegExp(r'[\n,;]+'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
    if (parsed.isEmpty) return;
    setParentDialogState(() {
      _applyChannelTemplate(stream, parsed);
    });
  }

  Widget _buildLslTab(
    SettingsService settings,
    AlertService alertService,
    Color lightTeal,
  ) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Display & Accessibility',
            style: TextStyle(
              color: StudioColors.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 12),
          _buildTextScaleTile(settings, lightTeal),
          const SizedBox(height: 16),
          _buildWaveformDisplayTile(settings, lightTeal),
          const SizedBox(height: 16),
          _buildMarkerProfilesTile(settings, lightTeal),
          const SizedBox(height: 32),
          const Text(
            'BLE Target Device Configuration',
            style: TextStyle(
              color: StudioColors.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'Set the specific amplifier prefix or MAC address (e.g., AXXSPU00002, AXXSPU00003) to prevent cross-connecting when multiple amplifiers are nearby.',
            style: TextStyle(color: StudioColors.textMuted, fontSize: 13),
          ),
          const SizedBox(height: 20),
          _buildTextField('xAMP / BLE Device Target Prefix', _xampPrefixCtrl, (
            val,
          ) {
            settings.update((s) => s.xampPrefix = val);
          }),
          const SizedBox(height: 16),
          _buildSwitchTile(
            title: 'Reconnect warning beep',
            subtitle:
                'Play repeated alert tones while auto-reconnect is failing',
            value: settings.reconnectBeepEnabled,
            color: lightTeal,
            onChanged: (val) =>
                settings.update((s) => s.reconnectBeepEnabled = val),
          ),
          const SizedBox(height: 16),
          _buildDisconnectionTimeoutTile(settings, lightTeal),
          const SizedBox(height: 32),
          const Text(
            'Lab Streaming Layer (LSL) Discovery',
            style: TextStyle(
              color: StudioColors.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'Configure target stream properties for WiFi EEG and fNIRS synchronization.',
            style: TextStyle(color: StudioColors.textMuted, fontSize: 13),
          ),
          const SizedBox(height: 20),
          _buildTextField('EEG Stream Name (Optional)', _eegStreamNameCtrl, (
            val,
          ) {
            settings.updateLslConfig(
              settings.lslConfig.copyWith(eegStreamName: val),
            );
          }),
          const SizedBox(height: 16),
          _buildTextField('EEG Stream Type', _eegStreamTypeCtrl, (val) {
            settings.updateLslConfig(
              settings.lslConfig.copyWith(eegStreamType: val),
            );
          }),
          const SizedBox(height: 32),
          const Text(
            'Auditory & Alert Verification',
            style: TextStyle(
              color: StudioColors.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: StudioColors.card,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.surround_sound,
                  color: StudioColors.blue,
                  size: 28,
                ),
                const SizedBox(width: 16),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'System Beep & Audio Stim',
                        style: TextStyle(
                          color: StudioColors.textPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        'Verify sound output for sleep and cognitive feedback',
                        style: TextStyle(color: StudioColors.textMuted, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: StudioColors.blue,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: () => alertService.playBeep(),
                  child: const Text('Test Sound'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 32),
          const Text(
            'Hardware Simulation & Bench Testing',
            style: TextStyle(
              color: StudioColors.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: StudioColors.card,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                const Icon(Icons.waves, color: Color(0xFF38BDF8), size: 28),
                const SizedBox(width: 16),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Synthetic EEG Mode (16-ch EpiDome Sim)',
                        style: TextStyle(
                          color: StudioColors.textPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        'Simulates 16 frontal/parietal channels at 250 Hz for bench testing without hardware',
                        style: TextStyle(color: StudioColors.textMuted, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                Switch(
                  value: settings.syntheticMode,
                  activeThumbColor: const Color(0xFF38BDF8),
                  onChanged: (val) {
                    settings.updateSyntheticMode(val);
                    if (val) {
                      final eeg = context.read<AcquisitionService>();
                      eeg.addSyntheticDevice();
                      final synth = eeg.discoveredDevices.firstWhere(
                        (d) => d.kind == DeviceKind.synthetic,
                      );
                      eeg.connect(synth);
                    } else {
                      context.read<AcquisitionService>().disconnect();
                    }
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStudyFlowTab(SettingsService settings, Color lightTeal) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Output Folder',
            style: TextStyle(
              color: StudioColors.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Every EDF, marker file, task log, JSON result, and PDF report is '
            'copied here under Subject / Session folders.',
            style: TextStyle(color: StudioColors.textMuted, fontSize: 13),
          ),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: StudioColors.card,
              borderRadius: BorderRadius.circular(10),
            ),
            child: FutureBuilder<String>(
              future: settings.effectiveOutputDirectory(),
              builder: (context, snapshot) => SelectableText(
                snapshot.data ?? 'Resolving output folder…',
                style: const TextStyle(
                  color: StudioColors.textPrimary,
                  fontFamily: 'monospace',
                  fontSize: 12,
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: () async {
                  final changed = await settings.chooseOutputDirectory();
                  if (!mounted || !changed) return;
                  final path = await settings.effectiveOutputDirectory();
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Output folder set to $path')),
                  );
                },
                icon: const Icon(Icons.drive_folder_upload_outlined),
                label: const Text('Choose Folder'),
              ),
              OutlinedButton.icon(
                onPressed: () async {
                  final opened = await settings.openOutputDirectory();
                  if (!mounted || opened) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                        'Could not open the folder automatically. Copy the path shown above.',
                      ),
                    ),
                  );
                },
                icon: const Icon(Icons.folder_open),
                label: const Text('Open Folder'),
              ),
              TextButton.icon(
                onPressed: settings.outputDirectoryPath.isEmpty
                    ? null
                    : () => settings.resetOutputDirectory(),
                icon: const Icon(Icons.restore),
                label: const Text('Use Default'),
              ),
            ],
          ),
          const SizedBox(height: 28),
          const Text(
            'Paradigm Signal Recording',
            style: TextStyle(
              color: StudioColors.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Choose whether each paradigm records all connected enabled '
            'biopotential and LSL streams. When off, ANGEL and Adaptive WM '
            'run task-only and still save behavioral results.',
            style: TextStyle(color: StudioColors.textMuted, fontSize: 13),
          ),
          const SizedBox(height: 8),
          _buildSwitchTile(
            title: 'ANGEL • Record connected signals',
            subtitle: settings.angelRecordEeg
                ? 'Task + EEG / ECG / EMG / PPG / fNIRS'
                : 'Task-only; behavioral log and report still saved',
            value: settings.angelRecordEeg,
            color: lightTeal,
            onChanged: (value) =>
                settings.update((s) => s.angelRecordEeg = value),
          ),
          _buildSwitchTile(
            title: 'Adaptive WM • Record connected signals',
            subtitle: settings.wmRecordEeg
                ? 'Task + EEG / ECG / EMG / PPG / fNIRS'
                : 'Task-only; behavioral log and report still saved',
            value: settings.wmRecordEeg,
            color: lightTeal,
            onChanged: (value) => settings.update((s) => s.wmRecordEeg = value),
          ),
          _buildSwitchTile(
            title: 'HeartSync • Save physiological streams',
            subtitle: settings.heartSyncRecordPhysiology
                ? 'Save the live PPG/ECG and other connected streams'
                : 'Do not save continuous physiology; a live pulse signal is still required for timing',
            value: settings.heartSyncRecordPhysiology,
            color: lightTeal,
            onChanged: (value) =>
                settings.update((s) => s.heartSyncRecordPhysiology = value),
          ),
          const SizedBox(height: 28),
          const Text(
            'Study Run Order',
            style: TextStyle(
              color: StudioColors.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'Configure the exact module order for non-technical operators. Modules can appear more than once.',
            style: TextStyle(color: StudioColors.textMuted, fontSize: 13),
          ),
          const SizedBox(height: 16),
          ReorderableListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: settings.studySequence.length,
            onReorder: (oldIndex, newIndex) {
              final next = List<ModuleType>.from(settings.studySequence);
              if (newIndex > oldIndex) newIndex -= 1;
              final item = next.removeAt(oldIndex);
              next.insert(newIndex, item);
              settings.setStudySequence(next);
            },
            itemBuilder: (context, index) {
              final module = settings.studySequence[index];
              return ListTile(
                key: ValueKey('study-step-$index-${module.name}'),
                tileColor: StudioColors.card,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                leading: CircleAvatar(
                  backgroundColor: lightTeal.withValues(alpha: 0.15),
                  foregroundColor: lightTeal,
                  child: Text('${index + 1}'),
                ),
                title: Text(
                  module.displayName,
                  style: const TextStyle(color: StudioColors.textPrimary),
                ),
                subtitle: Text(
                  module.fileTag,
                  style: const TextStyle(color: StudioColors.textMuted),
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline, color: StudioColors.textMuted),
                  onPressed: () {
                    final next = List<ModuleType>.from(settings.studySequence)
                      ..removeAt(index);
                    settings.setStudySequence(next);
                  },
                ),
              );
            },
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: ModuleType.values.map((module) {
              return OutlinedButton.icon(
                onPressed: () {
                  final next = List<ModuleType>.from(settings.studySequence)
                    ..add(module);
                  settings.setStudySequence(next);
                },
                icon: const Icon(Icons.add, size: 18),
                label: Text(module.displayName),
                style: OutlinedButton.styleFrom(
                  foregroundColor: lightTeal,
                  side: BorderSide(color: lightTeal.withValues(alpha: 0.5)),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 12),
          const Text(
            'Backup / Export All Settings',
            style: TextStyle(
              color: StudioColors.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Save or load all configuration parameters (including channel configurations, hardware preferences, and individual cognitive battery settings) to sync settings across tablets.',
            style: TextStyle(color: StudioColors.textMuted, fontSize: 12, height: 1.4),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () async {
                    try {
                      final hasStorage = await context
                          .read<PermissionService>()
                          .requestManageExternalStorage(context);
                      if (!hasStorage) {
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                'Cannot export settings: storage permission is required.',
                              ),
                            ),
                          );
                        }
                        return;
                      }
                      final path = await settings.exportJson();
                      if (!mounted || path == null) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            'All settings successfully exported to $path',
                          ),
                        ),
                      );
                    } catch (e) {
                      if (!mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Failed to save settings: $e')),
                      );
                    }
                  },
                  icon: const Icon(Icons.backup),
                  label: const Text('Export Backup'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: StudioColors.card,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () async {
                    try {
                      final hasStorage = await context
                          .read<PermissionService>()
                          .requestManageExternalStorage(context);
                      if (!hasStorage) {
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                'Cannot import settings: storage permission is required.',
                              ),
                            ),
                          );
                        }
                        return;
                      }
                      final loaded = await settings.importJson();
                      if (!mounted) return;
                      _xampPrefixCtrl.text = settings.xampPrefix;
                      _eegStreamNameCtrl.text =
                          settings.lslConfig.eegStreamName;
                      _eegStreamTypeCtrl.text =
                          settings.lslConfig.eegStreamType;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            loaded
                                ? 'All settings successfully loaded & applied'
                                : 'Load cancelled',
                          ),
                        ),
                      );
                    } catch (e) {
                      if (!mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Failed to load settings: $e')),
                      );
                    }
                  },
                  icon: const Icon(Icons.settings_backup_restore),
                  label: const Text('Import Backup'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: lightTeal,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          const Divider(color: StudioColors.border),
          const SizedBox(height: 16),
          const Text(
            'Application & Updates',
            style: TextStyle(
              color: StudioColors.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Check for newer versions directly from GitHub Releases and upgrade the app in-place.',
            style: TextStyle(color: StudioColors.textMuted, fontSize: 13),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: StudioColors.card,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: StudioColors.border),
            ),
            child: Row(
              children: [
                Icon(Icons.system_update_alt, color: lightTeal, size: 28),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'CCS Mobile Studio',
                        style: TextStyle(
                          color: StudioColors.textPrimary,
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      FutureBuilder<PackageInfo>(
                        future: PackageInfo.fromPlatform(),
                        builder: (context, snapshot) {
                          final version = snapshot.hasData
                              ? 'v${snapshot.data!.version}+${snapshot.data!.buildNumber}'
                              : 'Loading version…';
                          return Text(
                            'Installed: $version',
                            style: const TextStyle(
                              color: StudioColors.textSecondary,
                              fontSize: 12,
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
                FilledButton.icon(
                  onPressed: () => showAppUpdateFlow(context),
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('Check Updates'),
                  style: FilledButton.styleFrom(
                    backgroundColor: lightTeal,
                    foregroundColor: Colors.white,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMarkerProfilesTile(SettingsService settings, Color color) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: StudioColors.card,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: StudioColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Manual marker profiles',
            style: TextStyle(
              color: StudioColors.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.bold,
            ),
          ),
          const Text(
            'The active bank appears in every live EEG viewer. Names remain editable after an event is sent.',
            style: TextStyle(color: StudioColors.textMuted, fontSize: 12),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  initialValue: settings.activeMarkerProfile,
                  dropdownColor: StudioColors.card,
                  decoration: const InputDecoration(
                    labelText: 'Active profile',
                  ),
                  items: settings.markerProfiles.keys
                      .map(
                        (name) =>
                            DropdownMenuItem(value: name, child: Text(name)),
                      )
                      .toList(),
                  onChanged: (name) {
                    if (name != null) {
                      settings.update((s) => s.activeMarkerProfile = name);
                    }
                  },
                ),
              ),
              const SizedBox(width: 10),
              FilledButton.icon(
                onPressed: () => _editMarkerProfile(settings),
                icon: const Icon(Icons.edit_outlined),
                label: const Text('Edit'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: settings.activeManualMarkers
                .map(
                  (marker) => Chip(
                    avatar: CircleAvatar(backgroundColor: marker.color),
                    label: Text('${marker.name} (${marker.code})'),
                  ),
                )
                .toList(),
          ),
        ],
      ),
    );
  }

  Future<void> _editMarkerProfile(SettingsService settings) async {
    final profileName = TextEditingController(
      text: settings.activeMarkerProfile,
    );
    final markers = settings.activeManualMarkers
        .map((marker) => marker.copyWith())
        .toList();
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, updateDialog) => AlertDialog(
          backgroundColor: StudioColors.card,
          title: const Text('Edit marker profile'),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: profileName,
                    decoration: const InputDecoration(
                      labelText: 'Profile name',
                    ),
                  ),
                  const SizedBox(height: 12),
                  for (var index = 0; index < markers.length; index++)
                    Row(
                      children: [
                        Expanded(
                          child: TextFormField(
                            key: ValueKey(
                              'marker-name-$index-${markers[index].name}',
                            ),
                            initialValue: markers[index].name,
                            decoration: const InputDecoration(
                              labelText: 'Name',
                            ),
                            onChanged: (value) => markers[index] =
                                markers[index].copyWith(name: value),
                          ),
                        ),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: 100,
                          child: TextFormField(
                            key: ValueKey(
                              'marker-code-$index-${markers[index].code}',
                            ),
                            initialValue: markers[index].code.toString(),
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: 'Code',
                            ),
                            onChanged: (value) {
                              final code = int.tryParse(value);
                              if (code != null) {
                                markers[index] = markers[index].copyWith(
                                  code: code.clamp(1, 32767),
                                );
                              }
                            },
                          ),
                        ),
                        IconButton(
                          onPressed: () =>
                              updateDialog(() => markers.removeAt(index)),
                          icon: const Icon(Icons.delete_outline),
                        ),
                      ],
                    ),
                  TextButton.icon(
                    onPressed: () => updateDialog(
                      () => markers.add(
                        ManualMarkerDefinition(
                          name: 'New marker',
                          code: markers.isEmpty ? 1 : markers.last.code + 1,
                        ),
                      ),
                    ),
                    icon: const Icon(Icons.add),
                    label: const Text('Add marker'),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: markers.isEmpty
                  ? null
                  : () {
                      settings.saveMarkerProfile(profileName.text, markers);
                      Navigator.pop(dialogContext);
                    },
              child: const Text('Save profile'),
            ),
          ],
        ),
      ),
    );
    profileName.dispose();
  }

  Widget _buildDisconnectionTimeoutTile(SettingsService settings, Color color) {
    const options = [2, 3, 5, 8, 10, 15, 20, 30];
    final current = options.contains(settings.disconnectionTimeoutSeconds)
        ? settings.disconnectionTimeoutSeconds
        : 5;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: StudioColors.card,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: StudioColors.border),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Disconnection detection speed',
                  style: TextStyle(color: StudioColors.textPrimary, fontSize: 14),
                ),
                const SizedBox(height: 4),
                const Text(
                  'How long without EEG samples before the app declares a disconnect, pauses the recording timer, and starts the beep + on-screen alert. Applies to NIDRA, ANGEL, Adaptive WM, and the EEG recorder.',
                  style: TextStyle(color: StudioColors.textMuted, fontSize: 12),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          DropdownButton<int>(
            value: current,
            dropdownColor: StudioColors.card,
            style: TextStyle(color: color, fontWeight: FontWeight.bold),
            underline: Container(
              height: 1,
              color: color.withValues(alpha: 0.4),
            ),
            items: options
                .map(
                  (secs) =>
                      DropdownMenuItem(value: secs, child: Text('${secs}s')),
                )
                .toList(),
            onChanged: (val) {
              if (val == null) return;
              settings.update((s) => s.disconnectionTimeoutSeconds = val);
            },
          ),
        ],
      ),
    );
  }

  Widget _buildTextScaleTile(SettingsService settings, Color color) {
    final percent = (settings.textScaleFactor * 100).round();
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      decoration: BoxDecoration(
        color: StudioColors.card,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: StudioColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'App text size',
                  style: TextStyle(color: StudioColors.textPrimary, fontSize: 14),
                ),
              ),
              Text(
                '$percent%',
                style: TextStyle(color: color, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const Text(
            'Applies throughout the app and is saved in the configuration.',
            style: TextStyle(color: StudioColors.textMuted, fontSize: 12),
          ),
          Slider(
            value: settings.textScaleFactor,
            min: 0.8,
            max: 1.4,
            divisions: 6,
            label: '$percent%',
            activeColor: color,
            onChanged: (value) =>
                settings.update((s) => s.textScaleFactor = value),
          ),
        ],
      ),
    );
  }

  Widget _buildWaveformDisplayTile(SettingsService settings, Color color) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
      decoration: BoxDecoration(
        color: StudioColors.card,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: StudioColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'EEG / ECG / PPG waveform display',
            style: TextStyle(
              color: StudioColors.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.bold,
            ),
          ),
          const Text(
            'Persistent viewer mode, epoch, autoscaling and fixed signal scales.',
            style: TextStyle(color: StudioColors.textMuted, fontSize: 12),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 16,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Mode ', style: TextStyle(color: StudioColors.textSecondary)),
                  DropdownButton<String>(
                    value: settings.waveformViewMode,
                    dropdownColor: StudioColors.card,
                    items: const [
                      DropdownMenuItem(
                        value: 'rolling',
                        child: Text('Rolling'),
                      ),
                      DropdownMenuItem(value: 'page', child: Text('Page')),
                    ],
                    onChanged: (value) {
                      if (value != null) {
                        settings.update((s) => s.waveformViewMode = value);
                      }
                    },
                  ),
                ],
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Epoch ', style: TextStyle(color: StudioColors.textSecondary)),
                  DropdownButton<int>(
                    value: settings.waveformDurationSeconds,
                    dropdownColor: StudioColors.card,
                    items: const [2, 4, 8, 10, 20, 30]
                        .map(
                          (seconds) => DropdownMenuItem(
                            value: seconds,
                            child: Text('${seconds}s'),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value != null) {
                        settings.update(
                          (s) => s.waveformDurationSeconds = value,
                        );
                      }
                    },
                  ),
                ],
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Autoscale',
                    style: TextStyle(color: StudioColors.textSecondary),
                  ),
                  Switch(
                    value: settings.waveformAutoscaleV2,
                    activeThumbColor: color,
                    onChanged: (value) =>
                        settings.update((s) => s.waveformAutoscaleV2 = value),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Trace thickness: ${settings.waveformStrokeWidth.toStringAsFixed(1)} px',
            style: const TextStyle(color: StudioColors.textSecondary),
          ),
          Slider(
            value: settings.waveformStrokeWidth,
            min: 0.5,
            max: 5,
            divisions: 18,
            activeColor: color,
            onChanged: (value) =>
                settings.update((s) => s.waveformStrokeWidth = value),
          ),
          Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              const Text(
                'Trace colour',
                style: TextStyle(color: StudioColors.textSecondary),
              ),
              for (final value in const [
                0xFF14B8A6,
                0xFF3B82F6,
                0xFFF87171,
                0xFFFBBF24,
                0xFF8B5CF6,
                0xFFFFFFFF,
              ])
                ChoiceChip(
                  label: const SizedBox(width: 18, height: 18),
                  avatar: CircleAvatar(backgroundColor: Color(value)),
                  selected: settings.waveformColorValue == value,
                  onSelected: (_) =>
                      settings.update((s) => s.waveformColorValue = value),
                ),
            ],
          ),
          _buildConfigScaleSlider(
            label: 'EEG full scale',
            unit: 'µV',
            value: settings.eegDisplayScaleUv,
            minimum: 10,
            maximum: 15000,
            enabled: !settings.waveformAutoscaleV2,
            color: color,
            onChanged: (value) =>
                settings.update((s) => s.eegDisplayScaleUv = value),
          ),
          _buildConfigScaleSlider(
            label: 'ECG full scale',
            unit: 'µV',
            value: settings.ecgDisplayScaleUv,
            minimum: 100,
            maximum: 30000,
            enabled: !settings.waveformAutoscaleV2,
            color: color,
            onChanged: (value) =>
                settings.update((s) => s.ecgDisplayScaleUv = value),
          ),
          _buildConfigScaleSlider(
            label: 'PPG full scale',
            unit: 'a.u.',
            value: settings.ppgDisplayScale,
            minimum: 5,
            maximum: 32768,
            enabled: !settings.waveformAutoscaleV2,
            color: color,
            onChanged: (value) =>
                settings.update((s) => s.ppgDisplayScale = value),
          ),
        ],
      ),
    );
  }

  Widget _buildConfigScaleSlider({
    required String label,
    required String unit,
    required double value,
    required double minimum,
    required double maximum,
    required bool enabled,
    required Color color,
    required ValueChanged<double> onChanged,
  }) {
    final normalized = (math.log(value / minimum) / math.log(maximum / minimum))
        .clamp(0.0, 1.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$label: ±${value.round()} $unit',
          style: TextStyle(color: enabled ? StudioColors.textPrimary : StudioColors.textMuted),
        ),
        Slider(
          value: normalized,
          activeColor: color,
          onChanged: enabled
              ? (position) => onChanged(
                  (minimum * math.pow(maximum / minimum, position)).toDouble(),
                )
              : null,
        ),
      ],
    );
  }

  Widget _buildSwitchTile({
    required String title,
    required String subtitle,
    required bool value,
    required Color color,
    required ValueChanged<bool> onChanged,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: StudioColors.card,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: StudioColors.border),
      ),
      child: SwitchListTile(
        title: Text(
          title,
          style: const TextStyle(color: StudioColors.textPrimary, fontSize: 14),
        ),
        subtitle: Text(
          subtitle,
          style: const TextStyle(color: StudioColors.textMuted, fontSize: 12),
        ),
        value: value,
        activeThumbColor: color,
        contentPadding: EdgeInsets.zero,
        onChanged: onChanged,
      ),
    );
  }

  Widget _buildTextField(
    String label,
    TextEditingController controller,
    Function(String) onChanged,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(color: StudioColors.textSecondary, fontSize: 13),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          style: const TextStyle(color: StudioColors.textPrimary),
          decoration: InputDecoration(
            filled: true,
            fillColor: StudioColors.card,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide.none,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: StudioColors.border),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: StudioColors.teal),
            ),
          ),
          onChanged: onChanged,
        ),
      ],
    );
  }
}
