# Task 11.13 — Player Updates for Web Downloads

> **Status:** Pending owner decision regarding option choice in [AGENTS.md](../../AGENTS.md).
> Recommended baseline: Sparkle 2.
> **Assignee:** Agent or developer. **Review & commit:** Owner.
> **When:** Alongside or after milestone M6 — Sparkle requires signed and notarized builds.

## Purpose

The remote is updated via App Store. The Mac player is distributed from the website (AGENTS.md 3.3). Without an update mechanism, users would remain indefinitely on their initial downloaded release, missing critical fixes or encountering protocol incompatibilities.

## Architectural Options

1. **Option A: Sparkle 2** (Recommended) — Industry standard for macOS apps outside App Store: automatically checks, downloads, verifies signature, and applies updates. MIT license compatible with GPL v3.
2. **Option B: Lightweight custom check** — Periodically fetch a minimal JSON manifest over HTTPS and present an update prompt with download link.
3. **Option C: Manual only** — Website downloads only.

## Network Policy Note

Principles prohibit telemetry and cloud reliance. Options A & B require a explicit policy exception for HTTPS update feed queries without transmitting user diagnostics (`SUEnableSystemProfiling = NO`).

## Implementation Checklist

1. Package integration via SPM in `project.yml`.
2. Controller configuration in `AppDelegate.swift` and `KinroxPlayerApp.swift`.
3. Menu item "Check for Updates…" under Application menu.
4. Release signing and notarization verification scripts.
