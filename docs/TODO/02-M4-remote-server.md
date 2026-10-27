# Task M4 — Protocol, Transport, and Server in Mac Player

> **Status:** M4 is completed and accepted by owner; M4.1–M4.4 implemented.
> By owner decision on 2026-10-27 console `kinrox-cli` (former M4.5)
> was moved to [an optional task](05-kinrox-cli.md).
> Handshake specification (§6.5.1) was verified and approved.
> [M4.1 Report](../runbooks/M4.1-VERIFICATION.md),
> [M4.2 Specification](../runbooks/M4.2-SPEC-REVIEW.md),
> [M4.2 Report](../runbooks/M4.2-VERIFICATION.md),
> [M4.3 Report](../runbooks/M4.3-VERIFICATION.md),
> [M4.4 Report](../runbooks/M4.4-VERIFICATION.md).
> Server enabled by default; channel protected via CryptoKit handshake.
> **Assignee:** External agent. **Review & commit:** Owner.

## Summary

Milestone M4 established secure local communication between the Mac player and iOS remote:
- `RemoteProtocol`: Models, JSON codec, protocol version negotiation, and CryptoKit handshake state machines.
- `RemoteTransport`: Bonjour discovery, WebSocket transport over Network.framework, and connection lifecycle.
- `PlayerMac` Server: Bonjour advertising, paired devices management in Keychain, live state broadcasting, and UI pairing flow.
