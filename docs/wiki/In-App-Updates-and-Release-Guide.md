# In-App Updates & Release Guide

## How In-App Updates Work
CCS Mobile Studio checks `https://api.github.com/repos/CCS-NIMHANS/CCS_MobileStudio/releases/latest` at startup (optional) and on demand via the **Update** button in the dashboard toolbar or Settings screen.

- Compares semantic version + build number (`v1.0.12+15` > `v1.0.11+12`).
- Displays Markdown release notes and verifies downloaded packages against GitHub Release **SHA-256** checksums before installation:
  - **macOS:** `CCSMobileStudio-macos.zip` (universal `x86_64` + `arm64`)
  - **Windows:** `CCSMobileStudio-Windows.zip` (`x64`)
  - **Android:** `CCSMobileStudio-Android.apk` (universal ABI APK)
- Deferral protection prevents interrupting an active recording session.

## Developer ID Signing & Notarization (macOS)
Local builds can be signed inside-out with Hardened Runtime (and optionally notarized & stapled) using:
```sh
./scripts/sign_and_notarize_macos.sh \
  --app "build/macos/Build/Products/Release/CCS Mobile Studio.app" \
  --out-dir dist
```
Pass `MACOS_NOTARY_KEYCHAIN_PROFILE=AC_PASSWORD` (after storing credentials once via `xcrun notarytool store-credentials AC_PASSWORD`) to generate a notarized `.dmg` and `.zip`.
