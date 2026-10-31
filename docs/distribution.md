# Builds, signing and distribution

This guide covers building LANPair from source, creating complete packages, and signing your own distributions. It does not assume a store account or a signing identity is available.

Use Flutter 3.47.8/Dart 3.13.7 and the committed lockfile. Before building:

```sh
flutter doctor -v
flutter pub get --enforce-lockfile
flutter gen-l10n
```

Install the native toolchain for the target as described in [platform notes](platforms.md). Record the commit, Flutter/native SDK versions and host with each artifact. A lockfile fixes resolved Dart packages; native compiler and SDK differences can still change build output.

## Build a target

Run each command on a host with that target's toolchain:

```sh
# Android
flutter build apk --debug
flutter build apk --release

# Desktop, on the corresponding host
flutter build linux --release
flutter build windows --release
flutter build macos --release

# iOS compilation without signing
flutter build ios --release --no-codesign
```

Android debug builds use the normal development signing workflow and are suitable for local installation/testing. Android release builds are unsigned unless you provide a release signing configuration. The unsigned iOS bundle is not installable; see [iOS signing](#ios-signing).

Build from the current source after changing code, translations or native assets. Do not assume an older package contains those changes. Run the [automated and device checks](validation.md) against the version you intend to distribute.

## Package desktop and Android builds

After a successful release build, package its complete output:

```sh
python3 tool/package_release.py linux
python3 tool/package_release.py windows
python3 tool/package_release.py macos
python3 tool/package_release.py android
```

Run only the command matching the build you produced. The script writes the package and a SHA-256 checksum file to `dist/`, and fails if the expected native bundle is missing. On macOS it writes `lanpair-macos-unsigned.tar.gz` and `lanpair-macos-unsigned.dmg`, each with its checksum. The disk image holds `LANPair.app` and an `Applications` link; it needs `hdiutil` and is created on macOS only. Like the archive it is neither signed nor notarized, so Gatekeeper may ask for confirmation on first open. Copy the app to `/Applications` before running it: the window position and the saved settings belong to the app, not to the folder it was unpacked into. Packages include all required runtime files; a desktop executable by itself is insufficient without its libraries and data directory.

Linux and Windows CI packages target x64. macOS architecture follows the Flutter/native runner configuration; inspect the binary with `file` before advertising supported architectures. Unsigned or ad hoc-signed artifacts may be blocked by OS policy.

Verify the package checksum with the tools for your host:

```sh
# Linux, from dist/
sha256sum -c <package-name>.sha256

# macOS
shasum -a 256 dist/<package-name>
```

On Windows, use `Get-FileHash -Algorithm SHA256` in PowerShell and compare the result with the checksum file. Checksums detect changes to a downloaded file; they do not authenticate its publisher unless the checksum itself comes from a trusted source.

## Android signing

Android compiles against SDK 37.0, targets API 37, and uses Java 17, AGP 9.5.0 and Gradle 9.8.2 (`android/settings.gradle.kts`, `android/gradle/wrapper/gradle-wrapper.properties`). Dependabot updates these files; the previous local builds used AGP 9.1.1 and Gradle 9.3.1, and the current pins have not been built locally. The SDK Manager platform identifier is `platforms;android-37.0`; Flutter also requires its build tools and NDK.

For a signed release, provide your existing keystore through these environment variables:

```sh
export LANPAIR_KEYSTORE_PATH=/absolute/private/path/release.jks
export LANPAIR_KEYSTORE_PASSWORD='your-store-password'
export LANPAIR_KEY_ALIAS='your-key-alias'
export LANPAIR_KEY_PASSWORD='your-key-password'
flutter build apk --release
```

Use your secret manager or local shell environment to supply real values. Keep keystores outside the repository and keep passwords out of logs. Without this configuration, the release APK must be signed with your key before installation. A debug keystore is not substituted for release signing.

Inspect the final APK's manifest and signature, install it on a test device and complete the relevant [physical validation scenarios](validation.md#physical-two-device-procedure). Signing does not establish that local-network permission, discovery or multicast works on the target OS.

`tool/package_release.py android` copies `build/app/outputs/flutter-apk/app-release.apk` and names it `lanpair-android.apk` when it carries a v1 or v2+ signature, and `lanpair-android-unsigned.apk` (with a warning) when it does not. It only detects that a signature is present; it does not verify it or identify the key. Verify with `apksigner verify --verbose --print-certs`.

### Installing on Android

- Package `org.lanpair.lanpair`; minimum Android 7.0 (API 24, the pinned Flutter SDK's default), target and compile API 37 (Android 17). Version name and code come from `pubspec.yaml`: `0.1.2+3` is name 0.1.2, code 3.
- `flutter build apk --release` makes one universal APK (about 66 MB) with `arm64-v8a`, `armeabi-v7a` and `x86_64` libraries. No app bundle, ABI split or ABI filter is configured. The 64-bit libraries of the checked 0.1.0 APK are stored uncompressed, 16 KB aligned, with 16 KB or larger ELF segment alignment.
- **An unsigned APK is not installable.** Android requires every APK to carry a signature before it is installed or updated ([app signing](https://developer.android.com/studio/publish/app-signing)). The CI artifact `lanpair-android-unsigned` and `dist/lanpair-android-unsigned.apk` are unsigned by design: no key is configured in the repository or workflow. The installer refuses it on every Android version; the wording of the message varies by device. Sign it with your own key, as described above, before giving it to anyone. A throwaway or debug key is acceptable for one-off testing only: a later release signed with another key cannot update it.
- **Updating** an installed copy requires the same signing certificate and a version code that is not lower than the installed one (increase the number after `+` in `pubspec.yaml` for every APK you distribute). A different key makes the installer refuse the update; uninstalling first removes the app's saved report history.
- A `debug` APK from `flutter build apk --debug` is signed with a debug key and installs, but is not a release.
- `ACCESS_LOCAL_NETWORK` is a runtime permission asked when LANPair first needs the LAN, after installation. It does not decide whether the package installs ([Android local network permission](https://developer.android.com/privacy-and-security/local-network-permission)).
- Google's [developer verification](https://developer.android.com/developer-verification) program requires apps on certified devices to come from registered developers. Google's published plan starts protections on September 30, 2026 in Brazil, Indonesia, Singapore and Thailand and extends them to all regions in 2027, with an advanced flow for unverified apps; the page speaks of installs from participating stores, so check its current wording for sideloaded APKs. It applies to certified devices running Android 7 and newer, not only Android 17. Whether it blocks a given sideloaded LANPair APK depends on the device region and your registration; it cannot be determined from this repository.

When an installation fails, collect: the installer's exact message (or `adb install` output, such as `INSTALL_PARSE_FAILED_NO_CERTIFICATES`, `INSTALL_FAILED_UPDATE_INCOMPATIBLE`, `INSTALL_FAILED_VERSION_DOWNGRADE`), the APK file name and SHA-256, the output of `apksigner verify --print-certs`, the device model, Android build and region, and whether LANPair was installed before.

## macOS signing and notarization

A local macOS app build requires full Xcode and the selected command-line developer directory. Developer ID distribution also requires your own certificate, team and hardened-runtime configuration.

Sign required nested code before the outer app bundle, preserving Flutter's runtime and LANPair's network entitlements. Verify the signed bundle:

```sh
codesign --verify --deep --strict path/to/LANPair.app
```

Create a ZIP with `ditto -c -k --keepParent`, submit it using `xcrun notarytool submit` with your own credentials/profile, and staple the approved ticket:

```sh
xcrun notarytool submit path/to/LANPair.zip --keychain-profile YOUR_PROFILE --wait
xcrun stapler staple path/to/LANPair.app
```

Verify the result and install it on a test Mac. A successful build or ad hoc signature does not replace Developer ID signing or notarization. Follow [Apple's notarization guide](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) and the entitlement notes in [platforms.md](platforms.md#macos).

## Windows and Linux distribution

Windows bundles contain the executable, Flutter/plugin DLLs and data directory. Code signing requires the distributor's certificate; creating a ZIP does not sign the application. Check installation, incoming firewall prompts, network-adapter selection and the system DNS-SD implementation on the intended Windows versions.

Linux bundles depend on GTK and the system C/C++ runtime. Build on the oldest distribution you intend to support and test there; a build produced on a newer system may require a newer glibc. System Avahi is optional for direct TCP/UDP checks and required for DNS-SD. LANPair does not install or configure a system daemon.

## iOS signing

An unsigned `.app` from `flutter build ios --release --no-codesign` proves compilation only. It is not an installable application or IPA.

For a physical device, open `ios/Runner.xcworkspace` in Xcode, choose a development team and the device, and let Xcode provision/sign the app. Run it with Xcode or:

```sh
flutter run -d <device-id>
```

For an archive, use `flutter build ipa --release` with your valid team/profile and an export method appropriate to the certificate. Follow [Flutter's iOS deployment guide](https://docs.flutter.dev/deployment/ios).

Raw multicast remains disabled unless an approved provisioning profile contains Apple's restricted entitlement and the explicit application flag is enabled. See [iOS platform notes](platforms.md#ios). Verify the effective signed entitlements and repeat device testing; a simulator does not establish entitlement or local-network privacy behavior.

## Packaging workflow

The manually dispatched [Release packages workflow](../.github/workflows/packages.yml) builds native desktop bundles (a tar.gz and a DMG on macOS) and an unsigned Android APK, packages them with SHA-256 checksums and uploads workflow artifacts. It does not publish a GitHub release, create a tag, notarize, or submit to a store. iOS signing remains a separate owner-controlled step.

Actions are pinned by commit. Dependabot checks supported ecosystems monthly without automatic merging. Inspect the workflow results for the exact commit before distributing its artifacts. Signing secrets, certificates and store credentials stay outside source control and public artifacts.
