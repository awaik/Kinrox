# Kinrox Remote 0.2.1 (3) — TestFlight delivery

Delivered November 4, 2026 at the owner's request alongside Kinrox for Mac 0.5.3.

## Build and delivery

- App: Kinrox Remote, `app.kinrox.remote`, App Store Connect ID `6827926471`.
- Version/build: **0.2.1 (3)**, set in `Config/RemoteiOS.xcconfig` independently of Mac releases.
- Includes all standalone Spotify Soloist LAN remote updates, unknown-volume safety (`volumeKnown`), and state validation fixes across mode switches and window closure. Test with Kinrox for Mac 0.5.3.
- Signed with the existing Apple Distribution identity and `Kinrox Remote App Store` provisioning profile for team `HV66937AWS`.
- Apple validation and upload succeeded without errors. Uploaded at 14:40 UTC; Apple's processed-build timestamp is `2026-11-04T06:41:37-08:00` (`14:41:37 UTC`).
- Delivery/build ID: `d49d5f86-7f0b-4713-ab75-5dd627abd632`.
- Final API state: `VALID`, internal state `IN_BETA_TESTING`.
- Expiration: `2027-02-02T06:41:37-08:00`.
- IPA SHA-256: `62f3c5d857279222ffe9a042260f32aa9a5018179583a222d57fe275eea92108`.

## Testing access

- Added build `3` to internal group **Kinrox Owner Testing** (`ffd5f629-5985-4f24-bf7a-0b982ee26e5c`).
- Updated English and Russian TestFlight testing notes for build `3`.
- Existing App Store version 0.1.0 remains `WAITING_FOR_REVIEW`.

## Verification and evidence

- iPhone 17 / iOS 26.5 simulator: applicable unit and integration tests passed with ad-hoc simulator signing.
- Release archive and App Store export succeeded.
- Evidence is preserved in `DerivedData/TestFlight-20261104T143300Z/`: archive, exported IPA, checksums, simulator test logs, validation/upload logs, and `status-final.json`.
