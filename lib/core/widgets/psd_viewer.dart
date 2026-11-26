import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../eeg/spectral_analyzer.dart';
import '../theme/studio_theme.dart';

/// Dockable real-time Welch Power Spectral Density (PSD) viewer for any
/// selected channel.
class PsdViewerPanel extends StatefulWidget {
  const PsdViewerPanel({
    super.key,
    required this.channelLabels,
    required this.selectedChannelIndex,
    required this.onSelectChannel,
    required this.psdResult,
    required this.onClose,
  });

  final List<String> channelLabels;
  final int selectedChannelIndex;
  final ValueChanged<int> onSelectChannel;
  final WelchPsdResult? psdResult;
  final VoidCallback onClose;

  @override
  State<PsdViewerPanel> createState() => _PsdViewerPanelState();
}

class _PsdViewerPanelState extends State<PsdViewerPanel> {
  double _maxFreqHz = 45.0;
  bool _logScaleDb = true;

  @override
  Widget build(BuildContext context) {
    final psd = widget.psdResult;
    final bands = psd?.bands;
    final selectedIdx = widget.channelLabels.isEmpty
        ? 0
        : widget.selectedChannelIndex.clamp(0, widget.channelLabels.length - 1);

    return Container(
      decoration: BoxDecoration(
        color: StudioColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: StudioColors.border),
      ),
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(
                Icons.equalizer,
                color: StudioColors.sky,
                size: 16,
              ),
              const SizedBox(width: 6),
              const Text(
                'PSD',
                style: TextStyle(
                  color: StudioColors.textPrimary,
                  fontWeight: FontWeight.w700,
                  fontSize: 12.5,
                ),
              ),
              const SizedBox(width: 8),
              if (widget.channelLabels.isNotEmpty)
                Expanded(
                  child: DropdownButton<int>(
                    isExpanded: true,
                    isDense: true,
                    value: selectedIdx,
                    dropdownColor: StudioColors.elevated,
                    underline: const SizedBox.shrink(),
                    style: const TextStyle(
                      color: StudioColors.teal,
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                    ),
                    items: List.generate(
                      widget.channelLabels.length,
                      (i) => DropdownMenuItem(
                        value: i,
                        child: Text(
                          widget.channelLabels[i],
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                    onChanged: (idx) {
                      if (idx != null) widget.onSelectChannel(idx);
                    },
                  ),
                )
              else
                const Spacer(),
              DropdownButton<double>(
                isDense: true,
                value: _maxFreqHz,
                dropdownColor: StudioColors.elevated,
                underline: const SizedBox.shrink(),
                style: const TextStyle(
                  color: StudioColors.textSecondary,
                  fontSize: 11.5,
                ),
                items: const [
                  DropdownMenuItem(value: 45.0, child: Text('0–45 Hz')),
                  DropdownMenuItem(value: 70.0, child: Text('0–70 Hz')),
                  DropdownMenuItem(value: 125.0, child: Text('0–125 Hz')),
                ],
                onChanged: (v) {
                  if (v != null) setState(() => _maxFreqHz = v);
                },
              ),
              const SizedBox(width: 4),
              InkWell(
                onTap: () => setState(() => _logScaleDb = !_logScaleDb),
                borderRadius: BorderRadius.circular(6),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: StudioColors.card,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: StudioColors.border),
                  ),
                  child: Text(
                    _logScaleDb ? 'dB' : 'µV²/Hz',
                    style: const TextStyle(
                      color: StudioColors.sky,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Close PSD',
                visualDensity: VisualDensity.compact,
                iconSize: 16,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
                onPressed: widget.onClose,
                icon: const Icon(
                  Icons.close,
                  color: StudioColors.textSecondary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Expanded(
            child: psd == null
                ? const Center(
                    child: Text(
                      'Collecting samples for Welch PSD…',
                      style: TextStyle(
                        color: StudioColors.textMuted,
                        fontSize: 11.5,
                      ),
                    ),
                  )
                : CustomPaint(
                    painter: _WelchPsdPainter(
                      psd: psd,
                      maxFreqHz: _maxFreqHz,
                      logScaleDb: _logScaleDb,
                    ),
                  ),
          ),
          if (bands != null) ...[
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                _bandChip('Peak', '${bands.peakFrequencyHz.toStringAsFixed(1)} Hz', StudioColors.sky),
                _bandChip('δ', '${bands.deltaPct.toStringAsFixed(0)}%', const Color(0xFF94A3B8)),
                _bandChip('θ', '${bands.thetaPct.toStringAsFixed(0)}%', const Color(0xFFA78BFA)),
                _bandChip('α', '${bands.alphaPct.toStringAsFixed(0)}%', StudioColors.teal),
                _bandChip('β', '${bands.betaPct.toStringAsFixed(0)}%', StudioColors.amber),
                _bandChip('γ', '${bands.gammaPct.toStringAsFixed(0)}%', const Color(0xFFF472B6)),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _bandChip(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(
        '$label $value',
        style: TextStyle(
          color: color,
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _WelchPsdPainter extends CustomPainter {
  _WelchPsdPainter({
    required this.psd,
    required this.maxFreqHz,
    required this.logScaleDb,
  });

  final WelchPsdResult psd;
  final double maxFreqHz;
  final bool logScaleDb;

  @override
  void paint(Canvas canvas, Size size) {
    const padL = 32.0;
    const padB = 18.0;
    const padR = 8.0;
    const padT = 6.0;
    final plotW = math.max(10.0, size.width - padL - padR);
    final plotH = math.max(10.0, size.height - padT - padB);
    final rect = Rect.fromLTWH(padL, padT, plotW, plotH);
    canvas.drawRect(rect, Paint()..color = StudioColors.card);

    // Band shading (Delta/Theta/Alpha/Beta)
    void shadeBand(double f0, double f1, Color color) {
      if (f0 >= maxFreqHz) return;
      final x0 = rect.left + (f0 / maxFreqHz).clamp(0.0, 1.0) * rect.width;
      final x1 = rect.left + (f1 / maxFreqHz).clamp(0.0, 1.0) * rect.width;
      if (x1 <= x0) return;
      canvas.drawRect(
        Rect.fromLTRB(x0, rect.top, x1, rect.bottom),
        Paint()..color = color.withValues(alpha: 0.06),
      );
    }

    shadeBand(0.5, 4, const Color(0xFF94A3B8));
    shadeBand(4, 8, const Color(0xFFA78BFA));
    shadeBand(8, 13, StudioColors.teal);
    shadeBand(13, 30, StudioColors.amber);

    final grid = Paint()
      ..color = StudioColors.border.withValues(alpha: 0.5)
      ..strokeWidth = 0.7;
    canvas.drawRect(rect, grid..style = PaintingStyle.stroke);

    final freqs = psd.frequenciesHz;
    final values = logScaleDb ? psd.psdDb : psd.psdUv2PerHz;
    final pts = <Offset>[];
    var minY = double.infinity;
    var maxY = double.negativeInfinity;

    for (var i = 0; i < freqs.length; i++) {
      final f = freqs[i];
      if (f < 0.3 || f > maxFreqHz) continue;
      final v = values[i];
      if (!v.isFinite) continue;
      if (v < minY) minY = v;
      if (v > maxY) maxY = v;
    }
    if (!minY.isFinite || !maxY.isFinite || maxY <= minY) {
      minY = logScaleDb ? -20 : 0;
      maxY = logScaleDb ? 30 : 10;
    } else if (logScaleDb) {
      minY = math.max(-35.0, minY - 3.0);
      maxY = maxY + 3.0;
    } else {
      minY = 0.0;
      maxY = maxY * 1.1;
    }

    for (var i = 0; i < freqs.length; i++) {
      final f = freqs[i];
      if (f < 0.3 || f > maxFreqHz) continue;
      final x = rect.left + (f / maxFreqHz) * rect.width;
      final norm = ((values[i] - minY) / (maxY - minY)).clamp(0.0, 1.0);
      final y = rect.bottom - norm * rect.height;
      pts.add(Offset(x, y));
    }

    if (pts.length >= 2) {
      final fillPath = Path()..moveTo(pts.first.dx, rect.bottom);
      final linePath = Path()..moveTo(pts.first.dx, pts.first.dy);
      for (final p in pts) {
        fillPath.lineTo(p.dx, p.dy);
        linePath.lineTo(p.dx, p.dy);
      }
      fillPath.lineTo(pts.last.dx, rect.bottom);
      fillPath.close();

      canvas.drawPath(
        fillPath,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              StudioColors.sky.withValues(alpha: 0.35),
              StudioColors.sky.withValues(alpha: 0.02),
            ],
          ).createShader(rect),
      );
      canvas.drawPath(
        linePath,
        Paint()
          ..color = StudioColors.sky
          ..strokeWidth = 1.6
          ..style = PaintingStyle.stroke,
      );
    }

    // Axis ticks
    void drawLabel(String text, Offset pos) {
      final tp = TextPainter(
        text: TextSpan(
          text: text,
          style: const TextStyle(color: StudioColors.textMuted, fontSize: 9),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, pos);
    }

    drawLabel(maxY.toStringAsFixed(0), Offset(2, rect.top));
    drawLabel(minY.toStringAsFixed(0), Offset(2, rect.bottom - 10));
    final freqStep = maxFreqHz <= 50 ? 10 : (maxFreqHz <= 80 ? 15 : 25);
    for (var f = 0; f <= maxFreqHz; f += freqStep) {
      final x = rect.left + (f / maxFreqHz) * rect.width;
      canvas.drawLine(Offset(x, rect.top), Offset(x, rect.bottom), grid);
      drawLabel('${f}Hz', Offset((x - 10).clamp(0, size.width - 26), rect.bottom + 3));
    }
  }

  @override
  bool shouldRepaint(covariant _WelchPsdPainter oldDelegate) =>
      oldDelegate.psd != psd ||
      oldDelegate.maxFreqHz != maxFreqHz ||
      oldDelegate.logScaleDb != logScaleDb;
}
