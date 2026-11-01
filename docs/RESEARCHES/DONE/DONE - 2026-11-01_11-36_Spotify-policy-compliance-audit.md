# Spotify policy compliance audit

Status: audit completed on 2026-11-01. The current Music build is not cleared for
public Spotify distribution. Corrections below are proposed, not implemented.
This task requested assessment, not a change to the owner's approved interaction
contract. It does not reopen the completed implementation plan.

Scope: current uncommitted Mac/iPhone implementation, connection and data lifecycle,
release documents, and the live English privacy page. Official documents were
retrieved on 2026-11-01; Developer Terms version 10 and Developer Policy both state
an effective date of 2025-05-15. This is a source-backed engineering assessment,
not approval or a written exception from Spotify.

## Classification and release decision

Kinrox uses `/me/player/play` to control Spotify.app. That is a Streaming SDA under
Terms II.14–15; the Compliance Tips explicitly include this endpoint. A separate
audio process does not make Kinrox a Non-Streaming SDA.
[Terms](https://developer.spotify.com/terms#section-ii-definitions),
[streaming examples](https://developer.spotify.com/compliance-tips#special-considerations-for-streaming).

The private test established technical feasibility with one Premium account.
The Client ID distribution question remains an interpretation issue, not a
confirmed prohibition on user-owned credentials; see the follow-up evidence in
F1. Personal testing is not a general exemption from the developer agreement.

## Findings

### F1 Public Client ID strategy requires resolution

Priority: P2. Classification: interpretation uncertainty, not a demonstrated
violation by user-owned personal installations. Follow-up on 2026-11-01 corrected
the initial P1 assessment after checking other projects' primary documentation.

Terms VI.1.2 and Policy VII.2 require one Security Code per SDA. Their application
to independently registered personal installations is not explicitly resolved in
the reviewed wording. No express ban on a user entering their own Client ID was
found. [Terms](https://developer.spotify.com/terms#section-vi-access-usage-and-quotas),
[Policy](https://developer.spotify.com/policy#vii-access-usage-and-quotas).

Evidence: `PlayerMac/PlayerMac/Music/UI/SpotifySettingsSection.swift:11–15` requires
each user's developer app; `SpotifyAccount.swift:51–88` accepts and persists its ID.
`docs/releases/UNRELEASED-MUSIC.md` promotes this as the setup path.

The current spotify_player README recommends a user-owned Client ID. It also
documents a shared ncspot fallback, described by its authors as having extended
access from before the November 2024 changes. This describes their implementation,
not Spotify's approval of every aspect of it.
[spotify_player authentication](https://github.com/aome510/spotify-player/blob/master/README.md#client-id-and-rate-limits).

Home Assistant provides a closer architectural precedent: its official integration
instructions ask each owner to register an application and supply its credentials
for Web API control. Thus user-owned credentials are an established integration
pattern. That project's instructions are not a written Spotify interpretation of
the SDA clause. [Home Assistant setup](https://www.home-assistant.io/integrations/spotify/#create-a-spotify-application).

Proposal: distinguish public distribution of configurable software from operating
one centrally registered service. Do not require replacing Kinrox's chosen Client
ID model solely on the original F1 inference. Keep personal registration and its
limits explicit; seek Spotify clarification if formal policy assurance is needed.
Do not adopt another project's ID or rotate IDs to escape quotas.

Development Mode currently allows five allowlisted users per registered app,
not five across all Kinrox installations using their own apps. It requires the
app owner to have Premium. Extended access is discretionary; the published
application criteria include an organization and at least 250,000 MAUs. These
requirements matter for a shared public registration; they do not prove that each
personal installation must qualify for extended access.
[Quota modes](https://developer.spotify.com/documentation/web-api/concepts/quota-modes).

### F2 Blanket omission of artwork conflicts with streaming policy

Priority: P1. Classification: direct policy conflict with a narrower design exception.

Policy II.5 requires relevant artwork and metadata during streaming. Design guidance
allows omitting artwork when screen space is limited. That does not establish a
blanket exception for the spacious Mac layout and all playback surfaces.
[Policy](https://developer.spotify.com/policy#ii-respect-content-and-creators),
[design guidance](https://developer.spotify.com/documentation/design#using-our-content).

Evidence: `Packages/KinroxMusic/Sources/MusicCore/MusicModels.swift:15–59` has no
artwork fields; `Packages/RemoteProtocol/Sources/RemoteProtocol/MusicState.swift:6–23`
excludes artwork. Mac `DeckView.swift:59–90` and iPhone `MusicRemoteView.swift:114–148`
render text only. `NowPlayingController.swift:104` deliberately excludes music artwork.

Proposal: design current-track artwork for Mac/iPhone playback and review system
Now Playing attribution. Keep dense browsing rows textual where appropriate.
If retaining the absolute no-artwork contract is essential, obtain a written
exception covering the actual screenshots. Mac can fetch images and deliver
bounded image data over LAN; iPhone need not call Spotify's API.

### F3 End user terms and connection disclosure are incomplete

Priority: P1. Classification: missing public-release prerequisites.

Terms V.11 requires an accepted end user agreement with Spotify-specific terms,
including its beneficiary status; V.12 requires pre-install/signup privacy disclosure.
[Terms](https://developer.spotify.com/terms#section-v-users--data).

Evidence: `LICENSE`, `RemoteiOS/LICENSE.txt` and the connection flow contain no
Spotify-specific end user terms or acceptance mechanism. Existing code licenses
and Spotify's OAuth permission screen do not implement that Kinrox flow.
`SpotifySettingsSection.swift` shows prerequisites and Connect, without a privacy
link or explanation of the library/playlist changes.

The local English catalog has a Spotify paragraph (`Website/locales/en.json:164`),
but the live [privacy page](https://kinrox.app/privacy/) returned HTTP 200 without
Spotify disclosure on 2026-11-01. The app's GitHub Pages URL redirects there. This
is consistent with the feature being unreleased, but must be corrected before
new Spotify users rely on that page. Local copy also omits the exact disconnect
path and the broad unlike action.

Proposal: publish accurate privacy copy alongside the release, link it before
Connect, explain read/write scopes and the managed playlist, and provide
Settings → Spotify → Disconnect instructions. Prepare integration-specific
terms with qualified legal review, scoped to Spotify rather than imposing new
restrictions on Kinrox's GPL code. Preserve the existing component licensing work.

### F4 Spotify links are missing or point at the wrong entity

Priority: P1. Classification: confirmed implementation gap.

Policy II.4.2 requires links to the applicable content; design guidance includes
companion apps. [Policy](https://developer.spotify.com/policy#ii-respect-content-and-creators),
[linking guidance](https://developer.spotify.com/documentation/design#linking-to-spotify).

Evidence: `Shared/SpotifyAttribution.swift:3–8` is only an image. iPhone remote,
queue and favorites views use it without a link. The only Mac music link is
`MusicView.swift:70`; its destination at lines 100–107 prefers the selected album
over the playing track and otherwise may be Spotify's home page. Track context
menus (`TrackTable.swift:126–132`) offer no Spotify action.

Reproduction from code: play a track from album A, browse album B, activate the
header logo; B opens while the deck still describes A. Queue and favorites items
also have no corresponding item action.

Proposal: attach Open Spotify actions to the relevant deck/item/context and add
them on iPhone. A user-initiated handoff to Spotify is separate from granting the
remote API access; amend the LAN-only product wording precisely. Handle the app
missing case and test destination identity with different selected/playing albums.

### F5 Disconnect retains account-linked local data

Priority: P1. Classification: confirmed lifecycle gap.

Terms V.8 requires ending access and deleting the user's Spotify personal data on
disconnect. [Terms](https://developer.spotify.com/terms#section-v-users--data).

Evidence: `SpotifyConnectMusicEngine.swift:40–41,194` persists a preference keyed
by both Client ID and Spotify user ID, containing the private helper playlist ID.
`SpotifyAccount.swift:167–188` removes credentials and the Client ID preference,
but not that mapping. Engine shutdown at lines 148–154 does not remove it either.
Repository search found no disconnect cleanup for this namespace. This conclusion
is based on source; the user's live defaults were not inspected or erased.

Proposal: remove account-linked mappings on explicit disconnect, including legacy
entries for the disconnected account, and add a regression covering reconnect and
credential-removal failure. Retain the existing memory/LAN reset and request-stop
logic. Leaving an intentionally created playlist in the user's Spotify account
is separate from retaining its local account mapping; do not silently delete
the user's playlists to address this finding.

### F6 Favorites conflict with the specified interaction

Priority: P2. Classification: explicit UI discrepancy plus a separate transparency risk.

Design guidance specifies a plus icon and feedback for both saving and removing
a liked song. [Liking guidance](https://developer.spotify.com/documentation/design#playing-views).

Evidence: `MusicControls.swift:13–26` and the iPhone switch use hearts.
`MusicViewModel.swift:184–192` clears status after a successful mutation;
`RemoteAppModel+Music.swift:26–30` opens options after like confirmation but does
not supply the specified success feedback.

Additionally, `FavoritesPolicy.swift:12–21` removes every occurrence from every
editable playlist on unlike. `MusicModels.swift:88–89` includes collaborative
playlists, so this can change shared lists too. A generic Favorite label does not
communicate that scope. Policy I.1.1's transparency requirement is relevant;
classifying this as risky is an inference, not a claim that Spotify expressly
bans user-directed batch playlist removal.
[Policy](https://developer.spotify.com/policy#i-respect-users-and-data).

Proposal: adopt the specified save icon and feedback; make ordinary unlike affect
Liked Songs only. Offer bulk playlist removal as a separate, clearly described
operation with the affected lists visible. Keep exact undo support. This changes
the owner's deliberate contract and should be an explicit product decision.

### F7 Metadata display needs completion

Priority: P2, with a regional release condition.

Design guidance requires access to full truncated metadata and explicit badges
when serving South Korea. [Metadata and explicit-content guidance](https://developer.spotify.com/documentation/design).

Evidence: iPhone `MusicRemoteView.swift:132,155`, `MusicQueueView.swift:105` and
playlist option rows truncate without an expansion/link action. Some Mac track
cells have tooltips, but deck/album/source labels do not consistently expose the
full text. `SpotifyTrack` and `MusicTrack` drop `explicit`, and the remote model
has no corresponding field. Korean localization exists; there is no geography
restriction in the implementation.

Proposal: provide full text via an accessible detail action or expanding layout;
carry the API explicit flag through shared/protocol models and show an E badge.
Showing it for all users avoids guessing location from UI language. This is a
Spotify guideline finding, not an independent assessment of Korean law.

## Questions requiring narrower decisions

- **Core experience overlap:** the three-column library, search, favorites and
  queue approach a full client. Policy III.11 restricts replacing Spotify's core
  experience without permission. LAN remote control adds distinct value, so this
  audit does not declare Kinrox automatically prohibited. Present that exact use
  case and screenshots to Spotify when resolving distribution.
  [Policy](https://developer.spotify.com/policy#iii-some-prohibited-applications).
- **Content set limit:** the design page's browsing section limits content sets
  to 20 items. Its examples concern Spotify-provided shelves; applicability to a
  complete personal library/queue is unclear. Obtain clarification; do not silently
  truncate user playlists based on an assumed interpretation.
  [Browsing guidance](https://developer.spotify.com/documentation/design#browsing-spotify-content).
- **Playback restrictions:** `SpotifyPlayback` ignores API `actions`; the UI uses
  local queue/capability state. The API documents these fields for adapting controls.
  Add capability handling and targeted tests. Free-tier control guidance is not
  evidence that current Premium-only playback bypasses restrictions: Spotify still
  enforces its API authorization.
  [Playback state](https://developer.spotify.com/documentation/web-api/reference/get-information-about-the-users-current-playback).
- **Monetization:** the current build has no payments or ads. Charging for a
  bundled streaming feature or adding advertising would require a separate decision
  under Policy IV; a paid video shell does not automatically exempt its Spotify mode.
  The GPL's permission to sell code does not grant Spotify service rights.
  [Commercial-use examples](https://developer.spotify.com/compliance-tips#commercial-use).

## Parts that do not need a speculative redesign

- PKCE with a public Client ID and no embedded client secret fits a native app;
  the explicit `127.0.0.1` HTTP redirect is permitted. The problem in F1 concerns
  registration/distribution strategy, not cryptographic secrecy of the Client ID.
  [PKCE](https://developer.spotify.com/documentation/web-api/tutorials/code-pkce-flow),
  [redirect rules](https://developer.spotify.com/documentation/web-api/concepts/redirect_uri).
- Official white logo artwork is 78 points wide with clear space on a dark surface
  (`SpotifyAttribution.swift`). Its dimensions exceed the published 70px minimum.
  Adding it resolved that aspect, not F2/F4.
  [Logo guidance](https://developer.spotify.com/documentation/design#using-our-logo).
- The private helper uses documented playlist contexts, checks ownership/privacy
  and never adopts a playlist by name (`SpotifyConnectMusicEngine.swift:169–207`).
  No reviewed rule specifically prohibits a clearly disclosed managed playlist.
  This is not blanket approval of the whole product.
  [Playback endpoint](https://developer.spotify.com/documentation/web-api/reference/start-a-users-playback).
- Audio stays in Spotify.app. `PlaybackCoordinator.swift:64–69` waits for the other
  engine to pause. The deck bars use fixed arithmetic rather than audio analysis.
  There is no implemented ripping, mixing or synchronized video feature.
- The API session disables disk cache/cookies, uses Keychain credentials and
  origin checks, and respects 429 cooldowns. The iPhone receives encrypted LAN
  state. These are useful existing controls; F5 is a specific remaining gap.

## Proposed correction sequence and acceptance

1. Document the chosen distribution/access model with the corrected F1 distinction;
   resolve the artwork exception question before preparing a public Spotify release.
   Do not infer formal approval from successful API calls or another project's use.
2. Agree the necessary changes to the no-artwork, heart, bulk-unlike and iPhone-link
   contracts. Update the same Figma file before implementing new UI states.
3. Implement F3–F7 with bounded artwork transport, contextual links, explicit
   metadata, complete disconnect cleanup and localized onboarding/terms.
4. Verify: accepted terms before connection; accurate live privacy URL; no remaining
   local account mapping after disconnect; no late requests; link destinations
   match their entities; artwork and full metadata appear; unlike leaves playlist
   membership intact unless a separate bulk action was requested.
5. Run affected package, Mac and iPhone tests and repeat physical-device UI checks.
   Keep implementation validation separate from Spotify's policy/access decision.

## Audit boundaries

No application code, Figma designs, account permissions, playlists, credentials,
release settings or deployments changed during this audit. Source inspection,
official-document retrieval and anonymous privacy-page HTTP checks were sufficient
to establish the findings; the 365 earlier tests were not rerun because code did
not change. They demonstrate behavior, not platform-policy compliance.

Follow-up changes require a separate implementation task. The audit itself is
complete. Existing licensing changes and artifacts remain intact.

## Authorized implementation follow-up — 2026-11-01

The owner requested items 2–6, retained the existing unfavorite playlist behavior,
and declined artwork. [Implementation and checks](<DONE - 2026-11-01_11-55_Spotify-interface-and-consent.md>) cover official
plus/active icons, feedback, contextual links, Disconnect, metadata/restrictions
and versioned connection terms. This supersedes the earlier proposal only within
that authorized scope. Artwork/distribution interpretations remain unresolved;
no Spotify approval or public release is claimed.
