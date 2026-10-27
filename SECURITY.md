# Security Reports

Kinrox is in development. There are no maintained stable release branches yet;
security fixes target the current source on `main`.

## Reporting a Vulnerability

Use the repository host's private vulnerability reporting feature when it is
enabled. If no private reporting channel is available, open an issue requesting
a private contact without including exploit details or sensitive data.
Do not put active pairing tokens, PINs, private keys, signing credentials, or
personal media paths in public issues, pull requests, or logs.

A private report should include the affected revision, platform versions,
reproduction steps, expected and actual behavior, and the impact you observed.
Use synthetic media and test credentials where possible.

## Security Scope

Relevant areas include local network access restrictions, Bonjour discovery,
WebSocket framing, handshake and authentication, PIN attempt limits, encrypted
frame validation, Keychain storage, token revocation, and remote file access.

The remote is designed for local networks. It does not provide a hosted service
or an internet-facing control endpoint. Protocol documentation and historical
verification reports are available in [AGENTS.md](AGENTS.md#6-iphone-remote-control)
and [docs/runbooks](docs/runbooks/README.md). Automated tests do not constitute
an independent security audit.
