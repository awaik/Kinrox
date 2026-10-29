# App Localization — 30 Locales

> Implemented on 2026-10-27 at the owner's request. English remains the source and fallback language. Changes remain uncommitted for owner review.

Both PlayerMac and RemoteiOS follow the operating system's preferred app language. No in-app language selector or translation service is used. Changing the app language in system settings requires relaunching the app.

## Supported Locales

| Code | Language |
|---|---|
| en | English |
| ru | Russian |
| es | Spanish |
| fr | French |
| de | German |
| pt | Portuguese |
| it | Italian |
| zh-Hans | Chinese, Simplified |
| zh-Hant | Chinese, Traditional |
| ja | Japanese |
| ko | Korean |
| ar | Arabic |
| hi | Hindi |
| bn | Bengali |
| ur | Urdu |
| id | Indonesian |
| ms | Malay |
| vi | Vietnamese |
| th | Thai |
| tr | Turkish |
| fa | Persian |
| pl | Polish |
| uk | Ukrainian |
| nl | Dutch |
| ro | Romanian |
| el | Greek |
| cs | Czech |
| sv | Swedish |
| hu | Hungarian |
| he | Hebrew |

The owner approved this practical coverage list, counting the two Chinese writing systems separately. It is not a population ranking. Portuguese currently uses Brazilian wording; separate regional variants can be added later.

## Implementation

- Both XcodeGen targets include `Resources/Localization`. Each locale contains `Localizable.strings` with 231 UI keys and `InfoPlist.strings` with the local-network permission description.
- `Shared/Localization.swift` localizes strings at their source. This covers AppKit panels, SwiftUI menus, custom controls, accessibility labels, settings, connection states, and application-owned error messages.
- `L10n.format` inserts literal device names, filenames, times, and counts into translated format strings. Current resources use ordered `%@` arguments. Never interpolate a dynamic name into a localization key.
- Count labels use neutral constructions such as `devices: %@`; they do not concatenate English singular/plural words. Dates and counts use the current locale, replacing the previously fixed Russian date locale.
- SwiftUI follows system layout direction. Numeric PIN cells, keypad rows, scrubbers, and playback transport controls explicitly retain left-to-right ordering to match their gesture coordinates and physical time direction.
- The iPhone maps protocol error codes to its own local messages. Protocol fields, wire diagnostics, logs, device names, and media titles are not translated. Low-level libmpv and OS diagnostic details may remain in their original language beneath localized error headings.
- Source code, documentation, and localization keys remain English. User-visible translation resources and translation test expectations are the exception authorized by the owner.

## Verification

Run resource validation and both hosted test suites:

```sh
python3 Scripts/check-localization.py
./Scripts/generate.sh
xcodebuild -workspace Kinrox.xcworkspace -scheme PlayerMac -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData test
xcodebuild -workspace Kinrox.xcworkspace -scheme RemoteiOS -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath DerivedData test
```

`SharedTests/LocalizationTests.swift` runs in both apps. It checks that the built app contains all 30 locales, matching key sets, nonempty translations and permission prompts, valid placeholder counts, bundle lookup and English development language, regional language matching, and safe insertion of names containing percent characters.

Verified on 2026-10-27: PlayerMac passed 68 tests; RemoteiOS on the iPhone 17 simulator passed 46 tests. Both include the shared resource tests. All 60 resource files pass `plutil` validation, and all 30 locales pass the source-key/placeholder validator. Touched Swift files pass strict formatting checks. Whole-tree formatting still reports pre-existing issues in untouched tests and shared design/time helpers. The existing Homebrew libmpv deployment-target linker warning remains.

The resource validator also checks source-code key coverage. Adding a UI key requires updating every locale. No English placeholder translations are generated automatically.

For visual verification, launch the iOS Debug app in demo mode with `-KinroxDemo -KinroxScreen remote -AppleLanguages '(ar)' -AppleLocale ar`. Use `pairing` or `recents` instead of `remote` for those screens. Inspect German for text expansion, Arabic for right-to-left layout, and Chinese for CJK rendering, including on a small phone.

Visual checks completed on the iPhone SE simulator (iOS 18.5): German playback controls, Arabic pairing, and Simplified Chinese playback controls. Labels fit the small screen, Arabic navigation follows right-to-left layout, and the keypad/PIN cells retain left-to-right order. Screenshots were retained in `/tmp/kinrox-localization-qa.EXKiEY`.

Translations are an initial authored pass. Native-speaker editorial review and exhaustive visual review of all languages on physical devices remain release checks.

App Store preparation on 2026-10-28 added localized Privacy Policy and Support labels to the iPhone Settings/About section. The shared resource set now contains 183 UI keys in all 30 locales. Store metadata, screenshots and release requirements are in `AppStore/README.md`.

Mac track selection on 2026-10-29 added 48 translated keys in all 30 locales, bringing the shared resource set to 231 keys. Source coverage, placeholders, the Mac hosted localization tests, and whole-tree Swift formatting passed. These new panels were visually checked on macOS in English; exhaustive language review remains a release check.
