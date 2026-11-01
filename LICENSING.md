# Kinrox licensing

The owner authorized this licensing policy on November 1, 2026. It applies to
revisions distributed with these notices. Copyright (c) 2026 awaik.

## Scope

| Material | Terms |
| --- | --- |
| Mac player (`PlayerMac/`) | [GNU GPL v3 only](LICENSE), with the permitted attribution and origin terms in [NOTICE](NOTICE) |
| iPhone remote (`RemoteiOS/`) | [Kinrox Remote Personal Use License 1.0](RemoteiOS/LICENSE.txt) |
| Kinrox-owned `Shared/`, `SharedTests/`, `Resources/`, `Packages/RemoteProtocol/`, and `Packages/KinroxMusic/Sources/MusicCore/` | GPL-3.0-only and NOTICE, plus the [shared-code exception](SHARED-LICENSE-EXCEPTION.md) for the separately licensed remote |
| Other Kinrox-owned repository files, including scripts and website | GPL-3.0-only and NOTICE, unless a file explicitly states otherwise |
| Third-party code, libraries, assets, and system frameworks | Their original licenses; no new permission is granted on their owners' behalf |

The license documents state their own copying terms. Generated and vendored files
retain the terms of their sources. The [trademark policy](TRADEMARKS.md) concerns
branding, not permission to run, modify, or distribute GPL-covered code.

## What this means

- **Mac:** personal and commercial use, modification, and redistribution remain
  permitted under GPL-3.0-only. Selling copies or subscriptions does not remove
  the obligation to provide corresponding source and preserve recipients' GPL
  rights when distributing the program. Private internal modifications do not
  by themselves require publication.
- **Remote:** individuals may use and modify it for personal, noncommercial
  purposes. Free personal forks may be shared with their corresponding source,
  the same license, attribution, and clear modification notices. Business use,
  commercial exploitation, sales, paid access, and paid subscriptions are not
  licensed. This is source-available software, not OSI open source.
- **Shared material:** the exception permits including the specified shared code
  and resources in the remote without imposing GPL on the remote-specific code.
  The shared material itself remains available under GPL; the remote's commercial
  restrictions do not apply to independent use of that GPL material.
- **Brand:** do not present an unofficial build as an official Kinrox release or
  claim endorsement. Truthful attribution and lawful references remain allowed.

## Earlier releases and previously granted rights

This policy does not revoke or narrow any license already granted. Earlier
GPL-licensed versions, and material independently obtained under that GPL grant,
remain available for use, modification, and redistribution, including commercial
use, under their original terms. A license change in this checkout does not
relicense previously delivered binaries or App Store builds.

The last repository commit inspected before this change was
`b71adb6d73b7ac2bce23af282fc12c807bbde300`. That identifier records the baseline;
the actual license accompanying each copy determines its terms.

## Contributions and distribution

See [CONTRIBUTING.md](CONTRIBUTING.md) before contributing. A contributor must
authorize the applicable license and, for shared material, the shared-code
exception. Third-party material must retain its own notices and be compatible
with its intended use; a Git author name alone is not proof of ownership.

Both apps bundle the applicable legal documents. The App Store rollout requires
a new remote build and the corresponding store license configuration; see
[the rollout checklist](AppStore/LICENSE-ROLLOUT.md). No store configuration,
published release, or live website is changed merely by editing this repository.
