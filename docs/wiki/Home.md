# CCS Mobile Studio Wiki

Welcome to the official operator and researcher Wiki for **CCS Mobile Studio** (`v1.0.12+15`), developed by the **Centre for Consciousness Studies (CCS), Department of Neurophysiology, NIMHANS** in collaboration with **Axxonet** and **Neurostellar**.

## What’s New in v1.0.12
- **CCS_SleepStudio Clinical Light UI:** High-contrast `#F3F5F8` / `#FFFFFF` clinical instrument aesthetic across phones, tablets, laptops, and desktops, with full tab/dialog/plot contrast consistency and a clean cropped app icon.
- **Standalone EEG Recorder Overhaul:** Expanded Montage & Per-Channel Filter Editor, quick Hide/Prominent channel toggles, native Rust Welch PSD (`ccs_welch_psd`), passive impedance & Signal Quality Index (`Z / SQI`), and preset/custom markers aligned in both Page and Roll sweep modes.
- **Realtime Rust ASR + OSCAR Cleaning:** Non-destructive online CleanLine, sliding-window ASR subspace reconstruction, gated EOG regression, and EMG/slew suppression (`rust/src/cleaning.rs`).
- **Native EDF+ (`EDF+C`) & Clean Exports:** Embedded `EDF Annotations` TAL events directly in `.edf` files, single-directory exports without redundant subfolders, and hardware-clocked AVFoundation `.mp4` A/V Sync (`_av_sync.json`).
- **Standardized ERP CORE (6 Tasks) & Live ERPs:** N170, MMN, N2pc, N400, P3b, and ERN/LRP Flankers with VSync/audio timing verification, real-time ERP + difference-wave plots, and **Heart Rate Discrimination (HRD)** with metacognitive confidence calibration.
- **Dichotic Neural Speech Tracking:** Simultaneous stereo L/R speech presentation with native Rust multi-feature backward TRF attentional decoding across all or selected electrodes.
- **Multi-Profile Hardware Presets & Cold-Start BLE Fix:** Define multiple project-tagged profiles per amplifier, duplicate/import/export JSON, and connect reliably on first scan.

## Navigation
* [EEG Recorder & Signal Quality](EEG-Recorder-and-Signal-Quality.md)
* [Realtime EEG Cleaning (ASR & OSCAR)](Realtime-EEG-Cleaning-ASR-OSCAR.md)
* [ERP CORE & Conventional ERP](ERP-CORE-and-Conventional-ERP.md)
* [Neural Speech Tracking](Neural-Speech-Tracking.md)
* [AV Sync & EDF+ Annotations](AV-Sync-and-EDF-Plus.md)
* [Device Profiles & Hardware](Device-Profiles-and-Hardware.md)
* [In-App Updates & Release Guide](In-App-Updates-and-Release-Guide.md)
