# Realtime EEG Cleaning (ASR & OSCAR Style)

CCS Mobile Studio implements an online multi-stage artifact cleaning pipeline in native Rust (`rust/src/cleaning.rs`) exposed via `ccs_cleaner_*` FFI bindings.

## Pipeline Stages
1. **Online CleanLine (`50 / 60 Hz` + harmonics):** Tracks sinusoidal mains pickup and harmonics via sliding least-squares estimation and subtracts line noise without distorting adjacent brain frequencies.
2. **Sliding-Window Artifact Subspace Reconstruction (ASR):** Continuously maintains robust clean channel covariance statistics and attenuates transient large-variance multi-channel bursts via principal-component subspace reconstruction.
3. **Gated Frontal EOG Blink Regression:** Detects ocular deflections on frontal/EOG sensors and subtracts adaptive regression weights only during blink windows to avoid removing tonic frontal EEG.
4. **EMG & Electrode-Pop Slew Limiting:** Suppresses high-frequency myogenic bursts and steep discontinuity pops.

## Data Safety Guarantee
- Cleaning runs **strictly on display, PSD, and derived feature streams**.
- Raw physiological channels recorded to **EDF+ (`EDF+C`)** remain completely unaltered so offline post-hoc preprocessing pipelines (such as EEGLAB/OSCAR/CCS_EEGStudio) always have pristine source signals.
- A live **`% Cleaned`** badge in the recorder toolbar indicates active artifact attenuation.
