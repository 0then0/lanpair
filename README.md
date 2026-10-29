<p><img src="assets/icon.svg" width="88" height="88" alt="A computer and phone exchanging diagnostic probes"></p>

# LANPair

[![License: Apache 2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
[![Flutter 3.47.8](https://img.shields.io/badge/Flutter-3.47.8-02569B.svg)](https://docs.flutter.dev/install/archive)
[![CI](https://github.com/0then0/lanpair/actions/workflows/ci.yml/badge.svg)](https://github.com/0then0/lanpair/actions/workflows/ci.yml)

LANPair diagnoses connectivity **between two devices you explicitly pair** on a local network. It checks each direction separately, distinguishes direct connections from service discovery, and combines both devices' observations into a report.

For example:

> TCP connections succeeded in both directions. Device B did not record receiving A's test multicast packets during its observation window.

A timeout records an event that was not observed. It does not identify a router, firewall, or permission rule as the cause. A successful LANPair check also cannot prove another application's connectivity: that application's ports, permissions, firewall rules and discovery mechanisms may differ.

LANPair v0.1 includes Android, iOS, macOS, Windows and Linux runners. CI runs the shared checks and native builds, including a Linux startup integration check. A successful build does not establish physical two-device LAN behavior, which remains unverified. Check [CI for the commit you use](https://github.com/0then0/lanpair/actions/workflows/ci.yml) and [platform validation](docs/validation.md#platform-validation) for the coverage and remaining checks. Build from source using the instructions below; signing and installation requirements are described in [distribution](docs/distribution.md).

## What it checks

- A separate outgoing TCP connection in each direction.
- Small authenticated UDP unicast probes, distinguishing local sends, peer receipts and returned acknowledgements.
- Raw multicast probes on the selected interface, with IPv4 and IPv6 checked separately. Receiving the device's own packets cannot count as success.
- Publication, discovery and resolution of LANPair's `_lanpair._tcp` service through Android NSD, Apple Bonjour, Windows DNS-SD or Linux Avahi.
- Available network addresses, permission information and platform limitations.

Each run has a finite observation window, a small fixed packet budget and cancellation. IPv6 without a usable address is reported as unsupported. Suspension or a network change interrupts the run and requires a new one.

There is no backend, account, telemetry, subnet scan, port sweep, traffic capture, speed test, VPN or continuous monitoring. LANPair never changes firewall or router settings.

## Build and run

Install [Flutter stable 3.47.8](https://docs.flutter.dev/install/archive), which includes Dart 3.13.7, and the [native toolchain for your target](https://docs.flutter.dev/platform-integration). Run `flutter doctor -v` to check your installation.

```sh
git clone https://github.com/0then0/lanpair.git
cd lanpair
flutter pub get --enforce-lockfile
flutter gen-l10n
flutter devices
flutter run -d <device-id>
```

Replace `<device-id>` with an ID from `flutter devices`. Desktop target IDs include `macos`, `windows` and `linux` on the corresponding host. Run a copy on both participating devices.

Target prerequisites:

- **Android:** Java 17, Android SDK Platform 37.0 and Flutter's Android build tools. The app targets API 37.
- **iOS/macOS:** full Xcode with the selected native SDK. Installing on an iOS device also requires a development team and provisioning.
- **Windows:** Visual Studio with the desktop C++ workload and the Windows SDK.
- **Linux:** Clang, CMake, Ninja, pkg-config, GTK 3 development headers and the C++ standard library. A running system Avahi service is needed for DNS-SD only.

On Debian/Ubuntu, the Linux build prerequisites can be installed with:

```sh
sudo apt-get install clang cmake ninja-build pkg-config libgtk-3-dev libstdc++-12-dev
```

See [platform notes](docs/platforms.md) for permissions, native adapters and OS-specific restrictions, and [distribution](docs/distribution.md) for release builds, signing and checksums.

## Diagnose two devices

1. On device **A**, create a session and select the interface connected to the intended LAN.
2. Transfer the invitation to **B** using a QR code, pasted text or an invitation file. The invitation contains credentials; share it only with the selected device. Camera scanning is available on Android and iOS. Desktop devices use paste or files.
3. On B, join the session and check the selected interface. If the authenticated HTTPS channel is available, the devices exchange their endpoints. Service discovery is not required to join.
4. Review readiness and keep both apps visible. Start the bounded checks. When the control channel works, LANPair coordinates the peer's listeners before sending probes.
5. Read **A → B** and **B → A** separately. Open a check to inspect its raw observations, reporting device, interface, packet sequence and elapsed time.
6. Export JSON for journal reconciliation, or a localized readable report for sharing. Reports are saved in History. Create a new session for another experiment; a completed run ID cannot be reused.

A missing UDP acknowledgement does not prove missing delivery. The receiving device may have recorded the packet even if its acknowledgement was lost. Combining the journals can resolve that uncertainty.

### When the control channel does not work

1. Transfer the same invitation from A to B using an available offline method.
2. Enter B's numeric address on A under **Manual peer address**, and verify A's address on B. The TCP port is editable. UDP, HTTPS control and multicast use ports 45832, 45833 and 45834 in v0.1.
3. Start each device independently while both apps are visible. The default window is six seconds. The devices do not need synchronized clocks, but their observation windows must overlap for packets to be received.
4. Export each device's **original, unredacted JSON** and transfer the files privately.
5. Open a journal in History and import its counterpart. Review the combined results, then export a redacted copy for sharing.

LANPair checks the session, run, ordered participants, parameters and format versions before merging. Identical observations are deduplicated; conflicts are rejected. Journals from different runs cannot be merged. Imported journals are participant statements, not cryptographic proof of network events.

## Reports and privacy

Reports include session/run/device identifiers, platform capabilities, test parameters, addresses, interface names, observations, UTC wall times and independent monotonic durations. Invitation credentials, session secrets and TLS private keys are excluded.

The export dialog previews endpoint address/interface information and defaults to redaction. Redacted exports replace addresses and interface names with consistent aliases, suppress arbitrary capability values and remove precise wall times. Session-scoped identifiers, ports, platforms and event correlations remain. Redaction does not guarantee anonymity.

JSON is language-independent and can be imported. Readable reports follow the selected interface language and are intended for people. Original and redacted journals cannot be merged together: reconcile originals privately first, then redact the result.

Only report history is saved automatically. Live session credentials remain in memory, but invitations you explicitly save and reports you export can outlive the session. History is ordinary application-support data rather than an encrypted vault. Clipboard contents and the system share sheet are controlled by the OS. See the [security policy](SECURITY.md) before sharing evidence.

## Platform limits

Raw multicast, LANPair service discovery and another application's discovery are distinct checks. The default iOS build disables raw multicast because it requires Apple's restricted entitlement. Bonjour and direct checks remain separate; an approved custom build can enable the raw probe as described in [platform notes](docs/platforms.md#ios).

System permissions, firewall rules and service-discovery availability vary by platform. A failed or unsupported native operation is recorded explicitly. Background execution is not promised. See [validation](docs/validation.md) for automated coverage and the physical-device procedure.

## Languages and accessibility

English is the source and fallback language. Russian, Spanish, German, French, Japanese and Brazilian Portuguese are included. The app supports system/light/dark themes, keyboard shortcuts, text scaling and screen-reader labels. Check states have text and icons as well as color. Android uses Material controls; Apple platforms use adaptive navigation, menus and dialogs.

Automated layout and accessibility checks do not replace linguistic review, screen-reader testing or checks on native devices. Keyboard shortcuts are listed in Settings.

## Contribute and learn more

Start with [CONTRIBUTING.md](CONTRIBUTING.md) for setup, code organization, checks and pull requests. Follow the [code of conduct](CODE_OF_CONDUCT.md) in project discussions.

- [Protocol, interpretation and report format](docs/protocol.md)
- [Native platform integrations and permissions](docs/platforms.md)
- [Tests and physical validation](docs/validation.md)
- [Builds, signing and distribution](docs/distribution.md)
- [Changes](CHANGELOG.md)
- [Third-party notices](THIRD_PARTY_NOTICES.md)

LANPair is licensed under [Apache-2.0](LICENSE). No custom font files are redistributed; the interface uses platform text fonts and Flutter's Material/Cupertino icon assets.
