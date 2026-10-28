# Kinrox Remote — App Store submission

Prepared October 28, 2026. Assets and metadata exist locally; no app record, build or listing has been uploaded by this task. App Store Connect opened at its login page in Chrome. Membership, app-name availability and current account agreements have not been verified.

## Prepared

- 30 authored language packs matching the application's UI resources.
- 35 App Store metadata localizations: name, subtitle, description, promotional text, keywords, marketing, support and privacy URLs. English is the primary language. Text limits and UTF-8 keyword byte limits pass.
- 350 opaque RGB PNGs: five screenshots per store locale at 1206 × 2622 and 1320 × 2868. Ten additional Persian PNGs are kept separately under locale `fa` and must not be uploaded as an unsupported store locale.
- 90 original simulator captures in `screenshots/raw/` with provenance. Capture mode uses the real Debug UI with fictional data; only helper strings for demo status and example PIN were replaced in a copied app bundle.
- Editable English/Russian screenshot masters in [Kinrox — Design, page 03](https://www.figma.com/design/vvWQ5IQdSuOFw2BebZkS8U?node-id=23-304).
- A 27-second App Preview storyboard and localized caption timing guides. No video produced.
- Draft App Review instructions, including the real, visible demo mode and steps to test with a Mac.
- `PrivacyInfo.xcprivacy` declares no tracking/collection and UserDefaults reason `CA92.1` for app-local preferences. The generated iOS target includes the manifest in the built bundle.
- Public privacy and support page files under `site/privacy/` and `site/support/`, ready for the normal website deployment. They have not been published by this task.

## Owner/account decisions

1. **Paid Apple Developer Program membership and App Store Connect access.** A personal free development team cannot distribute on the App Store. Sign in using the account that will own Kinrox. Accept pending Apple agreements yourself if presented.
2. **Price and distribution.** Free without purchases is the preparation assumption, not a saved store price. Confirm it. Language coverage is separate from country availability: choose the territories permitted for this account and product, and complete any country-specific requirements. Do not interpret “all languages” as permission to assert compliance in every territory.
3. **Rights and license.** The repository declares GPL-3.0-only for RemoteiOS, Shared and RemoteProtocol. Confirm ownership of all included code/assets and an App Store-compatible distribution grant. An owner-controlled dual license or exception for the iOS distribution is a possible route; it does not automatically cover contributions owned by others. The Mac libmpv distribution can stay GPL. No licensing files were changed. The iOS target does not link libmpv.
4. **Identity and contact.** Supply the actual copyright holder and review contact (name, email, phone); complete the developer's DSA trader status if distributing in the EU. No contact information was invented.
5. **Encryption declaration.** The app implements a custom handshake/protocol using Apple's CryptoKit primitives (X25519, HKDF/HMAC, ChaCha20-Poly1305). Answer Apple's encryption questionnaire based on that implementation and chosen territories. Do not describe it as “no encryption.” Record the resulting exemption/documentation decision before setting `ITSAppUsesNonExemptEncryption`; it is intentionally not guessed in Info.plist.

## Product/release work before submission

- Ensure the final signed, notarized Mac player is publicly downloadable and pair it with the exact iOS release candidate. Mac release work is running separately in this repository; verify its final artifact and URL rather than relying on milestone text.
- Publish `site/privacy/` and `site/support/` and verify both URLs return the final pages. The iPhone Settings/About section now includes Privacy Policy and Support links, with labels in all 30 languages. The pages must be live before that release is submitted.
- Choose the public app name (proposed: **Kinrox Remote**), primary language `en-US`, bundle ID `app.kinrox.remote`, SKU `kinrox-remote-ios`, and version/build. Repository values at inspection were `0.1.0 (1)`; no shared version values were changed.
- Suggested categories: primary Entertainment, optional secondary Utilities. Complete the age-rating and content-rights questionnaires honestly. Do not infer a rating from sample filenames or claim movie licensing; the app is a local remote with no content catalog.
- The source app icon was verified as 1024 × 1024 without alpha; inspect the final App Store icon preview. Set iPhone-only availability as intended; check Mac/Apple Vision Pro automatic compatibility distribution separately.
- Check all 35 metadata localizations in App Store Connect preview. Native-language editorial review is still pending. The app currently has Brazilian Portuguese UI; regional store variants use the existing matching app-language screenshots.
- Build a signed Release archive, validate it, upload it, and wait for processing. TestFlight smoke test the processed build on a physical iPhone: discovery, fresh pairing, saved reconnect, background/foreground, controls, recents, revocation, denied local network, and demo mode. Simulator tests do not substitute for this release test.

## Upload order

1. Create the iOS app record in the correct team. Reserve the name and bundle ID.
2. Complete app information, content rights, privacy, age rating, pricing/availability, and account compliance fields. Suggested privacy answer from inspected code: **Data Not Collected**, after confirming the release has the same data handling. Local device-to-device exchange is described in the policy.
3. Archive in Xcode with the distribution team. Organizer → Validate App → Distribute App → App Store Connect. Do not use the unsigned validation build as the upload artifact.
4. Resolve export compliance; select the processed build for the version.
5. Add all 35 locales from `manifest.json`. Populate matching metadata folders. Upload each locale's five `1206x2622` files to the required medium Dynamic Island slot; add `1320x2868` to the large Dynamic Island slot. Upload no `fa` folder, contact sheets, raw captures, layout metrics or QA images.
6. Fill review contact and the finalized review notes. Include the companion Mac release link and keep the demo easy to find.
7. Choose **manual release** for the first version so the Mac download, site and iPhone listing can be checked together after approval.
8. Review the exact final listing and submit to App Review. Resolve review feedback, then release when both companion products are ready.

## Validation performed

- Debug simulator build succeeded.
- Generic iOS Release build (unsigned) succeeded. This verifies compilation and packaging, not App Store distribution signing or upload eligibility.
- iPhone 17 Pro Max / iOS 26.5 hosted test suite: **48 tests in 9 suites passed**. Log: `DerivedData/appstore-verification-final.log`; result bundle under `DerivedData/AppStoreVerification/Logs/Test/`.
- Resource validator: 30 locales, 183 UI keys, permission descriptions and format arguments passed.
- Metadata: 30 app languages / 35 store locales validated; names ≤30, subtitles ≤30, promotional text ≤170, descriptions ≤4000, keywords ≤100 UTF-8 bytes.
- All 360 final PNG files have exact declared dimensions and PNG RGB color type 2 (no alpha). Header/detail/footer layout bounds pass for every rendered language.
- Visual QA: English/Russian master layouts, English/Russian five-card overview, representative Arabic, Hebrew, Hindi, Urdu and Simplified Chinese exports. This is not exhaustive native-language copy approval or every-screen device testing.
- Review follow-up: the gallery now uses `screenshots/export-20261028-regional/`.
  All 360 regenerated PNGs passed dimension, RGB and layout checks; the corrected
  es-MX recents and pt-PT fullscreen/pairing artwork was visually inspected.
  Metadata, screenshot text and SRT captions share `localized-copy.json`.
- Source raw captures, temporary copied capture app, simulator and build/test artifacts were preserved. No branches, commits or worktrees were created; pre-existing and concurrent Mac-release changes were left intact.

## Current Apple references

Checked October 28, 2026; recheck the live upload UI before submission.

- [Screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications): medium Dynamic Island images are now the required iPhone set; PNG/JPEG without transparency, up to ten images per slot.
- [Locale shortcodes](https://developer.apple.com/documentation/appstoreconnectapi/managing-metadata-in-your-app-by-using-locale-shortcodes): the current list includes `bn-BD` and `ur-PK`, but no Persian locale. [Store localizations](https://developer.apple.com/help/app-store-connect/reference/app-information/app-store-localizations).
- [Product page guidance](https://developer.apple.com/app-store/product-page/) and [App Preview specification](https://developer.apple.com/help/app-store-connect/reference/app-information/app-preview-specifications).
- [App privacy](https://developer.apple.com/help/app-store-connect/reference/app-information/app-privacy), [Review Guidelines 5.1.1](https://developer.apple.com/app-store/review/guidelines/), and [required-reason APIs](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype).
- [Export compliance](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance) and [encryption documentation](https://developer.apple.com/help/app-store-connect/manage-app-information/determine-and-upload-app-encryption-documentation).
- [Apple Developer Program](https://developer.apple.com/programs/enroll/) and [EU trader requirements](https://developer.apple.com/help/app-store-connect/manage-compliance-information/manage-european-union-digital-services-act-trader-requirements/).
- [FSF discussion of GPL/App Store licensing conflict](https://www.fsf.org/blogs/licensing/left-wondering-why-vlc-relicensed-some-code-to-lgpl): historical background, not a determination of this owner's rights or a substitute for reviewing current distribution terms.
