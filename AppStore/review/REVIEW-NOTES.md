# App Review notes — draft

Do not paste this note until the released Mac download and review contact are confirmed. No reviewer Apple ID, password or fixed pairing code is required. Pairing codes are generated on the reviewer's own Mac.

## Suggested App Review notes

Kinrox Remote is a companion remote for the Kinrox video player on Mac. It does not play or stream video on iPhone. It uses the local network only; there is no cloud account, subscription, advertising SDK or analytics service.

You can inspect the interface without a Mac:

1. Open Kinrox Remote on iPhone.
2. Open Settings from the players screen.
3. Choose "Try Demo without Mac".
4. Select MacBook Pro to try playback controls and the recent-file list.
5. To try the pairing UI in demo mode, select "Mac mini - Living Room" and use the code displayed by the demo (482913). This is a demo-only code and never authenticates a real connection.
6. Exit Demo from Settings to use a real Mac.

For real functionality:

1. Download the signed Kinrox Mac player from https://github.com/awaik/Kinrox/releases and launch it on a supported Mac. Use the final version-specific DMG link in this note before submission.
2. Keep Mac and iPhone on the same normal local network. Allow Local Network access on both devices; guest-network client isolation must be disabled for the devices to reach each other.
3. Enable the remote in the Mac player's settings and open Connect iPhone.
4. On iPhone, select the Mac and enter the six-digit code currently shown by that Mac. Codes expire after two minutes; request a new one if necessary.
5. Open an owned local MP4 or MKV on the Mac. Pause, seek, change volume, switch fullscreen, and open an available file from Recents using the iPhone.
6. Next/Previous navigate video files in the current Mac folder. An unavailable recent file cannot be opened.

The demo uses fictional filenames and no network. The live mode uses Network.framework and Apple CryptoKit to protect pairing and control messages. No account deletion flow applies because no user account is created.

## Required owner fields

- Review contact: real first name, last name, reachable email and phone.
- Confirm the released Mac DMG URL and tested macOS version.
- Attach a short live Mac/iPhone demonstration if requested by App Review. This is separate from the public App Preview, which currently has a script only.
- Explain companion hardware/software dependency in the review notes and listing. Keep the public download accessible throughout review.
