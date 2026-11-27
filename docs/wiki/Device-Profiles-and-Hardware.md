# Device Profiles & Hardware Management

## Supported Hardware
| Device / Stream | Signals | Connection |
| :--- | :--- | :--- |
| Axxonet **xAMP-L10** / **EpiDome** | Multi-channel EEG, EOG, EMG, ECG | Bluetooth LE / Classic |
| Neurostellar **Orbit** | Frontal EEG + PPG | Bluetooth LE |
| **NIRSport 2** / Generic LSL | fNIRS / arbitrary polygraphic LSL streams | WiFi (Lab Streaming Layer) |
| **16-ch Built-in Simulator** | Synthetic multi-channel EEG/ECG/EOG | Local bench simulator |

## Cold-Start BLE Discovery Fix
- First-time BLE scans decouple adapter discovery from stale GATT caches and provide explicit `Scan` / `Stop` state feedback so amplifiers appear reliably on initial modal open without closing and reopening the dialog.

## Multi-Profile Device Configuration
Open **Settings → Channel Configuration**:
- Maintain multiple independent profiles for the same hardware device (e.g., *xAMP-L10 · Sleep PSG 4-ch*, *xAMP-L10 · ERP CORE 16-ch*, *Orbit · HRD PPG*).
- Assign **Project / Study Tags**, pick channel role templates, duplicate profiles in one tap, mark a **Default** profile per hardware family, or **Import / Export JSON** profiles to share across lab workstations.
- Switch active profiles directly inside the **Connect** dialog without leaving your session.
