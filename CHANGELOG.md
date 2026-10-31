# Changelog

## 0.1.2 (unreleased)

- Endpoint synchronization. Root cause of the devices disagreeing about an endpoint: the control channel exchanged endpoints once, when the second device joined, using whatever interface that device had selected by default (the first one in the system's list, which can be a tunnel adapter). Choosing another interface afterwards rebound the local listener but told nobody, so the first device kept the earlier interface and no IPv4 address of the second; the second device kept a handshake that had been correct only for its earlier endpoint. Both journals could still report the run as started "independently" with an unconfirmed peer, so nothing showed the mismatch.
- Every endpoint now has a revision, and the control channel's new `/endpoint` request updates the peer and returns its own endpoint. A change of interface, address or port, a network change and returning to the foreground start one bounded exchange. A confirmation belongs to the revision it was given for; an old handshake never confirms a new endpoint, and messages of an earlier session or of a replaced listener change nothing. A failed exchange, a busy control port or a vanished interface is shown with its reason instead of leaving the old state in place.
- "Peer parameters" in the readiness panel and a warning beside the start button say whether the peer confirmed the current parameters. Independent runs remain possible. `peerReadiness: confirmed` now also requires both sides to hold each other's current endpoint: `/start` carries the revisions and a receiver that holds other ones declines, so a session's single run is not spent on mixed parameters.
- Journals record the endpoint revisions the run used (`endpointRevision`, `peerEndpointRevision`). Merging keeps each participant's own endpoint and records whether the other journal used the same one (`peerEndpoint`: `matches` or `differs`); a difference is shown in the results, the readable report and the file, not hidden. Format versions stay 1; see docs/protocol.md for compatibility. A 0.1.1 peer has no `/endpoint`: its endpoint is used through `/hello` but stays unconfirmed.
- An explicit interface choice is kept across refreshes and network changes and is restored when the interface returns; no other interface replaces it silently. Without a choice, a tunnel or virtual adapter (`utun`, `ipsec`, `tun`, `ppp`, ...) is no longer selected only because it comes first in the list.
- Dialogs: settings, check details and export use one wide dialog that fits the window, scrolls its content and keeps its buttons visible, instead of the narrow fixed platform alert on macOS and iOS.
- Theme and language are remembered between launches (all platforms). On macOS the window's size and position are remembered too.
- macOS release packages now include `lanpair-macos-unsigned.dmg` (unsigned, with an Applications link) next to the tar.gz.
- A manually typed peer address no longer produces a false endpoint mismatch when journals merge; endpoint exchanges have their own request budget; a listener that had to reopen (interface returned) repeats the exchange; late messages of an earlier join are told apart from a restart by a join generation; dialogs name their route for screen readers.
- Not changed and not established: IPv6 failures seen in the same trials are not attributed to this defect. A stale Pixel endpoint explains the missing IPv4 and the unconfirmed Mac to Pixel directions, not socket errors in both IPv6 directions; they need journals from a build with this fix. Version code 3.

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
