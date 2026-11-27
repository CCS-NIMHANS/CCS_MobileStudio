# Dichotic Neural Speech Tracking

The **Neural Speech Tracking** module quantifies selective auditory attention during multi-speaker dichotic listening.

## Protocol Workflow
1. Choose two speech audio files assigned to **Left** and **Right** stereo channels (or bundled default speech tracks).
2. Define number of blocks, block duration, and alternating instruction sequence (`Attend Left` / `Attend Right`).
3. Select whether decoding uses **All active EEG channels** or a **Selected electrode subset**.
4. During playback, true dual-mono stereo streams play in headphones while synchronous block/attention event markers are written into EDF+ (`EDF Annotations`).

## Rust Multi-Feature Backward TRF (`rust/src/speech_tracking.rs`)
- Extracts bandpass rectified **speech envelope** and **temporal onset derivative** multi-features for both Left and Right audio tracks.
- Trains a ridge-regularized causal **backward Temporal Response Function** across temporal lags (`0–400 ms`) on the selected EEG channels — providing reliable attentional tracking even with sparse/few electrodes.
- Displays end-of-block decoding correlations (`r_left`, `r_right`), predicted focus ear, and margin confidence, and saves `<subject>_SPEECH_*.edf`, `.json`, and `.csv`.
