import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'native_speech_tracker.dart';

class DichoticAudioBundle {
  const DichoticAudioBundle({
    required this.stereoWavPath,
    required this.sampleRate,
    required this.durationSeconds,
    required this.envelopeRateHz,
    required this.leftEnvelope,
    required this.rightEnvelope,
    required this.leftLabel,
    required this.rightLabel,
  });

  final String stereoWavPath;
  final int sampleRate;
  final double durationSeconds;
  final double envelopeRateHz;
  final Float64List leftEnvelope;
  final Float64List rightEnvelope;
  final String leftLabel;
  final String rightLabel;
}

/// Loads two PCM WAV tracks (or synthesizes two distinct speech-modulated test
/// streams), combines Track A strictly into the **Left** channel and Track B
/// strictly into the **Right** channel of a stereo 16-bit WAV file, and extracts
/// time-aligned 50 Hz amplitude envelopes via Rust.
class StereoAudioMixer {
  static Future<DichoticAudioBundle> prepareDichoticAudio({
    String? leftWavPath,
    String? rightWavPath,
    double targetDurationSec = 40.0,
  }) async {
    const outSr = 22050;
    Float32List leftPcm;
    Float32List rightPcm;
    String leftLabel;
    String rightLabel;

    if (leftWavPath != null && leftWavPath.isNotEmpty) {
      final parsed = await _readWavMonoResampled(leftWavPath, outSr);
      leftPcm = parsed;
      leftLabel = leftWavPath.split(Platform.pathSeparator).last;
    } else {
      leftPcm = _synthesizeModulatedSpeech(
        sampleRate: outSr,
        durationSec: targetDurationSec,
        syllableHz: 3.4,
        baseF0: 125.0,
        seed: 11,
      );
      leftLabel = 'Built-in Voice A (3.4 Hz syllabic, 125 Hz)';
    }

    if (rightWavPath != null && rightWavPath.isNotEmpty) {
      final parsed = await _readWavMonoResampled(rightWavPath, outSr);
      rightPcm = parsed;
      rightLabel = rightWavPath.split(Platform.pathSeparator).last;
    } else {
      rightPcm = _synthesizeModulatedSpeech(
        sampleRate: outSr,
        durationSec: targetDurationSec,
        syllableHz: 5.1,
        baseF0: 215.0,
        seed: 29,
      );
      rightLabel = 'Built-in Voice B (5.1 Hz syllabic, 215 Hz)';
    }

    final desiredSamples = math.max(
      leftPcm.length,
      math.max(rightPcm.length, (targetDurationSec * outSr).round()),
    );
    final loopLeft = _tileOrTrim(leftPcm, desiredSamples);
    final loopRight = _tileOrTrim(rightPcm, desiredSamples);

    Directory tmp;
    try {
      tmp = await getTemporaryDirectory();
    } catch (_) {
      tmp = Directory.systemTemp;
    }
    final stereoFile = File('${tmp.path}/ccs_dichotic_stereo.wav');
    await stereoFile.writeAsBytes(
      _encodeStereoWav(loopLeft, loopRight, outSr),
      flush: true,
    );

    const envSr = 50.0;
    final envL = NativeSpeechTracker.instance.extractEnvelope(
      loopLeft,
      audioSampleRate: outSr.toDouble(),
      targetRate: envSr,
    );
    final envR = NativeSpeechTracker.instance.extractEnvelope(
      loopRight,
      audioSampleRate: outSr.toDouble(),
      targetRate: envSr,
    );

    return DichoticAudioBundle(
      stereoWavPath: stereoFile.path,
      sampleRate: outSr,
      durationSeconds: desiredSamples / outSr,
      envelopeRateHz: envSr,
      leftEnvelope: envL,
      rightEnvelope: envR,
      leftLabel: leftLabel,
      rightLabel: rightLabel,
    );
  }

  static Float32List _tileOrTrim(Float32List src, int length) {
    if (src.isEmpty) return Float32List(length);
    final out = Float32List(length);
    for (var i = 0; i < length; i++) {
      out[i] = src[i % src.length];
    }
    return out;
  }

  static Float32List _synthesizeModulatedSpeech({
    required int sampleRate,
    required double durationSec,
    required double syllableHz,
    required double baseF0,
    required int seed,
  }) {
    final n = (sampleRate * durationSec).round();
    final out = Float32List(n);
    final rng = math.Random(seed);
    var phasePitch = 0.0;
    var envNoise = 0.5;
    for (var i = 0; i < n; i++) {
      final t = i / sampleRate;
      if (i % 1400 == 0) {
        envNoise = 0.45 + 0.55 * rng.nextDouble();
      }
      final syllabic =
          (0.55 + 0.45 * math.sin(2.0 * math.pi * syllableHz * t)) *
          (0.65 + 0.35 * math.cos(2.0 * math.pi * (syllableHz * 0.43) * t + 0.7)) *
          envNoise;
      final f0 = baseF0 * (1.0 + 0.12 * math.sin(2.0 * math.pi * 1.1 * t));
      phasePitch += 2.0 * math.pi * f0 / sampleRate;
      final carrier =
          0.55 * math.sin(phasePitch) +
          0.30 * math.sin(2.0 * phasePitch) +
          0.15 * math.sin(3.0 * phasePitch);
      out[i] = (carrier * syllabic * 0.45).clamp(-0.95, 0.95).toDouble();
    }
    return out;
  }

  static Future<Float32List> _readWavMonoResampled(
    String path,
    int targetSr,
  ) async {
    final bytes = await File(path).readAsBytes();
    if (bytes.length < 44 ||
        String.fromCharCodes(bytes.sublist(0, 4)) != 'RIFF' ||
        String.fromCharCodes(bytes.sublist(8, 12)) != 'WAVE') {
      throw FormatException(
        'Unsupported audio format for "$path". Please select a 16-bit PCM .wav file.',
      );
    }
    final bd = ByteData.sublistView(bytes);
    var offset = 12;
    int channels = 1;
    int sampleRate = 44100;
    int bitsPerSample = 16;
    int dataOffset = -1;
    int dataSize = 0;
    while (offset + 8 <= bytes.length) {
      final id = String.fromCharCodes(bytes.sublist(offset, offset + 4));
      final size = bd.getUint32(offset + 4, Endian.little);
      if (id == 'fmt ' && offset + 24 <= bytes.length) {
        final audioFmt = bd.getUint16(offset + 8, Endian.little);
        if (audioFmt != 1) {
          throw const FormatException(
            'Only uncompressed PCM .wav files are supported.',
          );
        }
        channels = bd.getUint16(offset + 10, Endian.little).clamp(1, 8);
        sampleRate = bd.getUint32(offset + 12, Endian.little).clamp(8000, 192000);
        bitsPerSample = bd.getUint16(offset + 22, Endian.little);
      } else if (id == 'data') {
        dataOffset = offset + 8;
        dataSize = math.min(size, bytes.length - dataOffset);
        break;
      }
      offset += 8 + size + (size % 2);
    }
    if (dataOffset < 0 || bitsPerSample != 16) {
      throw const FormatException('Please select a standard 16-bit PCM .wav file.');
    }
    final frameBytes = channels * 2;
    final frames = dataSize ~/ frameBytes;
    final mono = Float32List(frames);
    for (var i = 0; i < frames; i++) {
      var sum = 0.0;
      for (var c = 0; c < channels; c++) {
        sum += bd.getInt16(dataOffset + i * frameBytes + c * 2, Endian.little) / 32768.0;
      }
      mono[i] = sum / channels;
    }
    if (sampleRate == targetSr) return mono;
    final outFrames = ((frames * targetSr) / sampleRate).round();
    final resampled = Float32List(outFrames);
    for (var i = 0; i < outFrames; i++) {
      final pos = (i * sampleRate) / targetSr;
      final lo = pos.floor().clamp(0, frames - 1);
      final hi = math.min(frames - 1, lo + 1);
      final frac = pos - lo;
      resampled[i] = mono[lo] * (1.0 - frac) + mono[hi] * frac;
    }
    return resampled;
  }

  static Uint8List _encodeStereoWav(
    Float32List left,
    Float32List right,
    int sampleRate,
  ) {
    final frames = math.min(left.length, right.length);
    final dataBytes = frames * 4;
    final bd = ByteData(44 + dataBytes);
    void ascii(int o, String s) {
      for (var i = 0; i < s.length; i++) {
        bd.setUint8(o + i, s.codeUnitAt(i));
      }
    }

    ascii(0, 'RIFF');
    bd.setUint32(4, 36 + dataBytes, Endian.little);
    ascii(8, 'WAVE');
    ascii(12, 'fmt ');
    bd.setUint32(16, 16, Endian.little);
    bd.setUint16(20, 1, Endian.little);
    bd.setUint16(22, 2, Endian.little); // stereo
    bd.setUint32(24, sampleRate, Endian.little);
    bd.setUint32(28, sampleRate * 4, Endian.little);
    bd.setUint16(32, 4, Endian.little);
    bd.setUint16(34, 16, Endian.little);
    ascii(36, 'data');
    bd.setUint32(40, dataBytes, Endian.little);

    for (var i = 0; i < frames; i++) {
      bd.setInt16(44 + i * 4, (left[i] * 32767).round().clamp(-32768, 32767), Endian.little);
      bd.setInt16(46 + i * 4, (right[i] * 32767).round().clamp(-32768, 32767), Endian.little);
    }
    return bd.buffer.asUint8List();
  }
}
