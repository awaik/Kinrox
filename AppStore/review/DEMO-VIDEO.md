# App Review demo video — Kinrox Remote 0.2.2 (build 4)

Requested by App Review on November 13, 2026 (Guideline 2.1 — Information Needed,
submission `2b874451-1d97-466a-a907-1f540b8fff25`). This video is for App Review only.
It is not the public App Preview described in `AppStore/preview/STORYBOARD.md`, and the
App Preview rules there (no fingers, no device bezels) do not apply.

## What Apple asked for

1. The current app version on a physical Apple device, not a simulator.
2. The initial pairing between the app and the designated hardware (the Mac running Kinrox).
3. The entire app workflow with that hardware.
4. Both the hardware and the app visible in the footage.

## Filming setup

- Film with a separate camera (a second phone is fine) on a tripod or stand. Keep the Mac
  screen and the iPhone in one frame for the whole video; hold the iPhone close to the Mac
  display so both stay legible. Use screen recording only as an optional inset, never instead
  of the camera view.
- One continuous take is the most convincing. If you cut, never cut between an iPhone action
  and its result on the Mac.
- Install Remote 0.2.2 (build 4) from TestFlight or the review build. Show the version in
  iPhone Settings → About at the start.
- Mac: Kinrox 0.5.9 from the public DMG. Show Kinrox → About with the version.
- Reset pairing before filming so the first pairing is real: on iPhone forget the Mac (or
  delete and reinstall the app so the Local Network prompt appears again); on the Mac remove
  the paired iPhone in Settings → Remote.
- Use an owned or freely licensed MP4/MKV with fictional or neutral file names, and two or
  more such files in one folder for Next/Previous. No commercial films.
- Hide personal data: turn on Do Not Disturb on both devices; avoid showing the Spotify
  account e-mail, Client ID, Keychain dialogs, Wi‑Fi password, or real names of other devices.
- Keep Kinrox playback volume low. The video does not need sound; optional narration or
  on-screen captions in English help the reviewer.
- Target length 3–5 minutes, landscape 1080p, MP4.

## Shot list

| # | Action | What must be visible |
|---|---|---|
| 1 | Show both devices; open Kinrox on the Mac and Kinrox Remote on the iPhone. Show both version numbers. | Mac 0.5.9 About panel; Remote 0.2.2 (4) in Settings → About |
| 2 | Mac: Settings → Remote, enable the remote, open Connect iPhone. | Pairing sheet with the six-digit code |
| 3 | iPhone: allow Local Network access, wait for the Mac in the player list, tap it. | iOS permission prompt; Mac appears via local discovery |
| 4 | Enter the six-digit code shown on the Mac. | Code entry on iPhone; Mac sheet closes; iPhone shows the connected remote |
| 5 | Mac: open a local video (drag a file or File → Open). | iPhone shows the title, duration and running time |
| 6 | iPhone: Pause, then Play. | Video stops and resumes on the Mac; button state changes on iPhone |
| 7 | iPhone: −10 s, +10 s, −30 s, +30 s, then drag the scrubber. | Mac position jumps each time; times match |
| 8 | iPhone: move the volume slider. | Mac volume control moves |
| 9 | iPhone: Fullscreen on and off. | Mac enters and leaves fullscreen |
| 10 | iPhone: Next and Previous. | Mac switches to the next file in the folder and back |
| 11 | iPhone: open Recents, pick another file. | Mac opens that file |
| 12 | iPhone: start the Matrix screensaver, then stop it. | Mac shows the screensaver after pausing and returns to the paused video |
| 13 | Mac: switch to Spotify (already connected), play a track. iPhone switches to the music deck. | Track title and artwork on both devices |
| 14 | iPhone: Pause/Play, Previous/Next, volume, open the queue, a favorite action, then Listen to similar and Not interested. | Each change happens on the Mac |
| 15 | Lock the iPhone. Use the Live Activity on the Lock Screen: play/pause, ±10 s (video) or previous/next (music), volume. Show the Dynamic Island if the phone has one. | Lock Screen card; Mac reacts to each press |
| 16 | Unlock; iPhone Settings: show the Lock Screen controls toggle and Try Demo without Mac. | Settings screen |
| 17 | Close the media on the Mac. | iPhone shows "nothing playing" and the Lock Screen card ends |
| 18 | Optional: forget the Mac on the iPhone. | Mac returns to the unpaired state |

If time is short, shots 1–11, 13–15 and 17 are the minimum that covers pairing and the full
workflow. Spotify on the Mac needs the user's own Client ID and the downloaded Soloist engine,
so the reviewer cannot easily reproduce it; that is why it belongs in the video.

## Hosting

Upload as an unlisted YouTube video, an unlisted Vimeo video, or a public file link (iCloud
Drive, Google Drive, Dropbox) that opens without signing in. Check the link in a private
browser window. Keep it available until the app is approved.

## Then

1. App Store Connect → Kinrox: Mac Remote Control → 0.2.2 → App Review Information → Notes:
   add the line `Demo video (physical iPhone with Mac): <URL>` at the top of the existing notes.
   `AppStore/review/notes.txt` is updated with this line and the Mac 0.5.9 DMG.
2. Reply in App Review (Resolution Center) with the message below.

## Reply to App Review

> Hello,
>
> Thank you for the review. We have added a demo video to the App Review Information section:
> <URL>
>
> It was filmed with a separate camera and shows Kinrox Remote 0.2.2 (4) on a physical iPhone
> together with the designated hardware, a Mac running the free Kinrox player 0.5.9. The video
> covers the initial pairing (local network discovery and the six-digit code shown on the Mac),
> then the complete workflow: play/pause, seeking, volume, fullscreen, next/previous file,
> recent files, the screensaver, music controls with the queue and Similar, and the Lock Screen
> controls.
>
> No account or password is required. The Mac player is a free public download:
> https://github.com/awaik/Kinrox/releases/download/v0.5.9/Kinrox-0.5.9-arm64.dmg
> The interface can also be explored without a Mac via Settings → Try Demo without Mac
> (demo pairing code 482913).
>
> Best regards
