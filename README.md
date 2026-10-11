# apk-mitm Termux Auto Installer

One-command installer that makes [apk-mitm](https://github.com/shroudedcode/apk-mitm) work on **Termux (aarch64 / ARM64)**.

apk-mitm patches an APK so that its HTTPS traffic can be inspected (e.g. with mitmproxy). The upstream package assumes a desktop Android SDK setup, so it fails on Termux. This installer patches it with Termux-native tooling, App Bundle handling and correct signing.

## Features

- **Termux-native aapt2** auto-detection for `apktool` (decode/encode).
- **zipalign** for aarch64 pulled from the [rendiix](https://github.com/rendiix) repo.
- **Legacy `$`-prefixed resource sanitizer** so `aapt2` no longer crashes on App Bundle base-split APKs.
- **App Bundle split flags strip** (`isSplitRequired` and `com.android.vending.splits*` meta-data) for standalone installs.
- **Correct APK signing** via a fixed `uber-apk-signer` v1.3.0 build.
- Idempotent: skips re-downloading when the correct versions are already present.

## Requirements

- Termux (F-Droid or GitHub build)
- aarch64 / ARM64 device
- Internet connection
- ~1 GB free storage (Node.js + OpenJDK 17)

## Installation

```bash
git clone https://github.com/Skcode-X/apk-mitm-termux-setup.git
cd apk-mitm-termux-setup
bash apk-mitm-termux-setup.sh
```

The first run may take **5-10 minutes** while dependencies are installed.

## Usage

Patch an APK:

```bash
apk-mitm app.apk
```

Output is written to `./app-patched.apk`.

Common options:

```bash
apk-mitm app.apk --wait           # pause so you can edit the decoded files
apk-mitm app.apk --debuggable     # set android:debuggable="true"
apk-mitm app.apk -o custom.apk    # custom output path
```

See `apk-mitm --help` for the full list.

## How it works

The installer installs `apk-mitm` globally via npm and then overwrites a few files inside its `dist/` directory:

| Patched file | Purpose |
| --- | --- |
| `tasks/sanitize-resources.js` | Renames legacy `$`-prefixed resources and updates XML references |
| `tasks/modify-manifest.js` | Strips App Bundle split flags and meta-data |
| `tools/apktool.js` | Auto-detects the Termux-native `aapt2` binary |
| `tools/uber-apk-signer.js` | Auto-detects `zipalign` and signs correctly |
| `patch-apk.js` | Inserts the resource sanitize step into the pipeline |

## Verifying the install

```bash
apk-mitm --version
node -e "require('$(npm root -g)/apk-mitm/dist/tools/apktool.js')"
```

## Uninstall

```bash
npm uninstall -g apk-mitm
```

The `rendiix` apt source can be removed from `$PREFIX/etc/apt/sources.list.d/rendiix.list`.

## Notes

- Package versions are pinned to `apk-mitm@1.3.0`, Apktool `2.9.3` and `uber-apk-signer` `1.3.0`.
- Dedicated to educational purposes and testing apps you own or are authorized to test.

## License

MIT
