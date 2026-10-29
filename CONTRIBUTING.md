# Contributing to LANPair

LANPair welcomes bug reports, documentation improvements, translations and focused code contributions. Preserve the distinction between a measurement, a missing observation and an explanation of its possible cause. Read the [code of conduct](CODE_OF_CONDUCT.md) before participating.

## Set up a checkout

Install Flutter 3.47.8, including Dart 3.13.7, and the native toolchain for the platform you intend to build. Python 3 is used by the localization, license and packaging helpers.

```sh
git clone https://github.com/0then0/lanpair.git
cd lanpair
flutter doctor -v
flutter pub get --enforce-lockfile
flutter gen-l10n
flutter devices
flutter run -d <device-id>
```

Use the committed `pubspec.lock`. Generated translations, plugin registrants, build output and local SDK caches are ignored. `tool/flutterw` is an optional wrapper that uses a project-local Flutter SDK when available and otherwise uses `flutter` from `PATH`; the commands below also work directly with a configured Flutter installation.

See [platform prerequisites](docs/platforms.md) for permissions and native setup, and [distribution](docs/distribution.md) for signing.

## Find the relevant code

- `lib/src/model.dart`: session identities, invitations, run plans and report data types.
- `lib/src/engine.dart`: bounded TCP, UDP and raw multicast probes.
- `lib/src/control.dart`: authenticated, certificate-pinned HTTPS coordination.
- `lib/src/report.dart`: interpretation, strict report import, merge and redaction.
- `lib/src/controller.dart` and `storage.dart`: application state and local report history.
- `lib/src/app.dart`, `ui_contract.dart` and `ui_theme.dart`: presentation and adaptive controls.
- `lib/src/platform_bridge.dart`: the Dart/native channel contract; adapters live in each native runner.
- `lib/l10n/`: English source messages and translations.
- `test/` and `integration_test/`: shared automated checks and native-runner integration checks.

Keep the diagnostic model independent of widgets and native APIs. Read [protocol semantics](docs/protocol.md) before changing observations, interpretation or serialized formats.

## Run checks

Run these before submitting a pull request:

```sh
flutter gen-l10n
python3 tool/check_l10n.py
dart format --output=none --set-exit-if-changed lib test integration_test tool
flutter analyze
flutter test
```

For native changes, also build the affected target and run the integration test on that runner:

```sh
flutter build <target> --release
flutter test integration_test/app_test.dart -d <device-id>
```

Use `apk` for an Android build, `ios --no-codesign` for an unsigned iOS compilation, or a desktop target (`macos`, `windows`, `linux`) on its native host. Installing on an iOS device requires signing. The integration test checks channel registration and application startup; it does not establish two-device LAN behavior.

Start with tests for the affected behavior. Socket tests use disposable loopback resources. Do not change a working machine's firewall or a shared network to make a scenario pass. The [validation guide](docs/validation.md) describes additional native and physical checks and how to report their evidence.

## Change behavior safely

A diagnostic check needs a finite time and packet budget, cancellation and resource cleanup, precise outcome semantics, and tests for meaningful failure cases. Do not add subnet discovery, port scans, traffic capture, telemetry or automatic firewall changes.

Imported files and network messages are untrusted and bounded. Report protocol changes explicitly and reject incompatible versions rather than guessing. Preserve the distinctions among a local send, peer receipt and returned acknowledgement. A timeout cannot establish a firewall or router diagnosis.

Use ephemeral credentials in tests. Never put real invitation secrets, certificates/private keys, bearer tokens, private network addresses or unredacted reports in commits, logs, screenshots or issue attachments. Use the [security policy](SECURITY.md) for vulnerability reports.

## Update translations and artwork

Add user-facing text to the English ARB and every translated ARB. Preserve named placeholders and ICU plurals. `app_pt.arb` supplies the Brazilian Portuguese fallback for `app_pt_BR.arb`; keep their messages consistent. Machine identifiers and report fields stay stable across languages.

After generating translations, test narrow and desktop layouts at enlarged text scale and affected platform variants. Automated message/layout checks are not linguistic review. English must remain the fallback for unsupported system languages.

The project icon is `assets/icon.svg`. `tool/render_icons.dart` uses the same geometry to generate Android, Apple and Windows assets:

```sh
flutter test tool/render_icons.dart
```

Keep the SVG and renderer synchronized. On macOS the generator removes alpha from iOS icons through `tool/strip_icon_alpha.swift`. Inspect the artwork at launcher sizes after changes; rebuild binaries to include new assets.

When dependencies change, update the lockfile deliberately and regenerate the license inventory:

```sh
python3 tool/license_inventory.py
```

Review the resulting notices and licenses before distribution.

## Submit a change

Describe the problem, the resulting behavior and the checks actually run. Include untested platforms and relevant protocol, permission or privacy effects. Use the pull-request template; screenshots should use synthetic data and contain no credentials.

Use Conventional Commits in English. Contributions are licensed under the repository's Apache-2.0 license. No contributor license agreement is required.
