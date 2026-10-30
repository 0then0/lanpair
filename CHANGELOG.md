# Changelog

## 0.1.1 (unreleased)

- Independent starts: without a confirmed-ready peer, the fixed TCP/UDP/multicast attempt budget is spread over the observation window instead of being sent in its first second. A device that starts a few seconds after the other is now reached in both directions. A start after the last attempt, or an unconfirmed peer, is reported as inconclusive rather than as a network failure. Each journal records whether the control channel had confirmed the peer was ready.
- A TCP pass now requires the expected participant: an authenticated acknowledgement bound to session, run, sender, receiver, check, family and sequence, or the peer's own record of the probe. A bare connection is kept as `connected` and reported as "connection accepted, participant unconfirmed". Manual entry rejects this device's own address and port.
- Every TCP attempt keeps its cause (`connection_refused`, `connect_timeout`, `host_unreachable`, missing or invalid reply). A later confirmation outranks earlier failed attempts and the sequence stays visible.
- DNS-SD publication, browse and resolution errors are separate and attached to the direction they affect; an error whose direction cannot be established is kept without a direction.
- Control channel: returning to the foreground, overlapping lifecycle changes and new sessions no longer leave a second listener bound, and an earlier open failure no longer remains the current state.
- Reports: format versions stay 1. Interpretation envelope version 2; 0.1.0 journals remain importable and are reinterpreted with the new rules (see docs/protocol.md). New readable explanations in all seven languages.
- QR invitation: shown in a wide dialog sized to the window (up to 640 px) instead of a fixed 300 px box squeezed by the narrow adaptive alert, so modules are large enough to scan on a laptop screen.
- Android: the release packaging step names an APK `lanpair-android.apk` only when it carries a signature, warns when it does not, and no longer picks a stale unsigned file next to a signed one. Documentation states that an unsigned APK cannot be installed and lists installation requirements. Version code 2.

## 0.1.0 (unreleased)

- Pair two devices using pasted invitations, files or mobile QR scanning.
- Run separate TCP, UDP unicast and raw multicast checks by direction and address family.
- Publish, discover and resolve the session's test service through native DNS-SD adapters.
- Support bounded runs, cancellation, network-change and suspension observations, and independent runs without a working control channel.
- Save report history and merge versioned JSON journals with duplicate/conflict validation.
- Export JSON and localized readable reports with consistent address/interface redaction.
- Provide seven interface languages, light/dark/system themes, adaptive navigation and accessibility/layout checks.
- Include native runner sources, automated checks, packaging workflows and platform/signing documentation.
