# Task 11.13 — Player Updates for Web Downloads

> **Status:** Option A (Sparkle 2) chosen and implemented 2026-10-29 after owner approval of
> [Figma page 05](https://www.figma.com/design/vvWQ5IQdSuOFw2BebZkS8U/Kinrox?node-id=48-304).
> The HTTPS feed request is an approved exception to principle 4. Results and remaining
> checks — [Updates Verification](../runbooks/UPDATES-VERIFICATION.md).
> **Released:** Mac 0.3.0 (build 5), 2026-10-30. Users of 0.2.0 install this
> first checker build manually once. The EdDSA key and encrypted backup are described
> in the [release runbook](../runbooks/RUNBOOK-RELEASE.md#update-signing-key).
> **Assignee:** Agent or developer. **Review & commit:** Owner.

## Purpose

The remote is updated via App Store. The Mac player is distributed from the website (AGENTS.md 3.3). Without an update mechanism, users would remain indefinitely on their initial downloaded release, missing critical fixes or encountering protocol incompatibilities.

## Architectural Options

1. **Option A: Sparkle 2** (Recommended) — Industry standard for macOS apps outside App Store: automatically checks, downloads, verifies signature, and applies updates. MIT license compatible with GPL v3.
2. **Option B: Lightweight custom check** — Periodically fetch a minimal JSON manifest over HTTPS and present an update prompt with download link.
3. **Option C: Manual only** — Website downloads only.

## Network Policy Note

Principles prohibit telemetry and cloud reliance. Options A & B require a explicit policy exception for HTTPS update feed queries without transmitting user diagnostics (`SUEnableSystemProfiling = NO`).

The owner granted this exception on 2026-10-29 for the Sparkle appcast only.

## Implementation Checklist

1. ✅ Package integration via SPM in `project.yml` (Sparkle 2.10.1, pinned).
2. ✅ Controller in `Updates/SparkleUpdater.swift`, started from `AppDelegate.swift`;
   gentle reminders feed the welcome banner and paused-player pill.
3. ✅ Menu item "Check for Updates…" under the Application menu, with a version badge.
4. ✅ Release signing of Sparkle helpers, EdDSA appcast item, and packaging checks.
5. ✅ EdDSA key (2026-10-29); public key in `Config/Updates.xcconfig`.
6. ✅ First Developer ID release (0.3.0) with a published `site/appcast.xml`.
