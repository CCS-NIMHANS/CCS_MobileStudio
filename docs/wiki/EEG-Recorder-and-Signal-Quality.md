# EEG Recorder & Signal Quality

## Viewport & Sweep Modes
- **Roll Mode:** Continuous right-to-left scrolling waveform stream.
- **Page Mode:** Fixed-width sweep cursor erasing ahead of the write head; markers track the active sweep position accurately rather than plotting on blank regions.
- **Ring Buffer & Decimation:** Zero-shift `Float64RingBuffer` storage paired with per-pixel min-max decimation keeps 60 FPS fluid UI performance even with 16 channels @ 250–1000 Hz.

## Montage & Per-Channel Filter Editor
Open **Channels / Montage** from the recorder toolbar:
- **Rename Channels:** Assign clinical montage names (`Fp1`, `Fp2`, `C3`, `C4`, `LEOG`, `REOG`, `ChinEMG`, etc.).
- **Re-Referencing:** Choose `Native`, Common Average Reference (`CAR`), linked mastoid, or any single channel reference per channel.
- **Channel-Specific Display Filters:** Set custom high-pass, low-pass, and 50/60 Hz notch settings independently per trace (e.g., `0.3–35 Hz` for EOG, `10–100 Hz` for EMG, `0.5–45 Hz` for EEG).
- **Quick Hide & Prominent Solo:** Toggle any channel's eye icon (`👁`) to hide/show immediately, or toggle prominent zoom for focused inspection.

## Signal Quality Index & Passive Impedance (`Z / SQI`)
- Toggle `Z / SQI` in the recorder toolbar to reveal compact per-channel impedance (`kΩ`) and clean/noisy/flat/saturated indicators computed in Rust (`ccs_signal_quality_batch`) without shrinking the waveform area.

## Real-Time Welch PSD (`PSD`)
- Toggle `PSD` to dock the frequency spectrum panel (`0–45 Hz`, `0–70 Hz`, or `0–125 Hz`) for any chosen channel, displaying live Delta/Theta/Alpha/Beta/Gamma relative band percentages and peak frequency.
