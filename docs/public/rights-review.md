# Distribution rights review

The first-party source grant is AGPL-3.0-only. This document explains the distinction between the published source license and authorization to distribute an official binary.

## Source and bundled material

The owner requested AGPL version 3 for first-party work. The implementation uses `AGPL-3.0-only` and the complete unmodified GNU text. Copyright control over every first-party contribution, imported fragment and any employer interest must be established by the rights holder before a separate distribution grant can be made. A single named Git author does not establish exclusive copyright control.

IBM Plex fonts retain SIL OFL 1.1 and reserved names. Photograph grants are recorded individually in [credits](credits.md) and [third-party notices](../../THIRD_PARTY_NOTICES.md). Apple system SDK/framework usage is a separate system dependency; it does not itself justify adding a broad license exception to this project.

## Official binary distribution

AGPL sections 6, 10 and 12 protect recipients’ source and redistribution rights and do not allow contradictory additional restrictions to be imposed. The FSF’s [2010 App Store analysis](https://www.fsf.org/blogs/licensing/more-about-the-app-store-gpl-enforcement) expressly applies its concern to GPL and AGPL. Its quoted Apple terms are historical, so they are not used as the current contract.

Apple’s current [standard EULA](https://www.apple.com/legal/internet-services/itunes/dev/stdeula/) includes a nontransferable Apple-product/Usage-Rules license and transfer/redistribution restrictions, with an exception for certain restrictions to the extent permitted by open-source component licenses. Apple’s [minimum custom-EULA terms](https://www.apple.com/legal/internet-services/itunes/dev/minterms/) also require a nontransferable Apple-product/Usage-Rules scope. The open-source qualification is relevant but does not by itself demonstrate compatibility for distributing this entire AGPL application. A custom EULA consisting only of pasted AGPL text is not an established solution. See Apple’s [custom-EULA workflow](https://developer.apple.com/help/app-store-connect/manage-app-information/provide-a-custom-license-agreement).

Before public App Store binary release, retain either a documented current-terms compatibility basis that covers the actual source/dependencies and distribution mechanism, or an explicit separate grant approved by every necessary rights holder. GNU’s [licensing FAQ](https://www.gnu.org/licenses/gpl-faq.en.html#ReleaseUnderGPLAndNF) explains that copyright holders can offer their own work under multiple nonexclusive licenses; it does not permit relicensing someone else’s work. Any separate authorization for an official binary applies to its specified scope. The public AGPL source license must remain as requested.

Verify the source, privacy and support links for each release. The earlier build’s source and license records are available in its [release](https://github.com/dtgibson/flockdotter/releases/tag/v1.0-mac-build9).

## License text verification

[GNU’s official AGPLv3 plain-text archive](https://ftp.gnu.org/gnu/Licenses/agpl-3.0.txt) supplied root LICENSE verbatim: 34,523 bytes, SHA-256 `0d96a4ff68ad6d4b6f1f30f713b18d5184912ba8dd389f86aa7710db079abcb0`. The duplicate official `/pub/pub/gnu/Licenses/agpl-3.0.txt` path matched byte for byte. Comparison with SPDX’s AGPL-3.0-only text matched all words after whitespace normalization and the official file’s three HTTP→HTTPS URL updates. No project grant or exception is inserted into the license document.
