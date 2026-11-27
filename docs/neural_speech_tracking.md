# Dichotic Neural Speech Tracking

The **Neural Speech Tracking** module (`lib/modules/speech_tracking/`) measures selective auditory attention when a participant listens to two simultaneous speech streams presented in stereo (**Left ear** vs. **Right ear**).

## Paradigm Design

1. Select two speech audio files (or default bundled stimuli) assigned to **Left Channel** and **Right Channel**.
2. Configure block count, block duration, and instruction alternation (`Attend Left` / `Attend Right` blocks).
3. Audio mixes into true dual-mono stereo (`L = speech_A`, `R = speech_B`) and delivers synchronous block start/cue/end event markers into EDF+ (`SPEECH_START`, `ATTEND_LEFT`, `ATTEND_RIGHT`, `BLOCK_END`).
4. Choose whether decoding uses **all active EEG channels** or a **selected subset** of EEG electrodes.

## Native Rust Multi-Feature Backward TRF (`rust/src/speech_tracking.rs`)

Because mobile/ambulatory EEG headsets may have anywhere from 2 to 16+ channels connected cleanly:

- **Acoustic Envelope & Multi-Feature Extraction:** Computes bandpass/rectified speech envelopes and first-order temporal derivative (acoustic onset/edge) features for both Left and Right audio tracks.
- **Backward Ridge-Regularized TRF:** Fits causal spatio-temporal backward decoders (`t = 0..400 ms` lags across the selected EEG channels with Tikhonov/L2 regularization) that reconstruct the attended acoustic feature trajectory from EEG.
- **Small-Montage Robustness:** Expanding single/few-channel EEG across temporal lag basis taps preserves decoding sensitivity even when only a subset of scalp electrodes is active.
- **Block-Wise Focus Scoring:** At the end of each block, correlates reconstructed neural envelopes against the true **Left** and **Right** stimulus features (`r_left`, `r_right`) and reports:
  - Predicted attended side (`Left`, `Right`, or `Balanced/Low Confidence`)
  - Confidence margin (`|r_left - r_right|`) and block accuracy vs. instructed ear.

## Exports

All recordings follow `<subject>_SPEECH_<timestamp>` naming below your configured export folder:
- Calibrated continuous **EDF+ (`EDF+C`)** with TAL block/attention annotations.
- **Session JSON & Block CSV** containing `r_left`, `r_right`, predicted focus, instructed target, selected channels, and feature parameters.
