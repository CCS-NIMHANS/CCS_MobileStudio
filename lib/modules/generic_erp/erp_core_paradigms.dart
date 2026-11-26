import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

/// Identifiers for the 6 standardized ERP CORE paradigms (Kappenman et al., 2021).
enum ErpCoreParadigmId {
  n170,
  mmn,
  n2pc,
  n400,
  p3b,
  flankers,
}

class ErpCoreParadigmSpec {
  const ErpCoreParadigmSpec({
    required this.id,
    required this.shortName,
    required this.title,
    required this.component,
    required this.quickTrials,
    required this.fullTrials,
    required this.stimDurationMs,
    required this.minIsiMs,
    required this.maxIsiMs,
    required this.isAuditory,
    required this.requiresResponse,
    required this.leftResponseLabel,
    required this.rightResponseLabel,
    required this.instructions,
  });

  final ErpCoreParadigmId id;
  final String shortName;
  final String title;
  final String component;
  final int quickTrials;
  final int fullTrials;
  final int stimDurationMs;
  final int minIsiMs;
  final int maxIsiMs;
  final bool isAuditory;
  final bool requiresResponse;
  final String leftResponseLabel;
  final String rightResponseLabel;
  final String instructions;
}

const List<ErpCoreParadigmSpec> kErpCoreParadigms = [
  ErpCoreParadigmSpec(
    id: ErpCoreParadigmId.n170,
    shortName: 'ERP CORE: N170',
    title: 'N170 Face Perception',
    component: 'N170',
    quickTrials: 40,
    fullTrials: 320,
    stimDurationMs: 300,
    minIsiMs: 1100,
    maxIsiMs: 1300,
    isAuditory: false,
    requiresResponse: true,
    leftResponseLabel: 'Intact [F]',
    rightResponseLabel: 'Scrambled [J]',
    instructions:
        'Classify each stimulus as an Intact object (Face/Car) or Scrambled texture while fixating centrally.',
  ),
  ErpCoreParadigmSpec(
    id: ErpCoreParadigmId.mmn,
    shortName: 'ERP CORE: MMN',
    title: 'MMN Passive Auditory Oddball',
    component: 'MMN',
    quickTrials: 80,
    fullTrials: 1000,
    stimDurationMs: 100,
    minIsiMs: 350,
    maxIsiMs: 450,
    isAuditory: true,
    requiresResponse: false,
    leftResponseLabel: '—',
    rightResponseLabel: '—',
    instructions:
        'Passive auditory oddball (80% 80 dB standard vs. 20% 70 dB deviant 1000 Hz tones). Sit quietly while viewing fixation.',
  ),
  ErpCoreParadigmSpec(
    id: ErpCoreParadigmId.n2pc,
    shortName: 'ERP CORE: N2pc',
    title: 'N2pc Visual Search',
    component: 'N2pc',
    quickTrials: 48,
    fullTrials: 320,
    stimDurationMs: 500,
    minIsiMs: 900,
    maxIsiMs: 1100,
    isAuditory: false,
    requiresResponse: true,
    leftResponseLabel: 'Top Gap [F]',
    rightResponseLabel: 'Bottom Gap [J]',
    instructions:
        'Keep eyes on center cross. Locate the PINK square and report whether its gap is on the TOP [F] or BOTTOM [J].',
  ),
  ErpCoreParadigmSpec(
    id: ErpCoreParadigmId.n400,
    shortName: 'ERP CORE: N400',
    title: 'N400 Semantic Word Pairs',
    component: 'N400',
    quickTrials: 40,
    fullTrials: 120,
    stimDurationMs: 200,
    minIsiMs: 1400,
    maxIsiMs: 1600,
    isAuditory: false,
    requiresResponse: true,
    leftResponseLabel: 'Related [F]',
    rightResponseLabel: 'Unrelated [J]',
    instructions:
        'Read the red Prime word followed by the green Target word. Decide if Target is Related [F] or Unrelated [J] in meaning.',
  ),
  ErpCoreParadigmSpec(
    id: ErpCoreParadigmId.p3b,
    shortName: 'ERP CORE: P3b',
    title: 'P3b Active Visual Oddball',
    component: 'P3b',
    quickTrials: 50,
    fullTrials: 200,
    stimDurationMs: 200,
    minIsiMs: 1200,
    maxIsiMs: 1400,
    isAuditory: false,
    requiresResponse: true,
    leftResponseLabel: 'Target "B" [F]',
    rightResponseLabel: 'Other Letter [J]',
    instructions:
        'Letters A–E appear (20% Target "B", 80% A/C/D/E distractors). Press Target [F] for "B" and Other [J] for all other letters.',
  ),
  ErpCoreParadigmSpec(
    id: ErpCoreParadigmId.flankers,
    shortName: 'ERP CORE: ERN / LRP',
    title: 'ERN & LRP Arrow Flankers',
    component: 'ERN',
    quickTrials: 60,
    fullTrials: 400,
    stimDurationMs: 200,
    minIsiMs: 1200,
    maxIsiMs: 1400,
    isAuditory: false,
    requiresResponse: true,
    leftResponseLabel: 'Left < [F]',
    rightResponseLabel: 'Right > [J]',
    instructions:
        'Respond quickly to the direction of the CENTRAL arrow (< = Left [F], > = Right [J]) while ignoring flanker arrows.',
  ),
];

ErpCoreParadigmSpec? erpCoreSpecByName(String name) {
  for (final spec in kErpCoreParadigms) {
    if (spec.shortName == name) return spec;
  }
  return null;
}

class ErpCoreTrial {
  const ErpCoreTrial({
    required this.conditionLabel,
    required this.avgClass,
    required this.markerCode,
    required this.expectedLeftResponse,
    this.n170Kind = N170Kind.face,
    this.targetOnLeft = true,
    this.targetGapTop = true,
    this.primeWord = '',
    this.targetWord = '',
    this.displayText = '',
    this.isDeviantTone = false,
    this.seed = 0,
  });

  final String conditionLabel;
  final String avgClass;
  final int markerCode;
  final bool expectedLeftResponse;
  final N170Kind n170Kind;
  final bool targetOnLeft;
  final bool targetGapTop;
  final String primeWord;
  final String targetWord;
  final String displayText;
  final bool isDeviantTone;
  final int seed;
}

enum N170Kind { face, car, scrambledFace, scrambledCar }

const List<(String, String)> _n400RelatedPairs = [
  ('DOCTOR', 'NURSE'),
  ('BREAD', 'BUTTER'),
  ('OCEAN', 'WATER'),
  ('WINTER', 'SNOW'),
  ('LOCK', 'KEY'),
  ('KING', 'QUEEN'),
  ('SALT', 'PEPPER'),
  ('THUNDER', 'LIGHTNING'),
  ('TABLE', 'CHAIR'),
  ('NIGHT', 'MOON'),
  ('FORK', 'SPOON'),
  ('HAMMER', 'NAIL'),
  ('DOG', 'BARK'),
  ('BIRD', 'WING'),
  ('TEACHER', 'SCHOOL'),
  ('COFFEE', 'CUP'),
  ('SHOE', 'SOCK'),
  ('TRAIN', 'TRACK'),
  ('SUN', 'HEAT'),
  ('PAPER', 'PEN'),
  ('RAIN', 'UMBRELLA'),
  ('FOREST', 'TREE'),
  ('MUSIC', 'SONG'),
  ('HEART', 'BLOOD'),
];

const List<(String, String)> _n400UnrelatedPairs = [
  ('DOCTOR', 'CLOUD'),
  ('BREAD', 'HAMMER'),
  ('OCEAN', 'PENCIL'),
  ('WINTER', 'SPOON'),
  ('LOCK', 'CARROT'),
  ('KING', 'BOTTLE'),
  ('SALT', 'WINDOW'),
  ('THUNDER', 'CARPET'),
  ('TABLE', 'WHALE'),
  ('NIGHT', 'LADDER'),
  ('FORK', 'PILLOW'),
  ('HAMMER', 'TOMATO'),
  ('DOG', 'LANTERN'),
  ('BIRD', 'ANCHOR'),
  ('TEACHER', 'PEPPER'),
  ('COFFEE', 'GLOVE'),
  ('SHOE', 'PLANET'),
  ('TRAIN', 'MIRROR'),
  ('SUN', 'CABINET'),
  ('PAPER', 'ORANGE'),
  ('RAIN', 'BICYCLE'),
  ('FOREST', 'BUTTON'),
  ('MUSIC', 'BRIDGE'),
  ('HEART', 'SCISSORS'),
];

/// Generates pseudorandomized trial sequences matching ERP CORE specifications.
List<ErpCoreTrial> buildErpCoreTrialPlan(
  ErpCoreParadigmId id,
  int totalTrials, {
  math.Random? rng,
}) {
  final random = rng ?? math.Random();
  final trials = <ErpCoreTrial>[];

  switch (id) {
    case ErpCoreParadigmId.n170:
      for (var i = 0; i < totalTrials; i++) {
        final kind = N170Kind.values[i % 4];
        final (cond, avg, code, intact) = switch (kind) {
          N170Kind.face => ('Face', 'Face', 101, true),
          N170Kind.car => ('Car', 'Car', 102, true),
          N170Kind.scrambledFace => ('Scrambled_Face', 'Scrambled', 103, false),
          N170Kind.scrambledCar => ('Scrambled_Car', 'Scrambled', 104, false),
        };
        trials.add(
          ErpCoreTrial(
            conditionLabel: cond,
            avgClass: avg,
            markerCode: code,
            expectedLeftResponse: intact,
            n170Kind: kind,
            seed: i + 1,
          ),
        );
      }
      trials.shuffle(random);
      return trials;

    case ErpCoreParadigmId.mmn:
      final devCount = (totalTrials * 0.20).round().clamp(1, totalTrials - 1);
      for (var i = 0; i < totalTrials; i++) {
        final isDev = i < devCount;
        trials.add(
          ErpCoreTrial(
            conditionLabel: isDev ? 'Deviant_70dB' : 'Standard_80dB',
            avgClass: isDev ? 'Deviant' : 'Standard',
            markerCode: isDev ? 202 : 201,
            expectedLeftResponse: true,
            isDeviantTone: isDev,
          ),
        );
      }
      trials.shuffle(random);
      // Avoid back-to-back deviants when possible (ERP CORE MMN constraint).
      for (var i = 1; i < trials.length; i++) {
        if (trials[i].isDeviantTone && trials[i - 1].isDeviantTone) {
          final swapIdx = trials.indexWhere(
            (t) => !t.isDeviantTone,
            (i + 1) % trials.length,
          );
          if (swapIdx >= 0) {
            final tmp = trials[i];
            trials[i] = trials[swapIdx];
            trials[swapIdx] = tmp;
          }
        }
      }
      return trials;

    case ErpCoreParadigmId.n2pc:
      for (var i = 0; i < totalTrials; i++) {
        final left = (i % 2) == 0;
        final top = ((i ~/ 2) % 2) == 0;
        trials.add(
          ErpCoreTrial(
            conditionLabel: left ? 'Target_Left' : 'Target_Right',
            avgClass: left ? 'Target Left' : 'Target Right',
            markerCode: left ? 301 : 302,
            expectedLeftResponse: top,
            targetOnLeft: left,
            targetGapTop: top,
            seed: i * 17 + 3,
          ),
        );
      }
      trials.shuffle(random);
      return trials;

    case ErpCoreParadigmId.n400:
      for (var i = 0; i < totalTrials; i++) {
        final related = (i % 2) == 0;
        final pair = related
            ? _n400RelatedPairs[(i ~/ 2) % _n400RelatedPairs.length]
            : _n400UnrelatedPairs[(i ~/ 2) % _n400UnrelatedPairs.length];
        trials.add(
          ErpCoreTrial(
            conditionLabel: related ? 'Related' : 'Unrelated',
            avgClass: related ? 'Related' : 'Unrelated',
            markerCode: related ? 401 : 402,
            expectedLeftResponse: related,
            primeWord: pair.$1,
            targetWord: pair.$2,
          ),
        );
      }
      trials.shuffle(random);
      return trials;

    case ErpCoreParadigmId.p3b:
      const distractors = ['A', 'C', 'D', 'E'];
      final targetCount = (totalTrials * 0.20).round().clamp(1, totalTrials - 1);
      for (var i = 0; i < totalTrials; i++) {
        final isTarget = i < targetCount;
        final letter = isTarget ? 'B' : distractors[i % distractors.length];
        trials.add(
          ErpCoreTrial(
            conditionLabel: isTarget ? 'Target_B' : 'NonTarget_$letter',
            avgClass: isTarget ? 'Target' : 'Non-Target',
            markerCode: isTarget ? 501 : 502,
            expectedLeftResponse: isTarget,
            displayText: letter,
          ),
        );
      }
      trials.shuffle(random);
      return trials;

    case ErpCoreParadigmId.flankers:
      for (var i = 0; i < totalTrials; i++) {
        final kind = i % 4;
        final (text, cond, avg, code, isLeft) = switch (kind) {
          0 => ('<<<<<', 'Congruent_Left', 'Left', 601, true),
          1 => ('>>>>>', 'Congruent_Right', 'Right', 602, false),
          2 => ('>><>>', 'Incongruent_Left', 'Left', 603, true),
          _ => ('<<><<', 'Incongruent_Right', 'Right', 604, false),
        };
        trials.add(
          ErpCoreTrial(
            conditionLabel: cond,
            avgClass: avg,
            markerCode: code,
            expectedLeftResponse: isLeft,
            displayText: text,
          ),
        );
      }
      trials.shuffle(random);
      return trials;
  }
}

/// Generates 16-bit PCM mono WAV files for the ERP CORE MMN 80 dB / 70 dB tones.
Future<({String standardPath, String deviantPath})> ensureMmnToneFiles() async {
  Directory dir;
  try {
    dir = await getTemporaryDirectory();
  } catch (_) {
    dir = Directory.systemTemp;
  }
  final stdFile = File('${dir.path}/erp_core_mmn_std_80db.wav');
  final devFile = File('${dir.path}/erp_core_mmn_dev_70db.wav');
  if (!await stdFile.exists()) {
    await stdFile.writeAsBytes(_buildToneWavBytes(amplitude: 0.72), flush: true);
  }
  if (!await devFile.exists()) {
    await devFile.writeAsBytes(_buildToneWavBytes(amplitude: 0.22), flush: true);
  }
  return (standardPath: stdFile.path, deviantPath: devFile.path);
}

Uint8List _buildToneWavBytes({
  required double amplitude,
  int sampleRate = 44100,
  double freqHz = 1000.0,
  double durationMs = 100.0,
  double rampMs = 5.0,
}) {
  final nSamples = (sampleRate * durationMs / 1000.0).round();
  final rampSamples = math.max(1, (sampleRate * rampMs / 1000.0).round());
  final pcmBytes = nSamples * 2;
  final bd = ByteData(44 + pcmBytes);

  void writeAscii(int offset, String s) {
    for (var i = 0; i < s.length; i++) {
      bd.setUint8(offset + i, s.codeUnitAt(i));
    }
  }

  writeAscii(0, 'RIFF');
  bd.setUint32(4, 36 + pcmBytes, Endian.little);
  writeAscii(8, 'WAVE');
  writeAscii(12, 'fmt ');
  bd.setUint32(16, 16, Endian.little);
  bd.setUint16(20, 1, Endian.little);
  bd.setUint16(22, 1, Endian.little);
  bd.setUint32(24, sampleRate, Endian.little);
  bd.setUint32(28, sampleRate * 2, Endian.little);
  bd.setUint16(32, 2, Endian.little);
  bd.setUint16(34, 16, Endian.little);
  writeAscii(36, 'data');
  bd.setUint32(40, pcmBytes, Endian.little);

  for (var i = 0; i < nSamples; i++) {
    var env = 1.0;
    if (i < rampSamples) {
      env = 0.5 - 0.5 * math.cos(math.pi * i / rampSamples);
    } else if (i >= nSamples - rampSamples) {
      final tail = nSamples - 1 - i;
      env = 0.5 - 0.5 * math.cos(math.pi * tail / rampSamples);
    }
    final s =
        math.sin(2.0 * math.pi * freqHz * i / sampleRate) * env * amplitude;
    bd.setInt16(44 + i * 2, (s * 32767).round().clamp(-32768, 32767), Endian.little);
  }
  return bd.buffer.asUint8List();
}

/// Vector renderer for N170 Face, Car, and Scrambled control stimuli.
class N170StimulusPainter extends CustomPainter {
  const N170StimulusPainter({required this.kind, this.seed = 1});

  final N170Kind kind;
  final int seed;

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width * 0.5;
    final cy = size.height * 0.5;
    final r = math.min(size.width, size.height) * 0.36;

    if (kind == N170Kind.scrambledFace || kind == N170Kind.scrambledCar) {
      final rng = math.Random(seed * 97 + (kind == N170Kind.scrambledFace ? 1 : 2));
      const cols = 10;
      final cell = (r * 1.9) / cols;
      final left = cx - (cols * cell) * 0.5;
      final top = cy - (cols * cell) * 0.5;
      for (var gy = 0; gy < cols; gy++) {
        for (var gx = 0; gx < cols; gx++) {
          final lum = 40 + rng.nextInt(190);
          final paint = Paint()..color = Color.fromARGB(255, lum, lum, lum);
          canvas.drawRect(
            Rect.fromLTWH(left + gx * cell, top + gy * cell, cell - 0.5, cell - 0.5),
            paint,
          );
        }
      }
      return;
    }

    final outline = Paint()
      ..color = Colors.white
      ..strokeWidth = 2.6
      ..style = PaintingStyle.stroke;
    final fill = Paint()..color = const Color(0xFFD1D5DB);
    final dark = Paint()..color = const Color(0xFF1F2937);

    if (kind == N170Kind.face) {
      final oval = Rect.fromCenter(center: Offset(cx, cy), width: r * 1.45, height: r * 1.85);
      canvas.drawOval(oval, fill);
      canvas.drawOval(oval, outline);
      // Eyes
      canvas.drawOval(
        Rect.fromCenter(center: Offset(cx - r * 0.32, cy - r * 0.2), width: r * 0.28, height: r * 0.16),
        dark,
      );
      canvas.drawOval(
        Rect.fromCenter(center: Offset(cx + r * 0.32, cy - r * 0.2), width: r * 0.28, height: r * 0.16),
        dark,
      );
      // Nose
      canvas.drawLine(
        Offset(cx, cy - r * 0.08),
        Offset(cx - r * 0.06, cy + r * 0.22),
        Paint()
          ..color = const Color(0xFF374151)
          ..strokeWidth = 2.4,
      );
      // Mouth
      canvas.drawArc(
        Rect.fromCenter(center: Offset(cx, cy + r * 0.36), width: r * 0.55, height: r * 0.25),
        0.15,
        math.pi - 0.3,
        false,
        Paint()
          ..color = const Color(0xFF1F2937)
          ..strokeWidth = 3.0
          ..style = PaintingStyle.stroke,
      );
    } else {
      // Front-view Car silhouette
      final roof = RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(cx, cy - r * 0.22), width: r * 1.15, height: r * 0.65),
        const Radius.circular(14),
      );
      final body = RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(cx, cy + r * 0.18), width: r * 1.75, height: r * 0.62),
        const Radius.circular(12),
      );
      canvas.drawRRect(roof, fill);
      canvas.drawRRect(roof, outline);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset(cx, cy - r * 0.22), width: r * 0.92, height: r * 0.42),
          const Radius.circular(8),
        ),
        dark,
      );
      canvas.drawRRect(body, fill);
      canvas.drawRRect(body, outline);
      // Grille & headlights
      canvas.drawRect(
        Rect.fromCenter(center: Offset(cx, cy + r * 0.22), width: r * 0.65, height: r * 0.24),
        dark,
      );
      canvas.drawCircle(Offset(cx - r * 0.62, cy + r * 0.16), r * 0.13, Paint()..color = Colors.amberAccent);
      canvas.drawCircle(Offset(cx + r * 0.62, cy + r * 0.16), r * 0.13, Paint()..color = Colors.amberAccent);
      // Tires
      canvas.drawRect(
        Rect.fromLTWH(cx - r * 0.80, cy + r * 0.46, r * 0.28, r * 0.20),
        dark,
      );
      canvas.drawRect(
        Rect.fromLTWH(cx + r * 0.52, cy + r * 0.46, r * 0.28, r * 0.20),
        dark,
      );
    }
  }

  @override
  bool shouldRepaint(covariant N170StimulusPainter oldDelegate) =>
      oldDelegate.kind != kind || oldDelegate.seed != seed;
}

/// Vector renderer for ERP CORE N2pc bilateral 12-item visual search array.
class N2pcSearchPainter extends CustomPainter {
  const N2pcSearchPainter({
    required this.targetOnLeft,
    required this.targetGapTop,
    required this.seed,
  });

  final bool targetOnLeft;
  final bool targetGapTop;
  final int seed;

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width * 0.5;
    final cy = size.height * 0.5;
    final fixPaint = Paint()
      ..color = Colors.white70
      ..strokeWidth = 2.0;
    canvas.drawLine(Offset(cx - 7, cy), Offset(cx + 7, cy), fixPaint);
    canvas.drawLine(Offset(cx, cy - 7), Offset(cx, cy + 7), fixPaint);

    final rng = math.Random(seed);
    final radiusX = math.min(size.width * 0.34, 150.0);
    final radiusY = math.min(size.height * 0.36, 68.0);
    const squareSize = 18.0;
    final targetIdx = rng.nextInt(6);

    void drawHemifield(bool isLeft) {
      final hasTarget = isLeft == targetOnLeft;
      for (var k = 0; k < 6; k++) {
        final angle = -math.pi * 0.38 + (k / 5.0) * math.pi * 0.76;
        final dx = math.cos(angle) * radiusX * (isLeft ? -1 : 1);
        final dy = math.sin(angle) * radiusY;
        final center = Offset(cx + dx, cy + dy);
        final isTarget = hasTarget && k == targetIdx;
        final color = isTarget
            ? const Color(0xFFF472B6) // Target pink
            : (k % 2 == 0 ? const Color(0xFF38BDF8) : const Color(0xFF94A3B8));
        final gapSide = isTarget
            ? (targetGapTop ? 0 : 1) // 0=top, 1=bottom
            : (rng.nextBool() ? 2 : 3); // distractors have left/right gaps
        _drawLandoltSquare(canvas, center, squareSize, color, gapSide);
      }
    }

    drawHemifield(true);
    drawHemifield(false);
  }

  void _drawLandoltSquare(
    Canvas canvas,
    Offset center,
    double s,
    Color color,
    int gapSide,
  ) {
    final half = s * 0.5;
    final left = center.dx - half;
    final right = center.dx + half;
    final top = center.dy - half;
    final bottom = center.dy + half;
    final gap = s * 0.34;
    final p = Paint()
      ..color = color
      ..strokeWidth = 3.0
      ..strokeCap = StrokeCap.square;

    // Top edge (0)
    if (gapSide == 0) {
      canvas.drawLine(Offset(left, top), Offset(center.dx - gap * 0.5, top), p);
      canvas.drawLine(Offset(center.dx + gap * 0.5, top), Offset(right, top), p);
    } else {
      canvas.drawLine(Offset(left, top), Offset(right, top), p);
    }
    // Bottom edge (1)
    if (gapSide == 1) {
      canvas.drawLine(Offset(left, bottom), Offset(center.dx - gap * 0.5, bottom), p);
      canvas.drawLine(Offset(center.dx + gap * 0.5, bottom), Offset(right, bottom), p);
    } else {
      canvas.drawLine(Offset(left, bottom), Offset(right, bottom), p);
    }
    // Left edge (2)
    if (gapSide == 2) {
      canvas.drawLine(Offset(left, top), Offset(left, center.dy - gap * 0.5), p);
      canvas.drawLine(Offset(left, center.dy + gap * 0.5), Offset(left, bottom), p);
    } else {
      canvas.drawLine(Offset(left, top), Offset(left, bottom), p);
    }
    // Right edge (3)
    if (gapSide == 3) {
      canvas.drawLine(Offset(right, top), Offset(right, center.dy - gap * 0.5), p);
      canvas.drawLine(Offset(right, center.dy + gap * 0.5), Offset(right, bottom), p);
    } else {
      canvas.drawLine(Offset(right, top), Offset(right, bottom), p);
    }
  }

  @override
  bool shouldRepaint(covariant N2pcSearchPainter oldDelegate) =>
      oldDelegate.targetOnLeft != targetOnLeft ||
      oldDelegate.targetGapTop != targetGapTop ||
      oldDelegate.seed != seed;
}
