# Spotify interface and consent follow-up

Status: implemented locally and verified; not released. Owner authorized audit follow-up items 2–6 on 2026-11-01.

## Scope and evidence

Follow-up to [policy audit](<DONE - 2026-11-01_11-36_Spotify-policy-compliance-audit.md>).
Keep the user-supplied Client ID, existing favorite/unfavorite playlist behavior,
and artwork-free layout. No release or deployment is requested in this task.

- Replace hearts with Spotify's supplied plus/active artwork and confirm completed
  track favorite changes briefly without additional dialogs.
- Provide contextual track, album and playlist links on Mac and iPhone. The iPhone
  opens Spotify only after a user action; API credentials and requests stay on Mac.
- Clear local helper-playlist associations on Disconnect, retaining Spotify playlists.
- Expose full metadata, explicit labels and API playback restrictions.
- Bundle integration terms and privacy disclosure before connection, with matching
  website documents prepared for publication alongside the release.

The current working tree already contains Disconnect cleanup and its regression
`disconnectForgetsQueueBindingsAfterPendingWorkSettles`; preserve and verify this
change. Do not claim a new red/green reproduction for an already corrected defect.
The cleanup runs after pending work settles so a late helper creation cannot
restore its mapping. Unrelated preferences are retained; no playlist-delete call
is involved. Other changes in the working tree, including licensing, are preserved.

## Implementation plan

1. Update existing Figma favorite masters and add approved metadata/connection states.
2. Add optional protocol metadata/restrictions and confirmed favorite feedback.
3. Implement contextual links, complete metadata and restricted controls.
4. Gate Spotify connection and credential restoration on current integration terms.
5. Prepare localized disclosures, website terms/privacy and release instructions.
6. Run targeted regressions, package and app tests, localization/site checks and UI QA.

Sources: [design](https://developer.spotify.com/documentation/design),
[developer terms](https://developer.spotify.com/terms),
[playback state](https://developer.spotify.com/documentation/web-api/reference/get-information-about-the-users-current-playback).
Official favorite assets: `https://developer.spotify.com/images/guidelines/design/like-icon-svg.zip`.

## Implementation result

- Figma page `88:304`: existing favorite masters now use Spotify's supplied
  plus/active SVGs (`100:911`, `100:914`). Consent `125:3541`, metadata details
  `125:3550`, feedback alternatives `128:3536`/`128:3538` and interaction notes
  `128:3540` cover the authorized states. The phone title exposes details and E.
- Shared official assets, contextual links and explicit badges are used by both
  apps. Mac tooltips expose full visible item metadata. The iPhone details sheet
  shows track/artist/album metadata without UI truncation. Playlist option titles
  wrap and have contextual Spotify links. Native Spotify URIs have HTTPS fallback;
  opening links is always user initiated and does not call the Web API on iPhone.
- Confirmed track favorite changes publish a distinct three-second feedback event.
  Optimistic changes and failures never publish success feedback. Existing
  unfavorite playlist removal, artist independence, popover and undo remain intact.
- Optional album ID, explicit/playability, restriction and feedback fields preserve
  existing v1 JSON fixtures byte for byte when absent. Both flat API actions and
  nested `disallows` are supported. Restrictions reach Mac, iPhone and media keys;
  model/command guards and fresh engine-state checks prevent prohibited writes.
  Devices that report unsupported volume are also rejected before a volume write.
- Disconnect cleanup already present in the working tree was retained and verified.
  It clears all local helper associations after pending work settles, without any
  Spotify playlist deletion. Stored connections can be disconnected even before
  accepting updated terms.
- `Resources/Spotify/SpotifyConnection.en.json` is the versioned source for bundled
  connection terms and privacy supplement and the generated website terms page.
  The current terms version must be accepted before OAuth or credential restoration.
  Missing/mismatched bundled documents fail closed. Consent does not change the
  component licenses or restrict GPL rights in Kinrox's Mac code.
- New UI strings and short disclosures cover all 30 locales. Full legal documents
  are explicitly English, both offline and on the site; no claim of 30 translated
  legal documents is made at this stage. The later
  [document localization task](<DONE - 2026-11-01_12-23_Spotify-document-localization.md>)
  completes all 30 full translations. Website privacy text now distinguishes LAN API/control
  from user-initiated Spotify handoff. Generated pages are ready for release, not
  deployed by this task.

## Verification

| Check | Result |
|---|---|
| Full Mac suite | 174 tests passed; subsequent focused reruns passed 24 and 23 tests after availability/Disconnect/volume refinements |
| iPhone simulator suite | 60 tests passed; final UI build also succeeded |
| KinroxMusic package | 27 tests passed |
| RemoteProtocol package, fresh scratch build | 126 tests passed, including exact legacy fixture bytes and new optional fields |
| Website | 8 offline tests passed; 120 generated routes verified in 30 locale navigations |
| Localization | 30 locales, 348 UI keys and format arguments verified |
| Formatting and whitespace | Strict recursive Swift lint and `git diff --check` passed |

New checks protect consent before credential access, unplayable/explicit metadata,
both API restriction response shapes, blocked commands never reaching the engine,
blocked seek/volume never reaching HTTP write endpoints, success-feedback timing
and clearing, rejection of unsafe Spotify link identifiers, and additive protocol
compatibility. Existing failed-favorites coverage also asserts absence of success
feedback. Disconnect's pre-existing regression passed; no new red-before-fix run
was claimed for that already corrected behavior.

A first package run with old `.build` artifacts crashed (signal 11); a sequential
retry reported six unrelated handshake/transport failures. A completely new
`--scratch-path /tmp/kinrox-spotify-protocol-fresh-20261101 --no-parallel` build
passed all 126 tests. No transport/security changes were made to accommodate these
failures, and old build artifacts were preserved.

Logs: `/tmp/kinrox-spotify-followup-mac-tests.log`,
`/tmp/kinrox-spotify-followup-mac-targeted.log`,
`/tmp/kinrox-spotify-followup-mac-final-tests.log`,
`/tmp/kinrox-spotify-followup-ios-tests.log`,
`/tmp/kinrox-spotify-followup-package-final.log`,
`/tmp/kinrox-spotify-followup-protocol-fresh.log`,
`/tmp/kinrox-spotify-followup-site-final.log`, and
`/tmp/kinrox-spotify-followup-lint-complete.log`.

Manual CUA verification on macOS and the dedicated iPhone simulator confirmed:

- Bundled terms readable without signing in; the unchecked agreement disables
  Connect and the prior account does not automatically reconnect.
- Official plus and active icons, explicit badge, both favorite messages and their
  disappearance; adding still opens the existing playlist/artist popover.
- Mac playlist context menu includes Open in Spotify; full track details and the
  album link render correctly on iPhone. Synthetic demo track identifiers are
  deliberately rejected by the external-link validator.
- Playback volume stayed at zero. Favorite UI checks used fictional demo data;
  no real Spotify library mutation or playlist deletion was performed.

## Release and remaining boundaries

No commits, version bump, archive, notarization, appcast update, website deployment,
or App Store upload. The owner must accept the new connection terms on the next
connection; the agent did not accept a legal agreement on the owner's behalf.
The current follow-up was visually checked on Mac and simulator. The earlier
physical-iPhone acceptance belongs to Music v2; this follow-up was not revalidated
on the physical phone or through a new live Spotify authorization.

Publish `/spotify-terms/` and updated `/privacy/` with the release before the new
download is enabled, then verify the public URLs. Artwork and Client ID policy
interpretations remain audit limitations; this task does not establish full
Spotify approval or compliance. The owner explicitly retained the existing
unfavorite playlist behavior and declined artwork.
