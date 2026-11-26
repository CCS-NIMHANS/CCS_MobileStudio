import 'dart:ffi';

import '../models/device_profile.dart';
import '../models/signal_stream_sample.dart';
import 'native_core.dart';
import 'orbit_packet_decoder.dart';

/// EDF recorder for one independently sampled configured stream.
class SignalStreamEdfRecorder {
  Pointer<Void> _writer = nullptr;
  late SignalStreamProfile _profile;
  int _samplesWritten = 0;
  String? _path;
  List<int> _enabledIndices = const [];
  List<OrbitEegDcBlocker> _electrophysiologyDcBlockers = const [];
  bool _dcBlockElectrophysiology = false;

  bool get isRecording => _writer != nullptr;
  String? get path => _path;
  SignalStreamProfile get profile => _profile;

  Future<String> start({
    required String path,
    required String subject,
    required SignalStreamProfile profile,
    bool dcBlockElectrophysiology = false,
  }) async {
    await stop();
    _enabledIndices = List<int>.generate(
      profile.channelCount,
      (index) => index,
    ).where((index) => profile.channelEnabled[index]).toList(growable: false);
    if (_enabledIndices.isEmpty) {
      throw ArgumentError('A signal stream needs at least one channel.');
    }
    _profile = profile;
    _dcBlockElectrophysiology = dcBlockElectrophysiology;
    _electrophysiologyDcBlockers = List.generate(
      profile.channelCount,
      (_) => OrbitEegDcBlocker(),
    );
    _path = path;
    _samplesWritten = 0;
    final labels = _enabledIndices
        .map((index) => profile.channelLabels[index])
        .toList(growable: false);
    final count = labels.length;
    String transducer(SignalType type) => switch (type) {
      SignalType.eeg => 'EEG electrode',
      SignalType.eog => 'EOG electrode',
      SignalType.emg => 'EMG electrode',
      SignalType.ecg => 'ECG electrode',
      SignalType.ppg => 'Optical PPG sensor',
      SignalType.fnirs => 'fNIRS optode',
      SignalType.marker => 'Event marker source',
      SignalType.auxiliary => 'Auxiliary sensor',
    };
    bool electrophysiology(SignalType type) =>
        type == SignalType.eeg ||
        type == SignalType.eog ||
        type == SignalType.emg ||
        type == SignalType.ecg;
    final enabledTypes = _enabledIndices
        .map((index) => profile.channelTypes[index])
        .toList(growable: false);
    _writer = NativeCore.instance.openEdfWithLabelsAtRate(
      path,
      subject,
      count,
      profile.sampleRate,
      labels,
      enabledTypes
          .map((type) => type == SignalType.ppg ? 'a.u.' : profile.unit)
          .toList(growable: false),
      enabledTypes
          .map(
            (type) => _dcBlockElectrophysiology && electrophysiology(type)
                ? 'HP:0.2Hz software DC block'
                : 'Configured stream',
          )
          .toList(growable: false),
      _enabledIndices
          .map((index) => transducer(profile.channelTypes[index]))
          .toList(growable: false),
      physicalMinimums: enabledTypes
          .map(
            (type) =>
                type == SignalType.ppg ? -32768.0 : profile.physicalMinimum,
          )
          .toList(growable: false),
      physicalMaximums: enabledTypes
          .map(
            (type) => type == SignalType.ppg ? 32767.0 : profile.physicalMaximum,
          )
          .toList(growable: false),
    );
    if (_writer == nullptr) {
      throw StateError('Could not open ${profile.name} EDF at $path');
    }
    return path;
  }

  void setMarker(int code, {String? label}) {
    if (_writer == nullptr) return;
    final text = (label != null && label.trim().isNotEmpty)
        ? '${label.trim()} ($code)'
        : 'Marker $code';
    final onsetSec = _profile.sampleRate > 0
        ? _samplesWritten / _profile.sampleRate
        : 0.0;
    NativeCore.instance.pushEdfAnnotation(_writer, onsetSec, 0.0, text);
  }

  void push(SignalStreamSample sample) {
    if (_writer == nullptr || sample.streamId != _profile.id) return;
    final values = List<double>.filled(_enabledIndices.length, 0);
    for (var output = 0; output < _enabledIndices.length; output++) {
      final input = _enabledIndices[output];
      if (input < sample.channels.length) {
        var value = sample.channels[input];
        final type = input < _profile.channelTypes.length
            ? _profile.channelTypes[input]
            : SignalType.eeg;
        final electrophysiology =
            type == SignalType.eeg ||
            type == SignalType.eog ||
            type == SignalType.emg ||
            type == SignalType.ecg;
        if (_dcBlockElectrophysiology &&
            electrophysiology &&
            input < _electrophysiologyDcBlockers.length) {
          value = _electrophysiologyDcBlockers[input].process(value);
        }
        values[output] = value;
      }
    }
    NativeCore.instance.pushEdfSample(_writer, values);
    _samplesWritten++;
  }

  Future<String?> stop() async {
    if (_writer == nullptr) return _path;
    final writer = _writer;
    _writer = nullptr;
    NativeCore.instance.closeEdf(writer);
    return _path;
  }
}
