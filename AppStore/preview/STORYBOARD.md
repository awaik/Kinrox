# App Preview 01 — Movie night, within reach

Status: script and captions only. No video has been produced or uploaded.

## Creative direction

A 27-second portrait demonstration of the real iPhone remote. Lead with the main control screen and a visible pause response in the first second. Use the warm black, ivory and ember palette from the screenshots. Let the controls and their state changes carry the story. No introductory logo animation.

The viewer must understand that this controls Kinrox on a Mac, requires the same local network, and does not play films on the iPhone. Keep a concise localized Mac/local-network requirement visible in the safe area. The story works with audio muted. Optional music must be owned or licensed; no speech is needed.

## Edit decision list

| Time | Actual app footage and action | English overlay | Russian overlay |
|---|---|---|---|
| 00:00–00:04 | Connected Remote screen, fictional file name visible. Tap Pause within the first second; the timer stops and the button changes. Resume. | Movie night. Within reach. | Кино на Mac. Пульт в руке. |
| 00:04–00:09 | Tap −10, then +30, and drag the scrubber to a clear position. Keep the time display visible so each action has a result. | Catch that moment again. | Тот самый момент. Ещё раз. |
| 00:09–00:13 | Drag the volume slider and tap the fullscreen control. Show the slider value and control state changing in the actual UI. | Set the mood. From your seat. | Устройтесь поудобнее. |
| 00:13–00:18 | Open Recent. Tap an available fictional title. Return to the remote as the title and duration change. | Your next film. One tap away. | Следующий фильм. Одно касание. |
| 00:18–00:23 | Cut to the real pairing flow. Select the nearby Mac, enter its current six-digit code, then show the connected remote. Allow enough time to see the successful transition. | One code. You’re connected. | Один код. И вы на связи. |
| 00:23–00:27 | Hold on the connected main screen while playback time advances. End with the app still visible, matching the opening composition. | Requires Kinrox for Mac · Same local network | Нужен Kinrox на Mac · Одна локальная сеть |

The localized SRT files in `captions/` are editorial timing guides for burned-in overlays. They are not a video upload and are not accessibility captions for the movie content. Use the accompanying localized screenshot description as optional secondary copy only if legibility and reading time permit it. The final requirement must remain visible in every language, including at the opening.

## Production specification

- Capture the actual release candidate on a physical iPhone connected to the released Mac player. Simulator demo footage is useful for rehearsals; the final cut should demonstrate real device behavior.
- Set Kinrox playback volume on the Mac to zero while testing. Do not change system volume. The recorded slider may still move as part of the demonstration; restore zero immediately afterward.
- Target 886 × 1920 portrait, 30 fps, H.264 MP4, progressive, approximately 10–12 Mbps. Stay below 500 MB. A 27-second cut fits Apple's 15–30 second range.
- Keep aspect ratio consistent with portrait screenshots so the preview occupies the main media sequence. Final placement and autoplay remain controlled by App Store and user settings.
- Choose a poster frame around 00:01.5: main remote, clear headline and Mac requirement, no transition or empty screen.
- Use real app footage only. Do not film fingers, phones on a couch, device bezels, or a person using the app for this App Preview. Those concepts can be used in a separate website or social advertisement.
- Use fictional filenames and owned test footage; do not use movie posters, studio logos, copyrighted film clips, real personal device names, notifications, credentials, pricing or unverified performance claims.
- Preserve genuine UI state changes. Do not simulate unavailable features, shorten connection time in a way that implies a guaranteed speed, or present demo behavior as measured real-network performance.
- Record each of the 30 app languages for a fully localized production. Reuse the matching app language for regional metadata variants. Persian captions are retained for other channels because Apple has no Persian metadata locale in its published list.

## Review before producing video

Confirm the concept, the companion Mac download, and the final release UI. Review all captions on a small phone, with audio muted. Check Arabic/Hebrew/Urdu/Persian right-to-left shaping and avoid placing overlays over controls or permission dialogs.

Sources checked October 28, 2026: [Apple App Preview guidance](https://developer.apple.com/app-store/app-previews/), [technical specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/app-preview-specifications), [product page guidance](https://developer.apple.com/app-store/product-page/).
