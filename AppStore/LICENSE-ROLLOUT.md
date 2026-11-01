# Remote personal-use license rollout

Owner-authorized repository change: November 1, 2026. This checklist concerns
future RemoteiOS builds; it does not change the previously uploaded 0.1.0 (1)
build or its existing recipients' rights.

## Repository changes

- Remote-specific material uses [Kinrox Remote Personal Use License 1.0](../RemoteiOS/LICENSE.txt).
- [The shared-code exception](../SHARED-LICENSE-EXCEPTION.md) permits the included
  Kinrox-owned shared modules and resources to be used in that remote while
  preserving their independent GPL rights. No libmpv/FFmpeg is linked into iOS.
- About text, the license link, and bundled license documents distinguish this
  remote from the GPL Mac player. Translated summaries do not replace the license.
- Future contributions must include the necessary grants; Git authorship alone
  does not establish ownership of third-party code or assets.

## Before a new App Store submission

1. Review rights in the exact archive, including any later contributions and
   assets. Keep separately licensed components and their notices identifiable.
2. Assign a new version/build and archive the revision carrying this license.
   Do not describe the already processed 0.1.0 (1) build as relicensed.
3. Prepare and configure a custom EULA in App Store Connect for the intended
   territories. The repository license alone does not replace Apple's standard
   EULA, whose usage rules can permit enterprise use. Reconcile the custom EULA
   with Apple's current minimum terms, including the actual developer contact,
   Apple-specific acknowledgements, support, warranty, and third-party-beneficiary
   provisions. Do not invent contact information or assert completion here.
4. Verify that the store license, localized description, in-app summary, and
   bundled documents agree about personal use and the commercial prohibition.
5. Upload and verify the new archive only under the normal owner-authorized
   delivery workflow. Retain the exact source, license, and store terms for that
   release, and perform the normal device smoke test.

No App Store Connect EULA, metadata, build, or review submission was changed by
the repository licensing task. Publication and store configuration remain
separate release operations.

References checked November 1, 2026:

- [Apple: provide a custom license agreement](https://developer.apple.com/help/app-store-connect/manage-app-information/provide-a-custom-license-agreement/).
- [Apple's standard EULA](https://www.apple.com/legal/internet-services/itunes/dev/stdeula/)
  and [minimum terms for a custom EULA](https://www.apple.com/legal/internet-services/itunes/dev/minterms/).
- [GPL version 3, section 7](https://opensource.org/license/gpl-3.0), governing
  the shared-code additional permission and permissible attribution terms.
