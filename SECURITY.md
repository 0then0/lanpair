# Security policy

LANPair v0.1 has not undergone an independent security audit. No security maintenance window or guaranteed response time is currently published.

## Report a vulnerability

Use [GitHub private vulnerability reporting](https://github.com/0then0/lanpair/security/advisories/new) if it is enabled for this repository. If that option is unavailable, open a minimal issue asking maintainers for a private reporting channel. Do not include exploit details, invitations, credentials, private addresses, unredacted journals or personal data in a public issue.

Include the affected version/platform, prerequisites, a reproducible example using disposable resources, and the observed impact when you have a private channel. Do not test against devices or networks without their owner's permission.

## Pairing and network trust

Only join sessions from a device you choose. An invitation contains a cryptographically random 256-bit secret, B's ephemeral EC private key and pinned public certificates. Possession authorizes participation in the session. Transfer invitations through a channel you trust and never publish them. This pairing mechanism does not prove that the participants are separate people: A can export B's joining credential, and a credential holder can make statements for either role.

Control messages use a session-scoped HTTPS client with empty trust roots, SHA-256 certificate pinning and a bearer credential. System TLS validation and other clients are untouched. The pins authenticate the session without requiring synchronized wall clocks. Standard HMAC-SHA256 authenticates bounded UDP/TCP probe metadata; the metadata is not encrypted.

TCP probe listeners and UDP responders are active only during an accepted bounded run. UDP replies require valid session/run/participant/check/sequence authentication and the selected peer endpoint. Each accepted unicast probe can receive at most one acknowledgement, no larger than its request. Multicast receives never generate acknowledgements, and own-device packets are ignored. DNS-SD TXT records contain session-scoped identifiers, never secrets.

Message sizes, imported files, observation counts and traffic budgets are limited. A received JSON journal is a participant statement rather than a cryptographic attestation of a network event. Do not treat report interpretation as stronger provenance.

## Stored and exported information

Only report history is saved automatically. History is ordinary application-support data protected by the OS account and disk, not application-level encryption. Live pairing credentials remain in memory. Invitations saved explicitly, exported reports and clipboard contents can outlive a session or leave the app sandbox.

Reports exclude invitation credentials, session secrets and TLS private keys. Export defaults to redaction: addresses and interface names become consistent aliases, precise wall times are removed and arbitrary capability values are suppressed. Session/run/device identifiers, ports, platforms and observation correlations remain. A redacted report is not an anonymity guarantee.

Merge original JSON journals privately before producing a redacted report to share. Original and redacted journals cannot be merged with each other. The clipboard, share sheet and receiving application are outside LANPair's control; check the destination and file before sharing it.

## Product boundaries

LANPair tests only explicitly paired devices. It has no telemetry or cloud service, does not scan subnets or ports, and never changes firewall or router settings. Preserve these boundaries when contributing. Do not disable TLS checks, weaken permission checks or add unrestricted responders to work around connectivity failures.

See [protocol documentation](docs/protocol.md) for validation and interpretation rules and [platform notes](docs/platforms.md) for OS-specific permissions and restrictions.
