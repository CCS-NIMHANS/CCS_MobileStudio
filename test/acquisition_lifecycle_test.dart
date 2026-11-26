import 'package:ccs_mobile_studio/core/eeg/acquisition_service.dart';
import 'package:ccs_mobile_studio/core/models/device_profile.dart';
import 'package:ccs_mobile_studio/core/services/settings_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'stream becomes ready only after a valid sample and disconnect is final',
    () async {
      final service = AcquisitionService()..addSyntheticDevice();
      final device = service.discoveredDevices.single;

      expect(service.isStreamReady, isFalse);
      final connected = await service.connect(device);
      expect(connected, isTrue);
      expect(service.isStreamReady, isTrue);
      expect(service.hasReceivedSamples, isTrue);

      // A duplicate request for the same device is idempotent.
      expect(await service.connect(device), isTrue);

      await service.disconnect();
      expect(service.currentState, AcquisitionState.disconnected);
      expect(service.isStreamReady, isFalse);
      expect(service.connectedDeviceId, isNull);
      expect(service.isRecovering, isFalse);

      service.dispose();
    },
  );

  test(
    'stopScan resets scanning state and switchActiveProfile updates labels live',
    () async {
      final settings = SettingsService();
      final customProfile = DeviceProfile(
        id: 'xamp_sleep',
        name: 'xAMP Sleep',
        transport: ConnectionTransport.bluetoothLe,
        protocol: DeviceProtocol.xampBinary,
        advertisedNamePattern: 'AXXSPU',
        isDefaultForHardware: true,
        streams: [
          SignalStreamProfile(
            id: 's1',
            name: 'PSG',
            signalType: SignalType.eeg,
            sampleRate: 250,
            channelLabels: const ['F3', 'C3', 'O1', 'Reog', 'Leog', 'EMG'],
          ),
        ],
      );
      settings.deviceProfiles.add(customProfile);

      final service = AcquisitionService()..updateSettings(settings);
      await service.stopScan();
      expect(service.currentState, AcquisitionState.disconnected);

      const bleDevice = EegDevice(
        name: 'AXXSPU00002',
        id: 'AA:BB:CC:DD:EE:FF',
        kind: DeviceKind.epidome,
        isBle: true,
        profileId: 'xamp_l10',
      );
      final matches = service.matchingProfilesFor(bleDevice);
      expect(matches.length, greaterThanOrEqualTo(2));
      expect(matches.first.id, 'xamp_sleep');

      service.addSyntheticDevice();
      final synth = service.discoveredDevices.single;
      expect(await service.connect(synth), isTrue);
      service.switchActiveProfile(customProfile);
      expect(service.connectedDeviceProfile?.id, 'xamp_sleep');
      expect(service.displayChannelLabels(6), [
        'F3',
        'C3',
        'O1',
        'Reog',
        'Leog',
        'EMG',
      ]);

      await service.disconnect();
      service.dispose();
    },
  );
}
