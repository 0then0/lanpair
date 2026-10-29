# Platform integration and distribution

LANPair uses Dart sockets for direct TCP/UDP and raw multicast probes. DNS-SD is a
separate test, implemented with the system responder. A successful DNS-SD test
does not substitute for a raw multicast receive observation.

The native bridge is `lanpair/platform`; its bounded discovery events are on
`lanpair/discovery`. Discovery publishes `_lanpair._tcp` with session and device
identifiers in TXT records. These identifiers are public metadata, not secrets.
Only names belonging to the selected session are resolved, with at most eight
resolution requests per discovery run. Neither discovery nor name resolution
authenticates a peer. The authenticated control channel does that separately.

## Android

The app targets API 37 and compiles against API 37.0 with AGP 9.1.1. Install Android SDK Platform 37 in
addition to the SDK/build tools required by the pinned Flutter SDK. Android 17
requires `ACCESS_LOCAL_NETWORK` at runtime for apps targeting 37 or later. The
manifest declares it, and the native bridge requests it before diagnostics.

Android 16's opt-in local network protection temporarily uses
`NEARBY_WIFI_DEVICES`. On API 36, LANPair can request that grant. A missing grant
on API 36 is reported as `unknown`, because an app cannot infer whether the
device enabled the opt-in restriction from that grant alone. On older OS
versions there is no corresponding general runtime local network grant.

`WifiManager.MulticastLock` is acquired only for an active multicast diagnostic.
It is not reference counted and is released on completion, cancellation,
activity stop, and destruction. The manifest includes `INTERNET`,
`ACCESS_NETWORK_STATE`, `ACCESS_WIFI_STATE`, and `CHANGE_WIFI_MULTICAST_STATE`.
No location permission is requested. Camera use is optional, with paste/file
joining available on camera-free devices.

DNS-SD uses `NsdManager` registration, discovery, and resolution. On API 33 and
later, the selected interface is mapped to an Android `Network` and used by
NSD. On older versions, NSD selects the network; capabilities include
`discovery_interface_system_selected`. Direct socket probes still bind their
selected local address. Resolving is serialized for compatibility with older
NSD implementations. Legacy DNS-SD uses a separate bounded multicast lock. On
API 34 and later, an active resolution is explicitly stopped on cancellation;
older system APIs provide no cancellation method for an already submitted
resolution. Such an OS-owned request may finish later, but its result is ignored
and no new requests are submitted after the run ends. Late callbacks from
previous runs are ignored.

The activity receives permission results and refreshes its observed grant on
return from Settings. Native network callbacks and the Dart address snapshot
detect network changes. A background activity stops discovery and releases its
multicast lock. There is no foreground service or promise of background tests.

Release signing is optional and comes only from environment variables:

```sh
export LANPAIR_KEYSTORE_PATH=/absolute/private/path/release.jks
export LANPAIR_KEYSTORE_PASSWORD='your-store-password'
export LANPAIR_KEY_ALIAS='your-key-alias'
export LANPAIR_KEY_PASSWORD='your-key-password'
flutter build apk --release
```

Without this configuration the release APK is unsigned and cannot be installed
until signed. A debug keystore is never silently used for a release. Keep the
keystore and passwords outside the repository and uploaded artifacts. For local
development, `flutter run` or `flutter build apk --debug` uses the normal Android
debug signing workflow.

Sources: [Android local network permissions](https://developer.android.com/privacy-and-security/local-network-permission),
[Flutter Android local network permissions](https://docs.flutter.dev/platform-integration/android/local-network-permission),
[NsdManager](https://developer.android.com/reference/android/net/nsd/NsdManager),
[MulticastLock](https://developer.android.com/reference/android/net/wifi/WifiManager.MulticastLock).

## iOS

`NSLocalNetworkUsageDescription` explains the selected-device diagnostic.
`NSBonjourServices` contains only `_lanpair._tcp`. Local network and optional
camera descriptions are bundled in all seven project languages.

Raw multicast is disabled in the default iOS build. It requires Apple's
restricted `com.apple.developer.networking.multicast` entitlement on physical
devices. Bonjour for the explicitly declared service remains an independent
available test; a missing multicast entitlement does not disable TCP/UDP unicast.

To enable the raw probe in a custom distribution:

1. Obtain Apple's entitlement approval and a provisioning profile containing it.
2. Add `com.apple.developer.networking.multicast = true` to that target's signing
   entitlements and select the entitlements file in the Xcode target.
3. Set `LANPairRawMulticastEnabled` to Boolean `true` in `ios/Runner/Info.plist`.
4. Sign and install on a physical device; verify the effective signed
   entitlements and repeat the two-device multicast scenario.

The flag is a declaration by the signer, not an entitlement grant. Do not enable
it in an unsigned or unapproved build. The default reports the explicit
`ios_multicast_entitlement_missing` limitation.

Apple has no general local network permission getter. LANPair therefore begins
with `unknown`, uses a bounded `NWBrowser` request to trigger the system prompt,
and records DNS-SD policy-denied errors (`-65570`) as denied. A ready browser is
an observed state for that operation, not a guarantee that every network API or
another app is permitted. Returning to the foreground discards stale permission
observations. DNS-SD registration, browsing, resolving and address resolution use
the system `DNSService*` APIs with the selected interface index. IPv6 link-local
addresses keep their scope identifiers.

iOS may suspend an application when it leaves the foreground. LANPair does not
request background execution for these tests. Interruption ends the planned observation window; positive observations are retained.
Start a new run after returning to the app. The iOS simulator does not exercise
local network privacy or prove that physical multicast entitlements work.

Build an unsigned app bundle with `flutter build ios --release
--no-codesign` on a Mac with the selected Xcode/iOS SDK. This bundle is a build
artifact, **not an installable IPA**. For installation, open
`ios/Runner.xcworkspace`, choose your development team and physical device, let
Xcode provision the app, and run it. For your own distribution, archive with
`flutter build ipa --release` using a valid team/profile and an export method
appropriate to your certificate. No signing identities or store credentials are
included, and the project does not upload to App Store Connect.

Sources: [Apple TN3179: local network privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy),
[multicast entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.multicast),
[Flutter iOS deployment](https://docs.flutter.dev/deployment/ios).

## macOS

Both sandbox configurations declare outgoing and incoming network access. The
sandbox permits user-selected files for invitation/report import and export;
desktop joining uses paste or files and requires no camera access. Local network and Bonjour declarations are
included in the app's `Info.plist`. The same interface-aware system DNS-SD adapter
is used as on iOS. macOS does not require the iOS-only raw multicast entitlement.
Policy denial is recorded explicitly when the system exposes it; a timeout is
never labeled as proof of a privacy or firewall rule.

`flutter build macos --release` produces a local app bundle. A build or ad hoc
signature is not Developer ID signing or notarization. For distribution, use
your own Developer ID Application certificate, enable the hardened runtime,
preserve the app's required Flutter and network entitlements, sign nested
frameworks before the outer bundle, and verify with `codesign --verify --deep
--strict`. Create a ZIP with `ditto -c -k --keepParent`, submit it with
`xcrun notarytool submit ... --keychain-profile YOUR_PROFILE --wait`, then staple
the notarization ticket with `xcrun stapler staple path/to/LANPair.app` and verify
the result. Use your own certificate names, team IDs and credentials. Verify the signed
application on a test Mac before distribution.

Sources: [App Sandbox network client entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.network.client),
[App Sandbox network server entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.network.server),
[notarizing macOS software](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

## Windows

The native runner targets Windows 10/11 and uses the system `dnsapi.dll`
`DnsServiceRegister`, `DnsServiceBrowse`, and `DnsServiceResolve` APIs. Registration
and browsing use the selected interface index. DNS callbacks run outside the
Flutter platform thread, so a bounded event queue marshals them to the runner's
window thread. Stop cancels browsing and resolution and deregisters the service;
callbacks from older runs are discarded. IP interface/address notifications
signal network changes. There is no bundled Bonjour daemon.

Windows Firewall can reject incoming probes independently of outgoing probes.
LANPair displays observed failures and never creates or changes firewall rules.
A firewall consent prompt or a connectivity timeout does not prove which rule
caused a result. The app's own successful socket test says nothing about another
process's firewall policy or port. Release bundles must include the Flutter DLLs
and data folder next to the executable. Windows code signing requires the
distributor's own certificate and is not implied by a ZIP artifact.

Source: [Microsoft DNS-SD API](https://learn.microsoft.com/en-us/windows/win32/api/windns/nf-windns-dnsservicebrowse).

## Linux

The native runner speaks the system Avahi D-Bus API through GLib's `GDBus`,
already supplied by Flutter's GTK dependencies. No additional Avahi library is
bundled or linked. A running `avahi-daemon` on the system bus is required only for
DNS-SD. Missing daemon, D-Bus policy denial, and service errors are exposed; direct
TCP/UDP tests remain independent. Registration/browsing/resolution pass the
selected interface index. Link-local IPv6 results retain a numeric scope.

Install the Flutter Linux build prerequisites (`clang`, `cmake`, `ninja-build`,
`pkg-config`, `libgtk-3-dev`, and `libstdc++-12-dev` on Ubuntu) and, when DNS-SD is
desired, the distribution's `avahi-daemon` package. LANPair does not install,
start, or reconfigure a system daemon. A missing responder is an unsupported
capability, not evidence that multicast is blocked. A bundle built on a newer
Linux distribution may require a newer glibc; build on the oldest distribution
you intend to support and test the actual bundle there.

Sources: [Avahi client API](https://avahi.org/doxygen/html/client_8h.html),
[Avahi D-Bus protocol definitions](https://github.com/avahi/avahi/tree/master/avahi-daemon),
[Flutter Linux setup](https://docs.flutter.dev/platform-integration/linux/setup).

## Verification boundaries

The [validation guide](validation.md) separates full builds, automated tests,
emulator/simulator work and physical-device tests. Verify the exact app build on
the intended devices before claiming support: source inspection and typechecking
do not exercise signing, consent prompts or two-device connectivity.

## Optional camera decoding

QR scanning on Android/iOS uses the Flutter camera adapter and pure
Dart `zxing_lib` QR decoding. Audio is disabled. Frames stay in memory, are bounded
to 2048 pixels per dimension, and are decoded at most once every 400 ms in a
Dart isolate. They are never saved or sent over a network. Desktop users join by
paste or files. No remote decoding service or native machine-learning SDK is used.

Sources: [Flutter camera plugin](https://pub.dev/packages/camera),
[zxing_lib source](https://github.com/shirne/zxing-dart).
