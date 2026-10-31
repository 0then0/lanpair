# LANPair protocol and report format v1

LANPair v0.1 runs one bounded experiment between two explicitly selected
participants, A and B. Discovery is an independent experiment, never a
prerequisite for pairing or direct probes. There is no subnet or port scan.

## Session credentials and invitations

An invitation is `lp1:` followed by compact UTF-8 JSON. It contains:

- `format: "lanpair-invitation"` and integer `protocolVersion: 1`;
- independent random `sessionId` and `runId`;
- a 256-bit random session `secret` encoded as lowercase hexadecimal;
- ordered A/B endpoint records and a shared run plan;
- A's public certificate and its SHA-256 DER fingerprint;
- B's public certificate, fingerprint and ephemeral private key.

Identifiers and secrets use `Random.secure()`. Certificates use separate
ephemeral EC identities created through the `basic_utils` dependency.
The invitation never contains A's private key. Invitation import is limited
to 24 KiB before JSON parsing and rejects unknown fields, incompatible
versions, invalid types, duplicate participants and out-of-budget parameters.
The QR presentation is available only when the encoded invitation fits the
QR byte limit; file transfer and clipboard import remain available.

An invitation grants access to this session and must be treated like a
password. It is deliberately different from a shareable diagnostic report.
Local session serialization is a credential-bearing format and is never
accepted as a report. Reports contain no keys, bearer secrets or certificates.

## Endpoints and the observation window

Each participant has a session-scoped ID, selected IPv4 address, optional IPv6
address, local interface name/index and three explicit ports. Default TCP,
UDP and HTTPS control ports are 45831, 45832 and 45833. Raw multicast uses
port 45834 with IPv4 group `239.255.77.77` or IPv6 group `ff02::114`, with
one-hop multicast scope. Direct and multicast IPv4/IPv6 checks are distinct.

An empty peer address means that the peer endpoint has not yet been entered.
This is an inconclusive setup condition, not evidence of a network fault.
Endpoint corrections preserve the session, run and participant IDs. Imported
remote IPv6 zone names do not identify an interface on the local OS. Link-local
destinations must use the selected local interface's scope identifier. An
interface name or index describes the device that reported it; the other
participant keeps it as metadata and never uses it as a local scope.

### Endpoint synchronization (0.1.2)

An invitation fixes A's endpoint at the moment it was created, and a participant
can change its interface afterwards. The control channel therefore exchanges
endpoints again whenever one changes. The wire format stays version 1.

- Each participant numbers its own endpoint from 1 and increases the number with
  every change of its addresses, interface or ports. A new session, or a new
  join of the same invitation, starts again at 1. A revision identifies one set
  of parameters of one participant.
- `/endpoint` carries the sender's endpoint, its `revision` and `peerRevision`,
  the revision of the receiver's endpoint the sender currently holds (0 for
  none). The receiver stores a newer endpoint, ignores an identical resend and
  refuses an older or conflicting one (`stale_revision`, `revision_conflict`).
  `/endpoint` also carries a `generation`, a microsecond timestamp taken when
  the sender joined or created the session. A larger generation than the
  receiver holds is a later join: numbering restarts and acknowledgements given
  to the earlier join no longer count. A smaller one is a late message of an
  earlier join and is refused (`stale_revision`) whatever its revision. The
  answer carries the receiver's generation as well. A receiver that is running or has finished
  answers `applied: false` (`peer_running`, `peer_completed`).
- The answer carries the receiver's own endpoint and revision, so one exchange
  updates both sides, and `appliedRevision`, the sender's revision the receiver
  now holds. A participant counts its endpoint as confirmed only when the peer
  answered `applied: true` with that revision, or itself stated
  `peerRevision` equal to it. When the stated revision of a request is older
  than the receiver's, the receiver sends its own endpoint once per revision.
  No answer triggers another request, so an exchange ends after at most two
  round trips; the sender tries at most twice, only after a transport failure.
- `/start` carries `revision` and `peerRevision`. The receiver answers
  `{"verified": true}` only when both match the endpoints it holds, and refuses
  with 409 when they do not, so the session's single run is not spent on
  parameters one side never held. `peerReadiness: confirmed` requires this
  verification.
- A participant that cannot confirm the current endpoints stays usable:
  readiness is `unconfirmed` with a reason (`control_unreachable`,
  `control_unavailable`, `interface_unavailable`, `peer_rejected`, `peer_running`, `peer_completed`,
  `peer_legacy`, `manual_peer`), and the run may start independently.
- A confirmation belongs to the revisions it was given for. A change makes the
  state pending until the peer answers again; an older handshake never confirms
  a newer endpoint. Messages of an earlier session, or of a replaced listener,
  change nothing.
- 0.1.1 peers have no `/endpoint` (404). The sender then uses `/hello`, which
  delivers its endpoint and returns the peer's, but nothing proves the peer
  applied it: the state is `peer_legacy` and `unconfirmed`. A 0.1.1 sender's
  `/hello` or `/start` is accepted the same way. A missing field is never read
  as confirmation.
- When two participants change interface at the same moment each can only reach
  the other's previous address, so both stay `unconfirmed`. Importing the other
  device's current invitation again starts a new exchange from its current
  address.

The default plan is 6000 ms, three packets per check/family and 250 ms between
packets. Accepted plans permit 1000–15000 ms, one to three packets and
100–1000 ms intervals, with the packet budget strictly inside the window.
There is no retry loop without a fixed budget. Every new experiment must use
a new run ID. An invitation's run ID lets disconnected participants execute
the same experiment independently and later correlate their observations.

Every participant starts its own stopwatch. Sequence numbers and run IDs
correlate events; wall clocks do not establish ordering between participants,
and one participant's stopwatch is never compared with the other's.

### Coordinated and independent starts

Each journal records `<participant>.peerReadiness` among its capabilities:

- `confirmed`: the control channel showed that the peer's listeners were open
  before this participant sent anything, and that both participants held each
  other's current endpoint (see "Endpoint synchronization"). The initiator's
  `/start` request was accepted and verified, or the peer's authenticated and
  verified `/start` request started this run. The attempts then follow each
  other at the plan's interval.
- `unconfirmed`: the run was started independently, or the control channel
  failed. Journals written before 0.1.1 contain no statement and are treated
  as `unconfirmed`.

In an independent start the peer can open its listeners at any moment, so the
same fixed budget of attempts per check and family is spread over the window:
the first at its start and the last early enough (at most one second, a quarter
of the window for short plans) to finish before the window ends. The spacing is
never smaller than the plan's interval. With the default plan the TCP and UDP
attempts fall at 0, 2.5 and 5 seconds.

If the peer's listeners are open for one spacing while this participant is
still sending, one attempt falls inside that time. This is an opportunity, not
a guarantee: a finite number of probes cannot ensure delivery for every
overlap, and overlapping windows alone prove nothing. A peer that starts after
the last attempt, or a probe that is lost, leaves a direction without evidence.
Exact clock synchronization is not needed and not used.

What a direction needs in order to be called `passed` is evidence that the
expected participant took part, defined under "Interpretation semantics". What
it needs in order to be called `failed` is evidence that the peer was ready
(`confirmed`), plus attempt errors that could not come from an absent peer.
Anything else is `inconclusive`, with the attempt causes kept as observations.

## Protected control channel

The control channel is HTTPS implemented by `dart:io`. Its dedicated
`HttpClient` has empty trusted roots and accepts only the peer certificate's
exact SHA-256 DER fingerprint from the invitation. The exception callback is
scoped to that client; no global TLS verification setting is modified.
Requests also require the session bearer secret in the Authorization header.
The certificate pin and bearer secret are never written to reports.

Each POST includes `protocolVersion`, `sessionId` and `runId`. Supported paths:

- `/hello` exchanges the joining participant's endpoint and returns the host
  endpoint (the 0.1.1 handshake, still accepted but never a confirmation).
  Participant IDs cannot be replaced by an endpoint update.
- `/endpoint` updates the peer's endpoint under a revision and returns the
  receiver's own; see "Endpoint synchronization".
- `/start` requests the one accepted bounded run. Repeated starts do not
  allocate another experiment.
- `/report` transfers a public report, validated using the same strict rules
  as a manually imported file.

Control traffic has finite message sizes, timeouts and concurrency/request
budgets (64 authenticated requests per listener, plus a separate budget of 512
for `/endpoint`). Unauthenticated requests do not consume the accepted session's request
budget. A failed control exchange does not invalidate locally collected
observations or prevent manual report export and merging.

## TCP, UDP and multicast probes

A TCP result refers to an actual outgoing `Socket.connect` from the named
source. A response on an existing connection cannot establish the reverse
direction. Two facts are kept apart:

- **Transport connection.** A successful `connect` is recorded as `connected`.
  It says only that something at that address and port accepted a TCP
  connection. It could be another application, a proxy, a stale listener, or,
  when the entered address is this device's own, this device itself.
- **Participant confirmation.** After connecting, the source sends the
  authenticated probe and expects an authenticated acknowledgement, recorded as
  `acknowledged`. The reply is accepted only when its HMAC is valid and it names
  this session and run, the expected peer as sender and this device as
  receiver, `tcp` as the check, the same family and the same sequence as the
  probe. The target independently records `received` for a valid probe.

Each attempt that connected but received no valid reply is followed by a
non-terminal `error` observation, `tcp_reply_missing` or `tcp_reply_invalid`.
A refused, timed-out or unreachable attempt is likewise recorded as an `error`
with `connection_refused`, `connect_timeout` or `host_unreachable`; the codes
are the same on every platform. These attempt errors are not final: a later
attempt may still confirm the peer. Other errors, such as
`network_unreachable` or `socket_error_<n>`, report a local operation failure.

A peer endpoint equal to this device's own address and TCP or UDP port is not
probed. The engine records `unsupported` with `peer_address_is_local`; manual
entry rejects it. Addresses are compared as parsed addresses together with the
port, not as text: another interface of the same host or the same address with
another port is a different endpoint.

A successful TCP connect does not establish the permissions or discovery
behavior of another app.

Probe messages are UTF-8 JSON, at most 1200 bytes. The envelope contains `p`,
the canonical encoded payload, and `h`, an HMAC-SHA256 of those exact bytes
using the UTF-8 bytes of the hexadecimal session secret as the HMAC key. This uses the standard `crypto` implementation;
the application does not implement a cryptographic primitive. Probe metadata
is authenticated but not encrypted. The secret itself is not sent in probes.

The payload fields are:

- `v`: protocol version;
- `s`, `r`: session and run IDs;
- `f`, `t`: source and target participant IDs;
- `c`: `tcp`, `udp` or `multicast`;
- `i`: `ipv4` or `ipv6`;
- `n`: zero-based sequence number within the fixed packet budget;
- `a`: acknowledgement flag.

The receiver accepts only the active session/run, the explicitly selected
peer identity, a valid HMAC, the expected check/family and a permitted sequence.
Unicast also checks the selected endpoint address and port. Duplicates do not
trigger additional acknowledgements. Late packets cannot create a successful
result outside the receiver's observation window. Multicast rejects our own
source identity even if the OS delivers loopback traffic, and never sends an
acknowledgement.

For UDP, `sent` means only that the local socket accepted the datagram.
`received` is the receiver's statement that it parsed a valid matching probe.
`acknowledged` is the sender's statement that it parsed the matching reply.
An acknowledgement is no larger than the request and is sent at most once
per accepted authenticated unicast sequence. There is no inactive-session
UDP responder and no unrestricted reflector.

## System service discovery

The platform adapter publishes and browses only LANPair's `_lanpair._tcp`
test service using system DNS-SD/Bonjour/NSD APIs. Session and device IDs
identify the expected peer service. Publication, discovery and resolution
are separate observations. Only resolution of the matching peer service
passes the directed system discovery result.

Native errors name the failed operation and are attached to the direction that
operation affects. A direction X to Y passes when Y resolves X's service, so a
failed publication on the reporting device belongs to the local to peer
direction (`dns_sd_publish_failed`, reason `discovery_publish_failed`), and a
failed browse on the reporting device belongs to the peer to local direction
(`dns_sd_browse_failed`, reason `discovery_browse_failed`). A failed resolution is attributed to the peer to
local direction only when the adapter names the peer's service
(`dns_sd_resolve_failed`). The Android adapter does; other adapters currently
report a resolution failure without the service, which is recorded as
`dns_sd_resolve_unattributed` with this device as both ends, so it cannot make
either direction `failed`. A permission refusal affects both directions of the
reporting device. A later successful resolution still passes the direction.

A Bonjour/NSD result does not substitute for the raw multicast socket check.
Neither experiment proves that a third-party application's discovery will
work. Platform entitlement, permission and system-daemon limitations remain
explicit observations; an unavailable API is not silently simulated.

## Public reports and provenance

A report is a UTF-8 JSON object with `format: "lanpair-report"`, integer
`reportVersion: 1`, integer `protocolVersion: 1` and
`provenance: "participant_statement"`. Import is limited to 1 MiB and 4096
observations. Unknown fields, unknown enum values, non-integer numeric fields,
unrecognized versions, credentials and invalid participant references are
rejected. The top-level fields are:

- app version, session/run IDs and reporting participant;
- ordered `devices` (A then B), `sourceDeviceIds`, and shared `parameters`;
- `capabilities`, with per-device namespaced categorical values;
- `observations`, each carrying its reporter and evidence ID;
- UTC `startedAt`, local monotonic `durationMicros` and platform;
- `sourceRuns`, preserving each contributing participant's own start,
  duration, platform and app version;
- a boolean `redacted` marker.

Every observation has `id`, `reporterId`, `kind`, `check`, source/target IDs,
address family, optional sequence number, local `elapsedMicros`, UTC
`wallTime`, optional stable machine `code` and interface name. There are no
free-form exception messages or credential-bearing detail objects.

Importing another participant's report imports that participant's statement.
It is not cryptographic proof of a network event. HMAC-based probe admission
does not turn an exported report into independently verifiable evidence.

## Interpretation semantics

Interpretation operates on raw observations and returns stable reason keys
and the evidence IDs used. UI and human reports localize these keys. Evidence
of a successful observation remains useful if the run is cancelled later.

- **passed**: TCP has a source-side `acknowledged` event (the authenticated
  reply) or a target-side `received` event (the peer's own record of the
  authenticated probe); UDP has a target-side `received` event or a source-side
  `acknowledged` event; multicast has a target-side matching `received` event;
  DNS-SD has a target-side matching `resolved` event. A bare TCP `connected`
  event is never a pass. Address families and directions never share success.
  If TCP was confirmed only after earlier failed attempts, the reason is
  `peer_confirmed_after_retry`; the failed attempts stay in the sequence.
- **failed**: a local check operation reports an error, including a failed
  DNS-SD publication, browse or resolution; or the sender recorded
  `peerReadiness: confirmed` and every TCP attempt was refused, timed out or was
  unreachable (`connection_refused`, `timeout_observed`, `host_unreachable`), or
  a connection was accepted by a service that did not identify itself as the
  participant (`peer_not_confirmed`). This states the failed operation, not a
  firewall/router diagnosis.
- **inconclusive**: a delivery/resolve expectation was not observed, only a
  local UDP/multicast send was observed, evidence or peer configuration is
  missing, or suspension/network change interrupted the window. For TCP without
  a confirmed-ready peer this includes refused attempts (`peer_not_listening`),
  timeouts or unreachable addresses (`timeout_observed`, `host_unreachable`),
  a connection without a valid reply (`tcp_connected_peer_unconfirmed`) and a
  peer endpoint equal to this device (`peer_address_is_local`).
- **unsupported**: the platform or selected address family cannot perform
  that check, including unavailable IPv6 or raw multicast entitlement.
- **permission denied**: a known permission refusal prevents the check.
- **cancelled**: explicit cancellation ended a check before success and
  without a more specific capability/permission limitation.

UDP without an acknowledgement remains inconclusive until peer observations
establish delivery. A timeout never identifies a root cause. Raw multicast,
system service discovery and third-party discovery remain separate claims.

## Merging and redaction

Merge requires the same session ID, run ID, ordered participant IDs, run
parameters, report/protocol versions and redaction state. Address updates and
different wall clocks are allowed. Identical evidence IDs are deduplicated;
conflicting duplicate contents, conflicting source-run metadata and conflicting
capability statements are rejected explicitly. Incomplete reports stay useful.
Do not merge reports from separately started runs even if they look similar.

Redacted export replaces addresses and interface names with consistent
participant aliases, removes interface indexes, replaces wall-clock timestamps
with the Unix epoch and suppresses arbitrary capability values. Random
session/run/device IDs, monotonic timings, ports, platforms and evidence remain
for correlation. Redaction does not promise anonymity: a report can still
reveal platform and diagnostic behavior. Raw and redacted reports cannot be
merged together; merge raw files locally first, then redact the result.

## Exported interpretation grounds

JSON exports add an `interpretation` envelope with 14 directional
results. Each result stores its check/family, source/target IDs, outcome, stable
reason code, and the observation IDs used as evidence. Import recomputes these
results from the raw observations and rejects inconsistent cached conclusions.
Raw participant messages may omit this envelope; the receiver still computes its
own interpretation. The envelope contains no localized text or credentials.

## Endpoint statements in journals

A journal's `devices` list holds the endpoints the participant's probes used:
its own endpoint and the peer endpoint it held when the run began. Later changes
never rewrite it. Journals written by 0.1.2 also state, per participant,
`<participant>.endpointRevision` and `<participant>.peerEndpointRevision`
(counters, kept when redacted).

Merging two single-participant journals keeps each participant's own statement
of its endpoint and records whether the other journal used the same one:
`<viewer>.peerEndpoint` is `matches` or `differs`. Equal revisions decide when
both journals state them. A peer revision of 0 (an address typed in by the user
or learned from a 0.1.1 peer) is compared by addresses and TCP port only.
Otherwise the endpoints are compared; redacted
journals without revisions make no statement. A difference is allowed, because
an address is not identity, and is shown with the report. Journals of another
session, run, plan or participant order are still refused.

## Compatibility with LANPair 0.1.0 journals

Report and protocol format versions stay at 1: 0.1.1 adds only new observation
codes and one capability key, `<participant>.peerReadiness`, which 0.1.0 reads
as an ordinary categorical capability. The interpretation envelope moves to
version 2 because the rules changed.

- A 0.1.1 application interprets every imported journal with the 0.1.1 rules,
  whoever wrote it. A 0.1.0 `connected` event is a transport connection and is
  never read as an authenticated exchange; it passes only together with an
  `acknowledged` or a peer `received` event.
- Cached conclusions in a version 1 envelope were produced by the old rules.
  They are checked for shape and then ignored, so 0.1.0 journals remain
  importable and can show a different result than they did in 0.1.0. A version 2
  envelope must match the recomputed result exactly. Other versions are refused.
- Journals from both versions of one run can be merged. Without
  `peerReadiness` a sender is treated as `unconfirmed`.
- LANPair 0.1.0 interprets 0.1.1 journals with its own rules: it counts a bare
  `connected` event as success and shows attempt errors as `probe_error`. Use
  0.1.1 on the device that merges and reads mixed journals.
