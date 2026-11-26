import 'package:flutter/material.dart';

import '../eeg/signal_quality_analyzer.dart';
import '../theme/studio_theme.dart';

/// Dockable per-channel Signal Quality & Passive Electrode-Skin Impedance
/// monitor panel.
class SignalQualityPanel extends StatelessWidget {
  const SignalQualityPanel({
    super.key,
    required this.channelLabels,
    required this.metrics,
    required this.mainsHz,
    required this.calibrationFactor,
    required this.onToggleMainsHz,
    required this.onCalibrate,
    required this.onSelectChannelForPsd,
    required this.onClose,
  });

  final List<String> channelLabels;
  final List<ChannelQualityMetrics> metrics;
  final double mainsHz;
  final double calibrationFactor;
  final ValueChanged<double> onToggleMainsHz;
  final VoidCallback onCalibrate;
  final ValueChanged<int> onSelectChannelForPsd;
  final VoidCallback onClose;

  static Color gradeColor(SignalQualityGrade grade) => switch (grade) {
    SignalQualityGrade.good => StudioColors.emerald,
    SignalQualityGrade.fair => StudioColors.amber,
    SignalQualityGrade.poor => const Color(0xFFFB923C),
    SignalQualityGrade.bad => StudioColors.red,
  };

  @override
  Widget build(BuildContext context) {
    final goodCount = metrics
        .where((m) => m.grade == SignalQualityGrade.good)
        .length;

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
                Icons.health_and_safety_outlined,
                color: StudioColors.emerald,
                size: 16,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Signal Quality & Z ($goodCount/${metrics.length} good)',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: StudioColors.textPrimary,
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
              ),
              InkWell(
                onTap: () => onToggleMainsHz(mainsHz == 50 ? 60.0 : 50.0),
                borderRadius: BorderRadius.circular(6),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: StudioColors.card,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: StudioColors.border),
                  ),
                  child: Text(
                    '${mainsHz.toInt()} Hz',
                    style: const TextStyle(
                      color: StudioColors.sky,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              Tooltip(
                message:
                    'Calibrate passive impedance baseline to current clean channels (k=${calibrationFactor.toStringAsFixed(2)})',
                child: InkWell(
                  onTap: onCalibrate,
                  borderRadius: BorderRadius.circular(6),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: StudioColors.card,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: StudioColors.border),
                    ),
                    child: const Text(
                      'Cal',
                      style: TextStyle(
                        color: StudioColors.teal,
                        fontSize: 10.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Close Signal Quality Panel',
                visualDensity: VisualDensity.compact,
                iconSize: 16,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
                onPressed: onClose,
                icon: const Icon(
                  Icons.close,
                  color: StudioColors.textSecondary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            'Passive Z est. from mains Goertzel + HF noise & rail check. Tap row for PSD.',
            style: TextStyle(color: StudioColors.textMuted, fontSize: 10),
          ),
          const SizedBox(height: 6),
          Expanded(
            child: metrics.isEmpty
                ? const Center(
                    child: Text(
                      'Waiting for samples…',
                      style: TextStyle(
                        color: StudioColors.textMuted,
                        fontSize: 11.5,
                      ),
                    ),
                  )
                : ListView.separated(
                    itemCount: metrics.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 4),
                    itemBuilder: (context, idx) {
                      final m = metrics[idx];
                      final label = idx < channelLabels.length
                          ? channelLabels[idx]
                          : 'Ch ${idx + 1}';
                      final color = gradeColor(m.grade);
                      return InkWell(
                        onTap: () => onSelectChannelForPsd(idx),
                        borderRadius: BorderRadius.circular(8),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: StudioColors.card,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: color.withValues(alpha: 0.35),
                            ),
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 8,
                                height: 8,
                                decoration: BoxDecoration(
                                  color: color,
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 7),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      label,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: StudioColors.textPrimary,
                                        fontWeight: FontWeight.w600,
                                        fontSize: 11.5,
                                      ),
                                    ),
                                    Text(
                                      'P2P ${m.peakToPeakUv.toStringAsFixed(0)}µV • ${mainsHz.toInt()}Hz ${m.lineNoiseRmsUv.toStringAsFixed(1)}µV',
                                      style: const TextStyle(
                                        color: StudioColors.textMuted,
                                        fontSize: 9.5,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Text(
                                    m.formattedImpedance,
                                    style: TextStyle(
                                      color: color,
                                      fontWeight: FontWeight.w700,
                                      fontSize: 11.5,
                                    ),
                                  ),
                                  Text(
                                    'SQI ${m.sqiPercent.round()}%',
                                    style: const TextStyle(
                                      color: StudioColors.textSecondary,
                                      fontSize: 9.5,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
