<p align="center">
  <img src="screenshots/ccs_logo.png" width="160" alt="Centre for Consciousness Studies Logo">
</p>

<h1 align="center">CCS Mobile Studio</h1>

<p align="center">
  <b>One unified clinical-light workspace for neurophysiology acquisition, stimulation, real-time cleaning, neural speech tracking and cognitive experiments</b>
</p>

<p align="center">
  A Research & Engineering Collaboration of<br>
  <b>Centre for Consciousness Studies (CCS)</b>, Department of Neurophysiology,<br>
  <b>National Institute of Mental Health and Neurosciences (NIMHANS)</b>, Bengaluru, India<br>
  🤝<br>
  <a href="https://axxonet.com/"><b>Axxonet</b></a> &nbsp;|&nbsp; <a href="https://www.neuro-stellar.com/"><b>Neurostellar</b></a>
</p>

<p align="center">
  <a href="https://github.com/CCS-NIMHANS/CCS_MobileStudio/releases/latest"><b>📦 Latest Release (v1.0.12+15)</b></a> &nbsp;·&nbsp;
  <a href="https://github.com/CCS-NIMHANS/CCS_MobileStudio/actions/workflows/desktop-release.yml"><b>⚙️ Build Status</b></a> &nbsp;·&nbsp;
  <a href="https://github.com/CCS-NIMHANS/CCS_MobileStudio/releases"><b>⬇️ All Releases &amp; Checksums</b></a>
</p>

<p align="center">
  <b>Current version: 1.0.12 (Build 15)</b> ·
  <a href="RELEASE_NOTES.md">Detailed changelog</a> ·
  <a href="docs/wiki/Home.md">Documentation &amp; Wiki</a> ·
  <a href="https://github.com/CCS-NIMHANS/CCS_MobileStudio/issues">Report a problem</a>
</p>

<p align="center">
  <a href="#-quick-download"><b>📥 Download App</b></a> &nbsp;•&nbsp;
  <a href="#about"><b>About</b></a> &nbsp;•&nbsp;
  <a href="#-research-modules"><b>Research Modules</b></a> &nbsp;•&nbsp;
  <a href="#-building-from-source"><b>Build from Source</b></a> &nbsp;•&nbsp;
  <a href="docs/wiki/Home.md"><b>Wiki &amp; Guides</b></a> &nbsp;•&nbsp;
  <a href="RELEASE_NOTES.md"><b>Release Notes</b></a>
</p>

---

### 📥 Quick Download

Pre-built standalone application packages are published through GitHub Releases:

| Platform | Package Type | Extracted App / Binary | Direct Download Link |
| :--- | :--- | :--- | :--- |
| **macOS** | Universal desktop application (.zip) | **`CCS Mobile Studio.app`** | [CCSMobileStudio-macos.zip](https://github.com/CCS-NIMHANS/CCS_MobileStudio/releases/latest/download/CCSMobileStudio-macos.zip) |
| **Windows** | 64-bit desktop package (.zip) | `CCSMobileStudio.exe` | [CCSMobileStudio-Windows.zip](https://github.com/CCS-NIMHANS/CCS_MobileStudio/releases/latest/download/CCSMobileStudio-Windows.zip) |
| **Android** | Mobile & Tablet APK | `CCSMobileStudio-Android.apk` | [CCSMobileStudio-Android.apk](https://github.com/CCS-NIMHANS/CCS_MobileStudio/releases/latest/download/CCSMobileStudio-Android.apk) |

> 📦 **All Releases & Assets:** View all version packages, release notes, and SHA-256 checksums (`SHA256SUMS.txt`) on the **[GitHub Releases Page](https://github.com/CCS-NIMHANS/CCS_MobileStudio/releases/latest)**.  
> 🔄 **In-App Upgrades:** CCS Mobile Studio features automatic background update checks with SHA-256 verification via the **Update** icon in the dashboard toolbar or Settings screen.

#### 🍏 First-Time Launch for macOS Users (Gatekeeper Setup)

When extracting `CCSMobileStudio-macos.zip`, macOS extracts **`CCS Mobile Studio.app`** into your `~/Downloads` folder. If running an unnotarized / Developer ID build downloaded via browser:

```sh
# 1. Clear Gatekeeper quarantine on the downloaded app:
xattr -rd com.apple.quarantine ~/Downloads/CCS\ Mobile\ Studio.app

# 2. Move to Applications folder:
mv ~/Downloads/CCS\ Mobile\ Studio.app /Applications/
```

> **Tip (Finder alternative):** In Finder, **Right-click (or Control-click)** `CCS Mobile Studio.app` → select **Open** → click **Open** on the security confirmation prompt. You only need to do this once.
>
> **Automated 1-Click Install:** Downloaded `.zip` archives can also be installed directly to `/Applications` using `./tools/install_mac.sh`. Future in-app updates perform this automatically in the background.

<p align="center">
  <img src="docs/images/dashboard.png" width="920" alt="CCS Mobile Studio Unified Study Dashboard">
</p>

---

## About

**CCS Mobile Studio** brings live EEG/fNIRS acquisition, real-time Rust ASR/OSCAR artifact cleaning, sleep staging, standardized **ERP CORE** & conventional ERP experiments, adaptive cognition tasks, dichotic **Neural Speech Tracking**, cardiac interoception (**Heart Rate Discrimination** & **HeartSync**), individual **Resonance Breathing**, and hardware-timestamped webcam A/V recording into one unified, subject-session-aware application.

Built with the clean **CCS_SleepStudio clinical light theme** (`#F3F5F8` canvas, pure white `#FFFFFF` instrument plots, `#3B6EA5` steel-blue accents, high-contrast dark traces), Flutter provides a responsive interface across phones, tablets, laptops, and desktop workstations while a native **Rust FFI core** executes Welch PSD, signal quality & passive impedance estimation, online CleanLine/ASR/EOG cleaning, multi-feature TRF speech decoding, TinySleepNet ONNX inference, NeuroKit2 cardiac pipelines, and **EDF+ (`EDF+C`)** encoding at 60 FPS without UI stalls.

> Enter the participant identifier once, choose or connect a saved device profile, and move through your entire study sequence with consistent filenames, embedded EDF+ TAL annotations, and unified folder exports.

---

## 🌟 Highlights

| Acquire & Clean | Experiment & Decode | Analyse & Safeguard |
| :--- | :--- | :--- |
| Multi-device EEG, EOG, EMG, ECG, PPG & fNIRS streaming | Train NIDRA (ACLS), ANGEL, ERP CORE (6 tasks), Conventional ERP, Adaptive WM, HeartSync, HRD, Resonance Breathing & Neural Speech Tracking | Live per-channel Signal Quality & passive impedance (`kΩ`), docked Welch PSD, live ERPs & sleep hypnograms |
| Online Rust **ASR + OSCAR** cleaning (CleanLine, ASR, EOG regression, EMG/slew suppression) | VSync-locked visual frames & zero-jitter auditory markers across paradigms | Standards-compliant **EDF+ (`EDF+C`)** with native TAL annotations + companion CSVs & PDF/SVG reports |
| Hardware-timestamped **Webcam Video & Audio** (`.mp4` + `_av_sync.json`) | Dichotic L/R stereo speech attention decoding via backward TRF (works even on few channels) | Multi-profile device presets, single-directory exports & SHA-256 verified in-app updates |

---

## 🔬 Research Modules

### 1. Standalone EEG / fNIRS Recorder
The high-performance shared viewing, cleaning, and recording engine used across the studio and available directly for resting or task EEG/fNIRS sessions ([guide](docs/eeg_recorder_and_cleaning.md)):
* **Screen-Space Optimized Plotter:** Zero-shift circular ring buffers (`Float64RingBuffer`), min-max pixel-column decimation, autoscale/fixed gain, Page vs. Roll sweep modes, and crisp light clinical trace rendering.
* **Montage & Per-Channel Filter Editor:** Rename channels, switch references (`CAR`, linked mastoid, bipolar, native), toggle quick **Hide** or **Prominent/Solo** zoom per channel, and assign channel-specific HP/LP/Notch display filters (unfiltered raw samples are always preserved in EDF+).
* **Real-Time Signal Quality & Passive Impedance:** Dedicated compact `Z / SQI` monitor powered by Rust batch DSP (`ccs_signal_quality_batch`) reporting live impedance estimates (`kΩ`) and clean/noisy flags without stealing waveform space.
* **Live Welch PSD & Event Markers:** Docked side/bottom real-time Welch power spectrum viewer (`0–45 / 0–70 / 0–125 Hz`, delta–gamma band breakdown) computed in Rust (`ccs_welch_psd`), plus 1-tap preset and custom markers aligned cleanly in both **Roll** and **Page** sweep modes.
* **Realtime Rust ASR + OSCAR Cleaning:** Toggle non-destructive live signal cleaning (`CleanLine` 50/60 Hz + harmonics, sliding-window ASR subspace reconstruction, gated frontal EOG blink regression, and EMG/slew pop suppression) with live `% Cleaned` feedback.
* **Time-Synched Webcam Video & Audio:** Capture hardware-clocked `.mp4` video + audio (`AvSyncRecorder` on macOS) synchronized with `AV_SYNC_START` / `AV_SYNC_STOP` EDF+ annotations and `_av_sync.json` drift/offset telemetry.
* **Native EDF+ (`EDF+C`) & User-Definable Export Folder:** Embeds `EDF Annotations` TAL events directly inside `.edf` files, writes directly under your configured output folder (no duplicate staging subfolders), and supports automatic reconnect segments (`_part2`, `_part3`).

### 2. Train NIDRA — Sleep Staging & Closed-Loop Auditory Stimulation
* Real-time 30-second epoch staging via **TinySleepNet ONNX** running natively in Rust (`tract-onnx`).
* **Leads-Off & Artifact Gating:** Validates amplitude (`2.5–400 µV`) to flag `LEADS OFF` epochs and prevent false REM scoring.
* **ACLS Stimulus Library & Playlist:** Sequential/randomized `.wav`/`.mp3`/`.ogg`/`.flac` cues, per-cue trigger codes written into EDF+ TAL & CSV logs, refractory/snooze controls, and live hypnogram + stage-probability + marker overlays.

### 3. ANGEL — Cognitive ERP Battery
* Bundled **Level 2** and **Level 3** E-Prime-derived paradigms with **English, Hindi, and Kannada** stimulus sets, VSync-locked visual marker timestamps, and automated PDF summary reports.

### 4. Conventional ERP & Standardized ERP CORE Laboratory
* Complete implementation of all **6 ERP CORE paradigms** ([documentation](docs/erp_core.md)): **N170** (faces/cars/scrambled), **MMN** (passive auditory deviant), **N2pc** (visual search lateralized target), **N400** (semantic word-pair priming), **P3b** (target letter oddball), and **ERN / LRP Flankers** (congruent/incongruent speeded flanker).
* Flexible classic visual/auditory oddball, N400, P50, MMN, and N170 tasks alongside **Real-Time ERP** averaging and live **Difference Wave** (`Target − Standard`) plotting with component-window overlays and zero-jitter visual/auditory scheduling.

### 5. Adaptive WM — Working Memory Task
* Adaptive working-memory trial runner with frame-locked marker timing and automated PDF summary reporting.

### 6. HeartSync — Cardiac-Phase Oddball
* Heartbeat-locked systolic/diastolic stimulus scheduling from live ECG/PPG, offline CSV replay tools, and cardiac-phase distribution plots.

### 7. Heart Rate Discrimination (HRD) — Bayesian Psi
* Interoceptive heart-rate comparison using xAMP-L10 ECG or Orbit PPG with procedural pulse audio, visual countdown, catch trials, and **Confidence & Metacognitive Insight** calibration ratings ([documentation](docs/hrd.md)).
* Native Rust NeuroKit2-parity ECG pipeline (`0.5 Hz` SOS HP, 50 Hz notch, R-peak detection, Kubios artifact correction) + SciPy fallback, signed marginal-Psi estimation, SVG curves, and detailed PDF reports.

### 8. Heartbeat Evoked Potential (HEP)
* 5-minute resting EEG + ECG capture with causal bandpass filtering, R-peak detection, deterministic midpoint-RR pseudotrial controls, and live SEM waveform plots ([documentation](docs/hep.md)).

### 9. Individual Resonance Breathing
* Guided adult paced-breathing assessment (conventional rate sweep + experimental Bayesian adaptive method) with live cardiac interval tracking, comfort gating, confirmation epoch, and scientific references ([documentation](docs/resonance_breathing.md)).

### 10. Sleepiness Scale
* Standalone Stanford Sleepiness Scale (SSS) logging into standardized CSVs at any point in a protocol.

### 11. Dichotic Neural Speech Tracking *(New in v1.0.12)*
* Presents two simultaneous, independent speech audio files in **true stereo separation** (Left vs. Right ear) across configurable attention blocks ([documentation](docs/neural_speech_tracking.md)).
* Extracts multi-feature speech representations (envelope + acoustic derivative / onset features) and trains/evaluates a **native Rust backward Temporal Response Function (TRF)** decoder (`rust/src/speech_tracking.rs`) across all or any user-selected subset of EEG channels — engineered to remain informative even when only a few electrodes are connected.
* Reports block-wise attentional decoding scores (`r_left`, `r_right`, predicted focus, confidence) and exports full session JSON/CSV telemetry under the `SPEECH` module tag.

---

## 🌐 Cross-Module Platform Features

* **Global Subject ID & Output Root:** Entered once, inherited by every module, and exported cleanly to `<OutputFolder>/<Subject>/...` without redundant subfolders.
* **Study Run Sequence & Quick Edit Flow:** Reorderable checklist on the home screen; clicking **Edit Flow** opens directly to Settings → **Output & Study Flow**.
* **Multi-Profile Device Presets:** Define, duplicate, import, export JSON, project-tag, and switch multiple profiles for the same hardware amplifier (e.g., *Sleep PSG 4-ch* vs. *ERP 16-ch*) directly from Settings or the Connect dialog.
* **Cold-Start Reliable BLE + Multi-Stream LSL:** Fixed first-open BLE scan stalls on macOS (`flutter_blue_plus`), added explicit Scan/Stop state control, and unified BLE + LSL + 16-ch Simulation into a clean uncluttered Connect dialog.
* **Standardized File Naming:** `<subject>_<MODULE>_<yyyyMMdd_HHmmss>[_partN].<ext>`, where `MODULE` includes `NIDRA`, `ANGEL`, `WM`, `EEG`, `HEARTSYNC`, `HRD`, `HEP`, `RESONANCE`, `SPEECH`, and `SSS`.
* **In-App Updates:** Automatic and manual update checks against GitHub Releases with release-note previews, active-recording safety deferral, SHA-256 checksum verification, and one-tap platform upgrades.

---

## ⚡ Architecture

* **Frontend:** Flutter (Dart), Material 3 (`StudioTheme.light()` clinical theme matching CCS_SleepStudio), `provider` state management under `lib/modules/*` and `lib/core/*`.
* **Native Core (`rust/` — `train_nidra_core`):** Compiled natively for macOS universal (`x86_64` + `arm64`), Android ABIs (`arm64-v8a`, `armeabi-v7a`, `x86_64`), and Windows `x64`. Owns:
  * **EDF+ (`EDF+C`) writer:** Native TAL annotations & multi-channel calibrated physical/digital encoding (`src/lib.rs`).
  * **DSP, PSD & Signal Quality:** `ccs_welch_psd`, `ccs_signal_quality_batch` (`src/dsp.rs`, `src/lib.rs`).
  * **Realtime EEG Cleaning:** `ccs_cleaner_new` / `process` (`src/cleaning.rs` — CleanLine, sliding-window ASR, gated EOG regression, EMG/slew suppression).
  * **Neural Speech Tracking:** Regularized multi-feature backward TRF (`src/speech_tracking.rs`).
  * **TinySleepNet ONNX (`tract-onnx`):** Real-time sleep stage probabilities (`src/lib.rs`).
  * **HRD NeuroKit2 & Marginal-Psi Engine:** (`src/hrd.rs`).
* **Native Platform Bridges:** macOS AVFoundation hardware-clocked webcam A/V sync (`macos/Runner/AvSyncRecorder.swift`), `flutter_blue_plus` / `flutter_bluetooth_serial` BLE, `liblsl` WiFi LSL streams.

```text
lib/
├── core/
│   ├── eeg/          # acquisition, EDF+ recorder, display filters, native FFI bindings
│   ├── models/       # EEG/fNIRS samples, device profiles, sleep scores, module types
│   ├── services/     # BLE coordinator, session manager, file naming, update service
│   ├── theme/        # StudioColors & StudioTheme.light() (CCS_SleepStudio aesthetic)
│   └── widgets/      # 60 FPS painters, PSD viewer, SQI/Z panel, AV sync controls
├── modules/
│   ├── home/         # clinical dashboard & study sequence
│   ├── standalone/   # EEG/fNIRS recorder, montage/filter editor, ASR cleaning, AV sync
│   ├── nidra/        # Train NIDRA sleep staging & ACLS playlist
│   ├── angel/        # ANGEL cognitive ERP battery & PDF reports
│   ├── generic_erp/  # Conventional ERP + 6 ERP CORE paradigms & realtime ERPs
│   ├── adaptive_wm/  # Adaptive working-memory task & PDF reports
│   ├── heartsync/    # Cardiac-phase oddball & replay
│   ├── hrd/          # Heart Rate Discrimination (Bayesian Psi + confidence)
│   ├── hep/          # Heartbeat Evoked Potential
│   ├── resonance/    # Individual Resonance Breathing
│   ├── speech_tracking/ # Dichotic Neural Speech Tracking (TRF decoder)
│   ├── sleepiness/   # Stanford Sleepiness Scale
│   └── settings/     # Multi-profile channels, network/display, output & study flow
rust/src/             # Native FFI core (EDF+, DSP, ASR cleaning, TRF, ONNX, HRD)
docs/                 # Protocol, pipeline, and validation documentation
scripts/              # Firebase deploy & macOS Developer ID / notarization scripts
```

---

## 🔌 Hardware Supported

| Signal | Device (Example) | Transport |
| :--- | :--- | :--- |
| **EEG / EOG / EMG / ECG** | Axxonet **xAMP-L10**, **EpiDome** | Bluetooth LE / Classic |
| **EEG / PPG** | Neurostellar **Orbit** | Bluetooth LE |
| **fNIRS / Generic Multi-Stream** | NIRSport 2 / any LSL inlet | WiFi (Lab Streaming Layer / LSL) |
| **A/V Context** | Integrated or USB Webcam & Mic | AVFoundation (`_av_sync.json` + EDF+ TAL) |

---

## 🚀 Building from Source

### Prerequisites
* [Flutter SDK](https://docs.flutter.dev/get-started/install) (3.24+ / 3.41+)
* [Rust Toolchain](https://www.rust-lang.org/tools/install) (`cargo` and `rustc` 1.75+)
* For Android builds: Android NDK (r25+) and `cargo-ndk` (`cargo install cargo-ndk`)

### 1. Build the Native Rust Core
For Android ABIs:
```sh
cd rust
chmod +x build_android.sh
./build_android.sh
cd ..
```

For desktop platforms (macOS / Windows):
```sh
cd rust
cargo build --release
cd ..
```

### 2. Running & Packaging
```sh
flutter pub get

# Run locally
flutter run -d macos      # or windows / <android-device-id>

# Package releases
flutter build apk --release
flutter build macos --release
flutter build windows --release

# macOS Developer ID signing (+ optional Apple Notarization)
./scripts/sign_and_notarize_macos.sh \
  --app "build/macos/Build/Products/Release/CCS Mobile Studio.app" \
  --out-dir dist
```

---

## 📚 Documentation & Wiki

* **[Documentation & Wiki Index](docs/wiki/Home.md)** — Step-by-step operator guides for acquisition, cleaning, paradigms, and updates.
* [Standalone EEG Recorder, Signal Quality & ASR Cleaning](docs/eeg_recorder_and_cleaning.md)
* [ERP CORE & Conventional ERP Laboratory](docs/erp_core.md)
* [Dichotic Neural Speech Tracking (TRF)](docs/neural_speech_tracking.md)
* [Heart Rate Discrimination (HRD)](docs/hrd.md) · [HRD Validation](docs/hrd_validation.md)
* [Heartbeat Evoked Potential (HEP)](docs/hep.md)
* [Individual Resonance Breathing](docs/resonance_breathing.md)
* [In-App Updates Guide](docs/auto_updates.md)

---

## 🤝 Research Collaboration & Acknowledgments

**CCS Mobile Studio** is developed as a joint research and neurotechnology engineering collaboration by:

* **Centre for Consciousness Studies (CCS)**, *Department of Neurophysiology*, **National Institute of Mental Health and Neurosciences (NIMHANS)**, Bengaluru, India.
* **Axxonet** ([https://axxonet.com/](https://axxonet.com/)) — EEG instrumentation, neurofeedback systems, and cognitive neuroscience platforms.
* **Neurostellar** ([https://www.neuro-stellar.com/](https://www.neuro-stellar.com/)) — Non-invasive physiological monitoring and clinical-grade health platforms.

---

## 📝 Repository Notes

* `rust/target/` is excluded from version control via `.gitignore` — build locally with `rust/build_android.sh` or `cargo build --release`.
* Compiled `.so` files under `android/app/src/main/jniLibs/` are tracked for direct Android builds; regenerate with `rust/build_android.sh` after editing Rust code.
