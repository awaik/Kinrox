# Music mode v2 — implementation notes

Historical pre-release record, implemented 2026-11-01. Mac publication is now
covered by [0.4.0 release notes](0.4.0.md). The boundaries below describe the
implementation task; iPhone App Store publication remains separate. Verification: [Music mode v2](../runbooks/MUSIC-VERIFICATION.md).

## What changes

- Mac Music view: source, albums and tracks in three columns, catalogue search,
  a fixed playback deck, compact layout from 1024 px and keyboard navigation.
- Independent track likes, saved albums and artist follows. Liking opens playlist
  and artist options; unliking removes all copies from owned/collaborative
  playlists while retaining artist follows. The row stays until navigation or
  refresh. Command-Z reverses the last favorite action, including playlist positions.
- Queue with distinct occurrences for repeated tracks, manual/source sections,
  reorder, removal, shuffle and repeat. A private **Kinrox Queue** playlist is used
  for reliable official Spotify Connect playback on this Mac.
- Music metadata, transport, queue and favorites on the iPhone over the existing
  encrypted LAN connection. The iPhone never connects to Spotify's API.
- Video/Music switches the Mac view. Starting playback first waits for the other
  source to pause; one shared Now Playing controller handles media keys.
- Official Spotify attribution, inline recovery actions, and localized app and
  privacy text in all 30 supported languages.

## Spotify setup

1. Use a Spotify Premium account and a Spotify developer app available to that
   account. Development Mode users must be included in the app's allowlist.
2. Add `http://127.0.0.1:43821/callback` to the app's allowed redirect URIs.
3. In Kinrox Settings → Spotify, read the bundled connection terms and privacy
   supplement, accept the terms, and enter the public **Client ID**, then Connect.
   No client secret is needed or requested. Complete consent in the browser.
4. Open the official Spotify app on the same Mac and sign in to the same account.
   Kinrox selects a Computer device whose name matches the local Mac. If unavailable,
   activate Spotify locally and retry; Kinrox does not take over another device.
5. Open Music with Command-2. Select an album, or press its play button to start it.
   Command-F searches the catalogue; Command-R refreshes the library.

Playback audio comes from Spotify.app. Kinrox controls that app's Spotify volume;
it does not change Mac system volume. Spotify API polling can delay state updates.

## Data and queue behaviour

The connection is opt-in on Mac. OAuth uses PKCE, a state-checked loopback callback,
and the Data Protection Keychain for credentials. Library metadata is cached in
memory. No Kinrox account, backend, telemetry or analytics is introduced.

Kinrox creates its helper playlist as private and remembers its ID per account and
Client ID. It never adopts a playlist merely because its title is Kinrox Queue.
The helper is excluded from favorites membership operations. Disconnect removes
local credentials, account-to-helper associations, and the in-memory library; it does not delete the helper
playlist or revert previous library changes in Spotify.

Queue edits during playback replace the helper contents and resume at the last
confirmed position. Editing a paused queue does not start playback. Duplicate
tracks have separate Kinrox IDs, but Spotify's playback API does not report a
playlist occurrence ID; ambiguous externally changed playback is a known limit.

## Release boundary

No version bump, distribution archive, notarization, appcast update or deployment
was performed. The [Spotify policy audit](<../RESEARCHES/DONE/DONE - 2026-11-01_11-36_Spotify-policy-compliance-audit.md>)
has a follow-up implementing official plus/active favorites, brief confirmed feedback,
contextual track/album/playlist links, full metadata, explicit badges, API action
restrictions and a versioned connection-consent gate. The owner retained existing
unfavorite playlist behavior and declined artwork. This is not a Spotify approval.

Publish the generated `/spotify-terms/` page and updated `/privacy/` routes in the
same release rollout, before enabling the new download. Full connection terms and
the privacy supplement are translated into all 30 app languages, with English as
the source. Each locale uses the same versioned JSON text offline in the Mac app
and on the site. The full supplement also appears on each `/privacy/` page.
The app selects its own language, including regional and Chinese script matching;
unsupported languages fall back to English. Missing or incomplete supported
documents prevent connection. Verify public routes after deployment.
No website publication was performed in this implementation task.
Minimum targets remain macOS 14 and iOS 17; live verification used macOS 26.5.2 and
the owner's physical iPhone. See the verification report for precise test scope.

Follow-up verification: [Spotify interface and consent](<../RESEARCHES/DONE/DONE - 2026-11-01_11-55_Spotify-interface-and-consent.md>).

Document localization and publication preparation:
[30-language verification](<../RESEARCHES/DONE/DONE - 2026-11-01_12-23_Spotify-document-localization.md>).
