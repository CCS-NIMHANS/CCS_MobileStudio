# AV Sync & EDF+ (`EDF+C`) Annotations

## Native EDF+C Format
- `rust/src/lib.rs` upgrades EDF recording to standards-compliant **EDF+ (`EDF+C`)**, writing an `EDF Annotations` TAL signal alongside raw physiological channels in every data record.
- Both manual recorder markers (`EO`, `EC`, `Task`, custom tags) and paradigm events (`ANGEL`, `WM`, `ERP CORE`, `NIDRA` stim/stage cues, `HEARTSYNC`, `HRD`, `SPEECH`) are embedded directly inside the `.edf` file as well as exported to companion CSV logs.

## Time-Synched Webcam Video & Audio
- On macOS (`macos/Runner/AvSyncRecorder.swift`), enabling **AV Sync** captures hardware-clocked `.mp4` video and microphone audio simultaneously with EEG acquisition.
- Writes exact `AV_SYNC_START` and `AV_SYNC_STOP` TAL markers into the EDF+ file plus a sibling `_av_sync.json` file containing start timestamps, hardware sample offsets, frame timestamps, and clock-drift telemetry for frame-accurate post-hoc video alignment.

## Clean Single-Directory Exports
- Configure your preferred export root in **Settings → Output & Study Flow** (or the dashboard header).
- All `.edf`, `.csv`, `.json`, `.mp4`, and `.pdf` outputs write cleanly below `<OutputFolder>/<Subject>/` with zero duplicate `recordings/` or `data/` staging folders.
