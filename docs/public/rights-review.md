# Distribution rights review

Prepared 4 November 2026. This records evidence and the remaining release condition; it is not a separate license grant.

## Source and bundled material

The owner requested AGPL version 3 for first-party work. The implementation uses `AGPL-3.0-only` and the complete unmodified GNU text. Copyright control over every first-party contribution, imported fragment and any employer interest must be established by the rights holder before a separate distribution grant can be made. A single named Git author does not establish exclusive copyright control.

The selected CountGD author weights declare MIT at pinned revision `6b989ad11db9413e44863ea5c57735cae6cacff8`; its code has the retained MIT grant. Grounding DINO/BERT lineage has retained Apache 2.0 grants, and Swin/Open-GroundingDino has retained MIT grants. The exact pinned upstream license/model-card files were fetched again during preparation and matched the bundled SHA-256 records. These grants support public source/LFS and binary redistribution of the identified material under their terms. Full notices and the modification record must travel with it. They do not require an owner-only channel.

Historical dataset rights, including Objects365 and FSC-147, are not independently certified. No training or research-corpus images are included in the production model package. This remaining provenance uncertainty is disclosed rather than treated as either proven infringement or universal clearance. Public release requires an explicit evidence-based disposition of that uncertainty and of detector safety/usefulness limits; previous private-beta acceptance is insufficient. The app preserves resource checks and reviewed addition, and describes the detector as experimental, with failures, misses and false positives. It makes no verified-count or accuracy claim.

IBM Plex fonts retain SIL OFL 1.1 and reserved names. Photograph grants are recorded individually in [credits](credits.md) and [third-party notices](../../THIRD_PARTY_NOTICES.md). Apple system SDK/framework usage is a separate system dependency; it does not itself justify adding a broad license exception to this project.

## App Store distribution remains unresolved

AGPL sections 6, 10 and 12 protect recipients’ source and redistribution rights and do not allow contradictory additional restrictions to be imposed. The FSF’s [2010 App Store analysis](https://www.fsf.org/blogs/licensing/more-about-the-app-store-gpl-enforcement) expressly applies its concern to GPL and AGPL. Its quoted Apple terms are historical, so they are not used as the current contract.

Apple’s current [standard EULA](https://www.apple.com/legal/internet-services/itunes/dev/stdeula/) includes a nontransferable Apple-product/Usage-Rules license and transfer/redistribution restrictions, with an exception for certain restrictions to the extent permitted by open-source component licenses. Apple’s [minimum custom-EULA terms](https://www.apple.com/legal/internet-services/itunes/dev/minterms/) also require a nontransferable Apple-product/Usage-Rules scope. The open-source qualification is relevant but does not by itself demonstrate compatibility for distributing this entire AGPL application. A custom EULA consisting only of pasted AGPL text is not an established solution. See Apple’s [custom-EULA workflow](https://developer.apple.com/help/app-store-connect/manage-app-information/provide-a-custom-license-agreement).

Before public App Store binary release, retain either a documented current-terms compatibility basis that covers the actual source/dependencies and distribution mechanism, or an explicit separate grant approved by every necessary rights holder. GNU’s [licensing FAQ](https://www.gnu.org/licenses/gpl-faq.en.html#ReleaseUnderGPLAndNF) explains that copyright holders can offer their own work under multiple nonexclusive licenses; it does not permit relicensing someone else’s work. No separate grant or exception has been made in this preparation. The public AGPL source license must remain as requested.

This condition blocks App Store distribution, not local building, review or preparation. Public source publication still needs a reviewed public tree/history decision and matching source/model availability. Functional public source, privacy and support URLs must be checked after authorized publication; draft documents or authenticated repository links do not yet satisfy public access.

## License text verification

[GNU’s official AGPLv3 plain-text archive](https://ftp.gnu.org/gnu/Licenses/agpl-3.0.txt) supplied root LICENSE verbatim: 34,523 bytes, SHA-256 `0d96a4ff68ad6d4b6f1f30f713b18d5184912ba8dd389f86aa7710db079abcb0`. The duplicate official `/pub/pub/gnu/Licenses/agpl-3.0.txt` path matched byte for byte. Comparison with SPDX’s AGPL-3.0-only text matched all words after whitespace normalization and the official file’s three HTTP→HTTPS URL updates. No project grant or exception is inserted into the license document.
