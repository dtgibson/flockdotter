# Flock Dotter

Flock Dotter is a native app for counting birds in one still photo. Add visible marks, correct them with Undo/Redo, and keep an editable count with the unchanged original photo. Optional experimental **Detect birds** runs locally and proposes marks for review. It can fail, miss birds or suggest false positives; you check every result and manual counting remains available.

A signed and notarized native Mac download is available in [GitHub Releases](https://github.com/dtgibson/flockdotter/releases/tag/v1.0-mac-build9) for macOS 14 or later, with Apple Silicon and Intel code. Download `Flock-Dotter-1.0-build-9-macOS-universal.zip`, extract it and move **Flock Dotter.app** to Applications. The release includes checksums and matching source with the full model. Intel execution and minimum-version runtime have not been verified.

Flock Dotter is available free for iPhone and iPad on the [App Store](https://apps.apple.com/app/id6827793703), with no in-app purchases. Read the experimental detection and performance limits below before relying on a count.

## What it does

- Open an image using selected-item Photos access or Files; pan, zoom and Fit the whole photo.
- Add, remove and move marks; choose numbered dots, plain dots or numbered pins and five colors.
- Renumber left to right, top to bottom or by a deterministic nearest-unvisited route; optionally connect marks in label order.
- Recover one active photo/count after relaunch and explicitly confirm permanent workspace clearing.
- Save editable JSON and an unchanged original-photo copy, or export a full-resolution annotated PNG.
- Request local experimental bird suggestions, accept/reject or skip them, mark missed birds and add the reviewed batch with normal Undo/Redo.

A running total records your marks; it is not a certified bird count. The app does not identify species. Detection has tighter workload/resource limits than manual counting and often refuses full-resolution phone photos. Very large counts and connection lines can cause visible delays. The 100,000-marker file-format maximum is a capacity limit, not a speed promise.

## Privacy and keeping your work

No app account, backend, advertising, tracking or analytics service is used. Processing is local. System Photos/Files providers and destinations may use their own cloud services. Recovery holds one workspace; export JSON **and the exact original photo** before replacing it. An edited or recompressed photo will not reopen an existing count. Clearing removes app-local recovery, leaving originals and exports alone. Undo history does not survive relaunch.

Read the [privacy policy](docs/public/privacy.md) and [support guide](docs/public/support.md). Source, privacy and support documents are publicly available in this repository.

## Build from source

The app uses Swift 6, SwiftUI, native UIKit/AppKit canvas adapters, Apple system frameworks and the local `DotCounterCore` package. Technical project, executable and bundle identifiers retain the name DotCounter. Minimum targets are iOS/iPadOS 17 and macOS 14; modern-SDK compilation does not establish minimum-version or Intel runtime behavior. The native Mac download is distributed directly through GitHub Releases; it is separate from the iPhone/iPad App Store submission.

Use a development Mac with Xcode 27.1, Swift 6.4, XcodeGen and Git LFS. Obtain the exact model bytes with `git lfs pull`; a pointer-only source ZIP is insufficient. See [BUILDING.md](docs/public/BUILDING.md) for complete commands, model identity, tests, signing boundaries and model-conversion reproduction limits.

```sh
brew install xcodegen git-lfs
git lfs install
git clone https://github.com/dtgibson/flockdotter.git
cd flockdotter
git lfs pull
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --jobs 4 --package-path Packages/DotCounterCore
```

The fresh production candidate uses `DotCounterPublicStoreIOS` / `PublicStore`, deliberately including the detector/model/notices and excluding DEBUG-only QA behavior and imagery. Ordinary `Release` and `OwnerBeta` have different historical boundaries. Compilation alone does not prove candidate runtime, successful detection, accuracy, accessibility or fold optimization.

Development verification uses only the development Mac and explicit **local simulators**. Never discover, enumerate, inspect, connect to, control, install on or test on any physical device. Physical installation/testing belongs to the owner and testers through TestFlight. Set `DEVELOPER_DIR` per process; preserve global Xcode and automation settings.

Task-owned simulator destinations on the preparation Mac are iPhone 18 Pro `54B95BBD-192C-44CB-A33C-19ACA1BB1008`, iPad Engineer `F8807CC8-B967-41FE-BADB-47095DBB976C` and Adaptive Duo Engineer `E632FC16-6D22-4B3E-BD2C-CC755845A8BB`. These UUIDs refer to local simulators, not connected hardware. Other contributors should choose their own installed local simulator in Xcode and pass that explicit UUID as described in BUILDING.md.

## Source and licenses

First-party work is **GNU AGPL version 3 only** (`AGPL-3.0-only`), with no App Store exception or separate store grant. See [LICENSE](LICENSE), [NOTICE](NOTICE), [licensing](docs/public/licensing.md), [third-party notices](THIRD_PARTY_NOTICES.md) and [credits](docs/public/credits.md). Fonts, model material and photographs keep their separately stated grants. User-selected photographs are not relicensed by this project.

The selected CountGD-derived Core ML model is stored with Git LFS. Full MIT/Apache lineage, source pins and modifications accompany it in `DotCounter/Resources/BirdPrototype/`. The app build uses that exact converted package; historical training/conversion reproducibility and all training-data rights are not certified. Read the retained limitations before redistributing.

[PUBLICATION.md](docs/public/PUBLICATION.md) explains the allowlisted public-tree proposal and history consequences. Private diagnostics, signed packages, account receipts and research corpora are not public-source dependencies and are excluded from the prepared public tree. Cleaning the current tree does not sanitize repository history.
