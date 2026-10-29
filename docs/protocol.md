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
destinations must use the selected local interface's scope identifier.

The default plan is 6000 ms, three packets per check/family and 250 ms between
packets. Accepted plans permit 1000–15000 ms, one to three packets and
100–1000 ms intervals, with the packet budget strictly inside the window.
There is no retry loop without a fixed budget. Every new experiment must use
a new run ID. An invitation's run ID lets disconnected participants execute
the same experiment independently and later correlate their observations.

Every participant starts its own stopwatch. Sequence numbers and run IDs
correlate events; wall clocks do not establish ordering between participants.
Independent windows need to overlap for a packet to be observed. A missed
window is not distinguishable from a lost packet without additional evidence.

## Protected control channel

The control channel is HTTPS implemented by `dart:io`. Its dedicated
`HttpClient` has empty trusted roots and accepts only the peer certificate's
exact SHA-256 DER fingerprint from the invitation. The exception callback is
scoped to that client; no global TLS verification setting is modified.
Requests also require the session bearer secret in the Authorization header.
The certificate pin and bearer secret are never written to reports.

Each POST includes `protocolVersion`, `sessionId` and `runId`. Supported paths:

- `/hello` exchanges the joining participant's endpoint and returns the host
  endpoint. Participant IDs cannot be replaced by an endpoint update.
- `/start` requests the one accepted bounded run. Repeated starts do not
  allocate another experiment.
- `/report` transfers a public report, validated using the same strict rules
  as a manually imported file.

Control traffic has finite message sizes, timeouts and concurrency/request
budgets. Unauthenticated requests do not consume the accepted session's request
budget. A failed control exchange does not invalidate locally collected
observations or prevent manual report export and merging.

## TCP, UDP and multicast probes

A TCP result refers to an actual outgoing `Socket.connect` from the named
source. A response on an existing connection cannot establish the reverse
direction. A successful TCP connect says that this port accepted a connection;
it does not establish the permissions or discovery behavior of another app.

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

- **passed**: TCP has a source-side `connected` event; UDP has a target-side
  `received` event or a source-side `acknowledged` event; multicast has a
  target-side matching `received` event; DNS-SD has a target-side matching
  `resolved` event. Address families and directions never share success.
- **failed**: a local check operation reports an error, or a configured TCP
  connection was not established within the observation window. This states
  the failed operation, not a firewall/router diagnosis.
- **inconclusive**: a delivery/resolve expectation was not observed, only a
  local UDP/multicast send was observed, evidence or peer configuration is
  missing, or suspension/network change interrupted the window.
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

JSON exports add an `interpretation` envelope with version 1 and 14 directional
results. Each result stores its check/family, source/target IDs, outcome, stable
reason code, and the observation IDs used as evidence. Import recomputes these
results from the raw observations and rejects inconsistent cached conclusions.
Raw participant messages may omit this envelope; the receiver still computes its
own interpretation. The envelope contains no localized text or credentials.
