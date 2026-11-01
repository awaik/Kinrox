# Kinrox Remote 0.2.0 (2) — TestFlight delivery

Delivered November 1, 2026 at the owner's request for a fresh iPhone test build.

## Build and delivery

- App: Kinrox Remote, `app.kinrox.remote`, App Store Connect ID `6827926471`.
- Version/build: **0.2.0 (2)**, set in `Config/RemoteiOS.xcconfig` independently of Mac releases.
- Source: `53cf58b8615fd128896467df16520770f47c7c3f` plus the recorded iOS version change.
- Contains the current music remote, Matrix controls, localization, project links,
  and personal-use license resources. Test with Kinrox for Mac 0.4.0.
- Signed with the existing Apple Distribution identity and `Kinrox Remote App Store`
  provisioning profile for team `HV66937AWS`.
- Apple validation and upload succeeded without errors. Uploaded at 11:22:55 UTC;
  Apple's processed-build timestamp is 11:23:58 UTC.
- Delivery/build ID: `f67a039a-caca-45a4-82f2-bde2b1c77d9c`.
- Final API state: `VALID`, internal state `IN_BETA_TESTING`.
- Expiration: January 30, 2027 at 11:23:58 UTC.
- IPA SHA-256: `3dce6b995aeaae3fe96b0d09cdca1db2d806a7f10e69b40c59ac0a7b4e68bf51`.

## Testing access

- Created internal group **Kinrox Owner Testing**, containing this build.
- Added the existing account holder through App Store Connect. The UI confirmed
  one internal tester with status **Invited**. Accept Apple's invitation on iPhone
  and install the build with TestFlight.
- English and Russian testing notes cover pairing/reconnection, video controls,
  Matrix, music playback, queue, favorites, and volume.
- Group ID: `ffd5f629-5985-4f24-bf7a-0b982ee26e5c`; automatic access to future builds is disabled.
- Existing App Store version 0.1.0 remains `WAITING_FOR_REVIEW`. This delivery is
  internal testing; the future store licensing rollout remains in `LICENSE-ROLLOUT.md`.

## Verification and evidence

- iPhone 17 / iOS 26.5 simulator: **58 tests passed, 2 skipped, 0 failures**.
  The two real-network integration tests require a physical iPhone and are
  intentionally skipped by the existing suite on Simulator.
- An initial unsigned simulator run failed the Keychain test with `-34018`.
  Rerunning with normal ad-hoc simulator signing passed the complete applicable suite.
- Release archive and App Store export succeeded. Archive signature, distribution
  entitlements, IPA identity/version, and all six bundled licensing documents verified.
- Physical-device testing of this exact TestFlight build is the owner's next step.
- Evidence is preserved in `DerivedData/TestFlight-20261101T111616Z/`: archive,
  exported IPA, source revision/patch, checksums, test results, validation/upload
  logs, and `status-final.json`. Earlier artifacts and the previous generated
  Xcode project were preserved.
- The installed fastlane client sent public-link fields that Apple's internal-group
  endpoint rejected; group creation used the minimal API payload. The API also
  rejected the existing tester assignment, so the owner invitation was completed
  and verified in Apple's web interface. No external library files were modified.
