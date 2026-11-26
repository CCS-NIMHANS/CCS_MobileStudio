import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ccs_mobile_studio/core/models/module_type.dart';
import 'package:ccs_mobile_studio/modules/speech_tracking/native_speech_tracker.dart';
import 'package:ccs_mobile_studio/modules/speech_tracking/stereo_audio_mixer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ModuleType includes speechTracking with SPEECH tag', () {
    expect(ModuleType.speechTracking.fileTag, 'SPEECH');
    expect(ModuleType.fromKey('speech'), ModuleType.speechTracking);
  });

  test('StereoAudioMixer synthesizes stereo WAV and aligned 50Hz envelopes', () async {
    final bundle = await StereoAudioMixer.prepareDichoticAudio(
      targetDurationSec: 4.0,
    );
    final file = File(bundle.stereoWavPath);
    expect(await file.exists(), isTrue);
    final bytes = await file.readAsBytes();
    expect(String.fromCharCodes(bytes.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(bytes.sublist(8, 12)), 'WAVE');
    expect(bundle.leftEnvelope.length, greaterThan(150));
    expect(bundle.rightEnvelope.length, greaterThan(150));
    await file.delete();
  });

  test('Speech tracker decodes attended side even with 2 channels', () {
    const nEnv = 1000;
    const eegSr = 250.0;
    const nEeg = 5000;
    final envL = Float64List(nEnv);
    final envR = Float64List(nEnv);
    for (var i = 0; i < nEnv; i++) {
      final t = i / 50.0;
      envL[i] = math.sin(2.0 * math.pi * 3.1 * t);
      envR[i] = math.sin(2.0 * math.pi * 5.2 * t);
    }
    final ch0 = List<double>.generate(nEeg, (s) {
      final t = math.max(0, s - 30) / eegSr;
      return 12.0 * math.sin(2.0 * math.pi * 3.1 * t) +
          10.0 * math.sin(2.0 * math.pi * 10.5 * (s / eegSr));
    });
    final ch1 = List<double>.generate(nEeg, (s) {
      final t = math.max(0, s - 30) / eegSr;
      return -8.0 * math.sin(2.0 * math.pi * 3.1 * t) -
          7.0 * math.sin(2.0 * math.pi * 10.5 * (s / eegSr));
    });

    final score = NativeSpeechTracker.instance.decodeBlock(
      eegChannels: [ch0, ch1],
      eegSampleRate: eegSr,
      envLeft: envL,
      envRight: envR,
      multiFeature: true,
    );
    expect(score.predictedSide, 0);
    expect(score.rLeft, greaterThan(score.rRight));
  });
}
