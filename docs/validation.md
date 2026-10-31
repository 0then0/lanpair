# Testing and platform validation

LANPair separates build evidence, automated behavior checks, native-runner tests and physical two-device tests. Passing one level does not establish the next: loopback sockets cannot verify a phone's local-network permission prompt or a LAN's multicast behavior.

## Run automated checks

Use Flutter 3.47.8/Dart 3.13.7, Python 3 and the committed lockfile. From a checkout with the native prerequisites installed:

```sh
flutter pub get --enforce-lockfile
flutter gen-l10n
python3 tool/check_l10n.py
dart format --output=none --set-exit-if-changed lib test integration_test tool
flutter analyze
flutter test
```

`flutter test` includes:

- session/invitation validation and strict, bounded report imports;
- interpretation by direction and address family, lost acknowledgements, duplicate/conflicting observations and journal reconciliation;
- actual loopback TCP/UDP, pinned HTTPS, deadlines, cancellation and resource cleanup;
- staggered and too-late independent starts, TCP participant proof against silent, garbage-answering and echoing listeners, connecting to this device's own address, and DNS-SD error direction;
- control listener ownership across inactive, paused and resumed transitions and new sessions;
- endpoint synchronization over real loopback control listeners: an interface change after joining, a choice made before joining, confirmation tied to the current revision, superseded sessions and listeners, bounded and unreachable exchanges, a busy control port, simultaneous changes, 0.1.1 peers and journals that disagree about an endpoint;
- report history and preservation of existing journals;
- locally rendered QR decoding, including rotated codes and ambiguous invitations;
- widget, localization, text-scaling, control-label and tap-target checks.

The default socket tests use ephemeral loopback resources. They do not change firewall rules or require another device. To focus on network/report behavior:

```sh
flutter test test/engine_test.dart test/report_test.dart
```

The localization checker verifies message/placeholder coverage. Widget tests exercise narrow/mobile and desktop sizes, enlarged text and platform variants. Neither is professional linguistic review or accessibility certification. Check real fonts, screen readers, keyboard focus and native dialogs on the relevant device before releasing UI changes.

QR decoder tests do not establish camera permission handling, lens focus, physical-screen scanning or preview orientation. Verify those separately on Android and iOS.

## Check a native runner

On the appropriate host, build the native target and run its integration test:

```sh
flutter build <target> --release
flutter test integration_test/app_test.dart -d <device-id>
```

Use a desktop target (`linux`, `windows`, `macos`), `apk` for Android, or `ios --no-codesign` for an unsigned iOS compilation. Choose the device ID with `flutter devices`. An iOS physical-device run requires signing; see [distribution](distribution.md).

The integration test checks method-channel registration, capabilities and application startup. It does not prove that DNS-SD resolves a peer, the share sheet exports correctly, or physical probes pass.

CI defines checks and native builds on platform-appropriate runners. Linux's startup integration check uses Xvfb and a D-Bus session. Workflow definitions are not execution evidence; inspect the checks for the exact commit being reviewed.

## Platform validation

The validation available for v0.1 is described below. Native builds and the Linux startup test run in [CI](https://github.com/0then0/lanpair/actions/workflows/ci.yml); check the result for the exact commit you use.

- **Android:** CI compiles the debug APK. Debug and unsigned release APKs were also compiled locally against API 37.0, targeting API 37; a debug signature and release checksum were checked. The unsigned release APK cannot be installed. No installation on any Android version, including Android 17, has been performed or verified; see [installing on Android](distribution.md#installing-on-android). Emulator and physical-device/LAN behavior remain unverified.
- **macOS:** CI checks release compilation. Shared automated tests also run on a macOS host. Native application runtime, installation and physical LAN behavior remain unverified.
- **iOS:** CI checks unsigned release compilation; shared UI tests include the iOS platform variant. Simulator and physical-device tests remain unverified. Raw multicast is disabled in the default build.
- **Windows:** CI checks release compilation. Native application runtime and physical LAN behavior remain unverified.
- **Linux:** CI checks release compilation and application startup under Xvfb/D-Bus, including native channel registration. Peer DNS-SD/Avahi behavior and physical LAN probes remain unverified.

This evidence describes the kinds of checks completed, not certification of every platform or a promise that an arbitrary later checkout has passed. Validate the exact commit and artifacts you intend to use. Update this section when additional reproducible native/device evidence is available.

## Physical two-device procedure

Use two devices and a LAN whose owners have authorized testing. Build/install the same app version on both devices. Record the commit, app version, OS/build, device, selected interface, address family and permission state. Keep both apps visible, pair explicitly and retain both original journals privately.

Run these scenarios:

1. **TCP/UDP in both directions.** Start a coordinated run with normal connectivity. Verify separate outgoing TCP connections and distinguish UDP sends, peer receipts and acknowledgements in both journals. Test IPv4 and IPv6 independently when the LAN supplies both.
2. **Asymmetric reachability.** On an isolated lab setup, restrict one direction and repeat the run. Confirm the result identifies which observations are missing without claiming the restriction's cause. Do not change a contributor's working firewall or shared network to create this condition.
3. **Unicast passes, multicast is unobserved.** Retain positive direct observations while comparing multicast sends and peer receipts. Verify own-device packets cannot establish success. Test raw multicast separately from DNS-SD; an unsupported raw probe does not reproduce packet loss.
4. **Permission denied and restored.** Deny local-network access in system Settings, inspect readiness and run behavior, then grant access, return to the app and refresh readiness. Start a new run and verify recovery. Check native prompts as well as capability labels.
5. **No control channel.** Transfer the same invitation offline, enter endpoints manually, and start the independent runs. Repeat with the second start after about 1, 3 and 5 seconds. Expect the early offsets to be reached in both directions and the late one to leave the first device's direction `inconclusive` (not `failed`) while the other direction passes. Also try the peer address of the device itself, a different application listening on the TCP port and a peer that is not running. Export both original JSONs, transfer them privately and merge. Missing delivery evidence must remain inconclusive. Check file dialogs or the mobile share sheet on both devices.
6. **Interface change and re-agreement.** Select the LAN interface on both devices (for example `en0` on a Mac and `wlan0` on a phone, not a tunnel adapter), create a session and join it. On both devices the "Peer parameters" row must read passed. Start a coordinated run and export both journals. Then create a new session, change the interface on one device to another one and back, and confirm the row leaves "passed" while the exchange is pending or fails, and returns to passed with the current interface on both devices without restarting either app. Run again and export both journals. In each journal `devices` must show the interface actually selected on each device at the start of that run, `peerReadiness` must be `confirmed` only for runs started while the row was passed, and the merged journal must show no endpoint mismatch. Repeat once with the other device's control port blocked or its app suspended: the row must say why it is unconfirmed and an independent run must remain possible. IPv6 failures need their own evidence: record the sanitized error codes per family and direction.
7. **Interruption.** Background the app or change the network during the active window. Confirm the saved journal records interruption, collected positive observations remain available, resources are released and a new session can run afterward.

Exact clock synchronization is unnecessary. Local stopwatch durations belong to their reporting device, and neither a peer's wall clock nor its stopwatch is compared with the local one. Independent windows must overlap for positive receipt evidence, and overlap alone is not enough: see [coordinated and independent starts](protocol.md#coordinated-and-independent-starts).

On iOS, raw multicast requires an entitlement-approved physical build; see [platform notes](platforms.md#ios). A simulator cannot establish the behavior of local-network privacy or the signed multicast entitlement.

Also check refusal/re-grant of camera permission, returning from Settings, multiple network adapters, IPv6 scope identifiers, occupied ports, unavailable DNS-SD, export cancellation and receiving a shared file.

## Report validation evidence

Attach the following to a pull request or release record:

- commit and artifact checksum;
- toolchain, host, OS/device and relevant permissions/interfaces;
- exact commands or interaction steps and observed results;
- whether the evidence comes from a build, automated test, emulator/simulator or physical devices;
- remaining limitations and sanitized error codes.

Use synthetic or redacted examples in public reports. Never attach pairing invitations, secrets, private keys or unredacted journals. A timeout is evidence that an expected event was not observed, not proof of a firewall, router or permission rule. State failures and unavailable checks explicitly rather than upgrading them to platform support.
