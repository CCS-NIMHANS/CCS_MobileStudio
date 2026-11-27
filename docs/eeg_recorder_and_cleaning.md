# Standalone EEG Recorder, Signal Quality & Realtime Cleaning

The Standalone EEG / fNIRS Recorder serves both as an independent multi-channel recording tool and as the shared visualization/acquisition engine across CCS Mobile Studio modules.

## 1. Layout, Montage & Per-Channel Controls

- **Clinical Light Canvas:** Waveform plots render on pure white (`#FFFFFF`) cards inside a clinical light workspace (`#F3F5F8` / `#F8F9FB`) with dark ink traces and tabular metrics.
- **Channel Rail Controls:**
  - **Quick Hide (👁):** Immediately hides noisy or unused channels from the viewport while optionally keeping raw hardware data intact in EDF+.
  - **Prominent / Solo Focus:** Expands a chosen channel of interest cleanly without altering acquisition buffers.
- **Montage & Per-Channel Filter Editor:**
  - Custom channel renaming (persisted per device profile).
  - Reference selection (`Native`, `CAR`, linked mastoid, or custom reference channel).
  - Per-channel high-pass, low-pass, and notch display filters so EEG, EOG, EMG, and ECG traces remain readable side-by-side.
  - Note: Display filters and online cleaning affect visualization, PSD, and derived metrics only; the raw physiological signals written to disk remain unaltered.

## 2. Passive Impedance & Signal Quality (Z / SQI)

- Computed in batches on the native Rust core (`ccs_signal_quality_batch`).
- Evaluates mains contamination, high-frequency EMG bursts, flatlines / rails-off, and passive impedance estimates (`kΩ`) per channel inside a collapsible compact strip that preserves vertical space for traces.

## 3. Real-Time Welch Power Spectral Density (PSD)

- Computed natively in Rust (`ccs_welch_psd`) across selectable display bounds (`0–45 Hz`, `0–70 Hz`, `0–125 Hz`).
- Displays relative Delta, Theta, Alpha, Beta, and Gamma band percentages alongside peak frequency for any chosen channel.

## 4. Realtime Rust ASR + OSCAR-Style Cleaning Pipeline

Implemented in `rust/src/cleaning.rs` and exposed via `ccs_cleaner_*` FFI entry points:
1. **CleanLine Suppression:** Adaptive 50/60 Hz line-noise and harmonic sinusoidal removal.
2. **Sliding-Window ASR (Artifact Subspace Reconstruction):** Estimates robust channel covariance structure over clean calibration statistics and reconstructs transient high-variance bursts above configurable SD thresholds.
3. **Gated Frontal EOG Blink Regression:** Subtracts blink/ocular projections onto EEG channels when ocular transients exceed clean thresholds.
4. **EMG & Slew Pop Suppression:** Attenuates sharp muscle and electrode-pop transients.

The recorder displays a live **`% Cleaned`** status chip whenever online cleaning is enabled.

## 5. EDF+ (`EDF+C`) Annotations, Markers & A/V Sync

- **EDF+C Format:** `rust/src/lib.rs` encodes continuous `EDF+C` files with an explicit `EDF Annotations` TAL channel embedded directly into each data record alongside companion marker CSVs.
- **Sweep Alignment:** Manual/task markers align directly with the active cursor in both **Roll** and **Page** sweep modes.
- **Export Structure:** Outputs write directly below `<Configured Output Root>/<Subject>/` with zero duplicate `recordings/` or `data/` staging folders.
- **Time-Synched Webcam Video & Audio:** macOS AVFoundation capture (`AvSyncRecorder.swift`) writes an `.mp4` track paired with `AV_SYNC_START` / `AV_SYNC_STOP` EDF+ annotations and `_av_sync.json` sample-offset & clock-drift telemetry.
