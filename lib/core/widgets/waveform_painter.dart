import 'dart:math';
import 'package:flutter/material.dart';

import '../eeg/ring_buffer.dart';
import '../models/stream_marker.dart';
import '../theme/studio_theme.dart';

/// Custom painter for multi-channel EEG/biosignal waveforms.
/// Supports decoupled [repaint] Listenable, zero-shift [Float64RingBuffer],
/// min-max pixel-column decimation, and weighted prominent lanes.
class WaveformPainter extends CustomPainter {
  const WaveformPainter({
    required this.channels,
    required this.visibleChannels,
    required this.stacked,
    required this.selectedChannel,
    required this.gain,
    required this.sampleRate,
    required this.durationSeconds,
    required this.autoscale,
    this.ringBuffers,
    this.channelLabels,
    this.channelScaleFactors,
    this.channelColors,
    this.channelWeights,
    this.showInlineLabels = true,
    this.markers = const [],
    this.traceColor,
    this.strokeWidth = 1.4,
    this.now,
    this.isPageMode = false,
    this.pageStartedAt,
    super.repaint,
  });

  final List<List<double>> channels;
  final List<Float64RingBuffer>? ringBuffers;
  final List<bool> visibleChannels;
  final bool stacked;
  final int selectedChannel;
  final double gain;
  final double sampleRate;
  final int durationSeconds;
  final bool autoscale;
  final List<String>? channelLabels;
  final List<double>? channelScaleFactors;
  final List<Color>? channelColors;
  final List<double>? channelWeights;
  final bool showInlineLabels;
  final List<StreamMarker> markers;
  final Color? traceColor;
  final double strokeWidth;
  final DateTime? now;
  final bool isPageMode;
  final DateTime? pageStartedAt;

  static const colors = [
    Color(0xFF111827), // Clinical Ink
    Color(0xFF1D4ED8), // Deep Blue (EOG/frontal)
    Color(0xFF0F766E), // Deep Teal
    Color(0xFFB45309), // Burnt Amber
    Color(0xFF6D28D9), // Deep Violet
    Color(0xFF15803D), // Forest Emerald
    Color(0xFFB91C1C), // Crimson
    Color(0xFF0369A1), // Cerulean
  ];

  static double canvasHeightForChannels({
    required int channelCount,
    required double availableHeight,
    double minimumLaneHeight = 64.0,
    double extraProminentWeight = 0.0,
  }) {
    final effectiveCount = max(1.0, channelCount + extraProminentWeight);
    return max(availableHeight, effectiveCount * minimumLaneHeight);
  }

  static List<double> laneHeights({
    required List<int> visibleIndices,
    required double totalHeight,
    List<double>? channelWeights,
  }) {
    if (visibleIndices.isEmpty) return const [];
    final weights = visibleIndices
        .map(
          (idx) => (channelWeights != null && idx < channelWeights.length)
              ? max(0.5, channelWeights[idx])
              : 1.0,
        )
        .toList(growable: false);
    final totalWeight = weights.reduce((a, b) => a + b);
    return weights
        .map((w) => totalHeight * (w / totalWeight))
        .toList(growable: false);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final gridPaint = Paint()
      ..color = StudioColors.border.withValues(alpha: 0.45)
      ..strokeWidth = 0.8;
    final baselinePaint = Paint()
      ..color = StudioColors.border.withValues(alpha: 0.22)
      ..strokeWidth = 0.6;
    final tracePaint = Paint()
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round;

    final secDivisions = durationSeconds >= 10 ? 10 : max(2, durationSeconds);
    for (var i = 1; i < secDivisions; i++) {
      final x = size.width * i / secDivisions;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridPaint);
    }

    final totalCh = ringBuffers != null ? ringBuffers!.length : channels.length;
    final indices = stacked
        ? [
            for (var i = 0; i < totalCh; i++)
              if (i < visibleChannels.length && visibleChannels[i]) i,
          ]
        : [selectedChannel.clamp(0, max(0, totalCh - 1)).toInt()];

    if (indices.isEmpty) return;

    final heights = laneHeights(
      visibleIndices: indices,
      totalHeight: size.height,
      channelWeights: stacked ? channelWeights : null,
    );
    final points = max(2, (sampleRate * durationSeconds).round());

    var yCursor = 0.0;
    for (var lane = 0; lane < indices.length; lane++) {
      final channel = indices[lane];
      final laneHeight = heights[lane];
      final centerY = yCursor + laneHeight * 0.5;

      canvas.drawLine(
        Offset(0, centerY),
        Offset(size.width, centerY),
        baselinePaint,
      );
      if (lane < indices.length - 1) {
        canvas.drawLine(
          Offset(0, yCursor + laneHeight),
          Offset(size.width, yCursor + laneHeight),
          gridPaint,
        );
      }

      if (channel < totalCh) {
        final ring = ringBuffers != null ? ringBuffers![channel] : null;
        final list = ring == null ? channels[channel] : null;
        final dataLen = ring != null ? ring.length : list!.length;
        if (dataLen >= 2) {
          final start = max(0, dataLen - points);
          final visibleCount = dataLen - start;

          var sum = 0.0;
          var maxAbsDev = 0.0;
          if (ring != null) {
            for (var i = 0; i < visibleCount; i++) {
              sum += ring[start + i];
            }
          } else {
            for (var i = 0; i < visibleCount; i++) {
              sum += list![start + i];
            }
          }
          final mean = sum / visibleCount;

          final double scaleFactor;
          if (channelScaleFactors != null &&
              channel < channelScaleFactors!.length) {
            scaleFactor = max(0.000001, channelScaleFactors![channel]);
          } else if (autoscale) {
            if (ring != null) {
              for (var i = 0; i < visibleCount; i++) {
                final d = (ring[start + i] - mean).abs();
                if (d > maxAbsDev) maxAbsDev = d;
              }
            } else {
              for (var i = 0; i < visibleCount; i++) {
                final d = (list![start + i] - mean).abs();
                if (d > maxAbsDev) maxAbsDev = d;
              }
            }
            scaleFactor = max(20.0, maxAbsDev);
          } else {
            scaleFactor = 150.0;
          }

          final yScale = (laneHeight * 0.44 * gain) / scaleFactor;
          final minY = yCursor + 2.0;
          final maxY = yCursor + laneHeight - 2.0;
          final xDiv = max(1, points - 1);
          final path = Path();

          // Min-max pixel-column decimation keeps peaks intact at a fraction
          // of path vertex count when visibleCount exceeds 2x pixel width.
          final maxCols = size.width.floor().clamp(64, 1400);
          if (visibleCount <= maxCols * 2) {
            for (var i = 0; i < visibleCount; i++) {
              final v = ring != null ? ring[start + i] : list![start + i];
              final x = i * size.width / xDiv;
              final y = (centerY - (v - mean) * yScale).clamp(minY, maxY);
              if (i == 0) {
                path.moveTo(x, y);
              } else {
                path.lineTo(x, y);
              }
            }
          } else {
            final usedWidth = size.width * (visibleCount / xDiv);
            final cols = max(32, (maxCols * (visibleCount / xDiv)).round());
            final bucketSize = visibleCount / cols;
            for (var col = 0; col < cols; col++) {
              final bStart = (col * bucketSize).floor();
              final bEnd = min(
                visibleCount,
                max(bStart + 1, ((col + 1) * bucketSize).floor()),
              );
              var bMin = double.infinity;
              var bMax = double.negativeInfinity;
              for (var j = bStart; j < bEnd; j++) {
                final v = ring != null ? ring[start + j] : list![start + j];
                if (v < bMin) bMin = v;
                if (v > bMax) bMax = v;
              }
              final x = (col + 0.5) * usedWidth / cols;
              final yTop = (centerY - (bMax - mean) * yScale).clamp(minY, maxY);
              final yBot = (centerY - (bMin - mean) * yScale).clamp(minY, maxY);
              if (col == 0) {
                path.moveTo(x, yTop);
                if (yBot != yTop) path.lineTo(x, yBot);
              } else {
                path.lineTo(x, yTop);
                if (yBot != yTop) path.lineTo(x, yBot);
              }
            }
          }

          final color =
              (channelColors != null && channel < channelColors!.length)
              ? channelColors![channel]
              : (traceColor ?? colors[channel % colors.length]);
          tracePaint.color = color;
          canvas.drawPath(path, tracePaint);

          if (showInlineLabels) {
            final labelText =
                channelLabels != null && channel < channelLabels!.length
                ? channelLabels![channel]
                : 'Ch ${channel + 1}';
            final label = TextPainter(
              text: TextSpan(
                text: labelText,
                style: TextStyle(
                  color: color,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
              textDirection: TextDirection.ltr,
            )..layout();
            label.paint(canvas, Offset(6, yCursor + 4));
          }
        }
      }
      yCursor += laneHeight;
    }

    _paintTimeTicks(canvas, size, secDivisions);
    if (markers.isNotEmpty) {
      _paintMarkers(canvas, size);
    }
  }

  void _paintTimeTicks(Canvas canvas, Size size, int divisions) {
    if (durationSeconds <= 0 || divisions <= 0) return;
    final step = max(1, (divisions / 5).ceil());
    for (var i = 1; i < divisions; i += step) {
      final secAgo = durationSeconds * (1 - i / divisions);
      final x = size.width * i / divisions;
      final label = TextPainter(
        text: TextSpan(
          text: '-${secAgo.toStringAsFixed(secAgo >= 10 ? 0 : 1)}s',
          style: const TextStyle(
            color: StudioColors.textMuted,
            fontSize: 9,
            fontWeight: FontWeight.w500,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      label.paint(canvas, Offset(x + 3, size.height - label.height - 2));
    }
  }

  void _paintMarkers(Canvas canvas, Size size) {
    if (markers.isEmpty || durationSeconds <= 0) return;
    final reference = now ?? DateTime.now();
    for (final marker in markers) {
      final double x;
      if (isPageMode && pageStartedAt != null) {
        if (marker.receivedAt.isBefore(pageStartedAt!)) continue;
        final elapsed =
            marker.receivedAt.difference(pageStartedAt!).inMicroseconds / 1e6;
        if (elapsed < 0 || elapsed > durationSeconds) continue;
        x = (size.width * (elapsed / durationSeconds)).clamp(0.0, size.width);
      } else {
        final age = reference.difference(marker.receivedAt).inMicroseconds / 1e6;
        if (age < -0.25 || age > durationSeconds) continue;
        x = (size.width * (1 - age / durationSeconds)).clamp(0.0, size.width);
      }
      final paint = Paint()
        ..color = StudioColors.amber
        ..strokeWidth = 1.5;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
      final label = TextPainter(
        text: TextSpan(
          text: ' ${marker.value} (${marker.code}) ',
          style: const TextStyle(
            color: Color(0xFF78350F),
            fontSize: 9.5,
            fontWeight: FontWeight.w700,
            backgroundColor: Color(0xFFFEF3C7),
          ),
        ),
        maxLines: 1,
        ellipsis: '…',
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: 140);
      label.paint(
        canvas,
        Offset((x + 3).clamp(0, size.width - label.width), 3),
      );
    }
  }

  @override
  bool shouldRepaint(covariant WaveformPainter oldDelegate) =>
      oldDelegate.stacked != stacked ||
      oldDelegate.selectedChannel != selectedChannel ||
      oldDelegate.gain != gain ||
      oldDelegate.durationSeconds != durationSeconds ||
      oldDelegate.autoscale != autoscale ||
      oldDelegate.markers.length != markers.length ||
      oldDelegate.isPageMode != isPageMode ||
      oldDelegate.pageStartedAt != pageStartedAt ||
      oldDelegate.strokeWidth != strokeWidth;
}
