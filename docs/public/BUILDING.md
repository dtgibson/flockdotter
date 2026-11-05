# Building Flock Dotter

Use a development Mac with Xcode 27.1, Swift 6.4, XcodeGen and Git LFS. The project targets iOS/iPadOS 17 and macOS 14. Building with a newer SDK does not establish execution on those minimum versions. The native Mac release is distributed through GitHub Releases, separately from the iPhone/iPad App Store submission.

```sh
brew install xcodegen git-lfs
git lfs install
git clone https://github.com/dtgibson/flockdotter.git
cd flockdotter
git lfs pull
xcodegen generate
```

The exact Core ML weights are in Git LFS. A source ZIP containing only an LFS pointer is insufficient. The weight file must be 539,500,736 bytes with SHA-256 `a3e4fca75edf170997708921427f774f902ee4fe472dbe49e92073d79ce4a159`. The graph, manifest and weights together are 540,953,605 bytes. The frozen per-file hashes are in `DotCounter/Resources/BirdPrototype/prototype-contract.json`; `scripts/prepare-public-tree.py` checks each before producing a source snapshot. The model is distributed under its retained third-party grants; the first-party AGPL license does not replace those grants.

For an unsigned simulator build, select an installed **local simulator** in Xcode, then use its simulator UUID in place of `SIMULATOR_UUID` below. Do not enumerate, connect to, install on or run against physical devices. Set the developer directory per process; do not change global `xcode-select` settings.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -jobs 4 -project DotCounter.xcodeproj -scheme DotCounterPublicStoreIOS \
  -configuration PublicStore \
  -destination 'platform=iOS Simulator,id=SIMULATOR_UUID' \
  -derivedDataPath build-public CODE_SIGNING_ALLOWED=NO build
```

`PublicStore` is an optimized production configuration that deliberately includes the existing experimental detector, its exact model and notices. It excludes DEBUG-only QA startup/fixture behavior and the bundled QA flock photo. `Release` and `OwnerBeta` are historical configurations with different capability/resource boundaries. Do not substitute an old OwnerBeta binary for a fresh public candidate.

An unsigned generic iOS archive compiles for distribution without accessing a device:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -jobs 4 -project DotCounter.xcodeproj -scheme DotCounterPublicStoreIOS \
  -configuration PublicStore -destination 'generic/platform=iOS' \
  -derivedDataPath build-public-archive \
  -archivePath build-public-archive/Flock-Dotter.xcarchive \
  CODE_SIGNING_ALLOWED=NO archive
```

Signing and TestFlight distribution require the publisher's own Apple account, certificates, profile, reviewed version/build number and explicit release authorization. Supply those settings locally; none is a public-source credential. Do not accept an account agreement or upload while merely building this source. App Store distribution remains subject to the licensing and release conditions in [licensing.md](licensing.md).

## Native universal Mac release

[Mac 1.0 (9)](https://github.com/dtgibson/flockdotter/releases/tag/v1.0-mac-build9) was built from commit `54b80ee786350bf6e9fdd115fa3193a5db86a81e`. The later download/build documentation commit does not change that binary's source. Use the release asset `Flock-Dotter-1.0-build-9-source-with-model.tar.gz` for all 119 exact source files and hydrated model weights. Do not assume GitHub's automatic source archives contain the weights. Verify the supplied `SHA256SUMS` before extracting.

From that source directory, after `xcodegen generate`, build the native AppKit/SwiftUI application with the existing Mac scheme and explicit production configuration:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -jobs 4 -project DotCounter.xcodeproj -scheme DotCounterMac \
  -configuration PublicStore -destination 'generic/platform=macOS' \
  -derivedDataPath build-mac-public \
  -archivePath build-mac-public/Flock-Dotter.xcarchive \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO archive
```

The resulting unsigned app is `build-mac-public/Flock-Dotter.xcarchive/Products/Applications/DotCounter.app`. For the official download, the publisher copied it to `Flock Dotter.app`, signed using Developer ID with hardened runtime, secure timestamp and the unchanged `DotCounter/macOS/DotCounter.entitlements`, submitted a ZIP to Apple's notary service, stapled the accepted ticket to the app, and zipped it with `ditto -c -k --sequesterRsrc --keepParent`. Strict `codesign --verify --deep --strict`, `xcrun stapler validate` and Gatekeeper execution assessment passed on the app and an independently extracted ZIP. Signing requires your own identity and notarization credentials; none is included here. Compiled and signed bytes vary with toolchain, signatures and timestamps.

The binary contains both architectures and declares macOS 14. Execution on Intel, macOS 14 and the final signed production workflow remains unverified. Existing development-Mac runtime checks are separate evidence. The optional detector remains experimental; successful real inference, accuracy and hardware headroom are not established. The known 100,000-marker response criterion fails with multi-second interactions. Do not interpret successful compilation or notarization as certification of those behaviors.

Run the shared contract tests on the development Mac:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --jobs 4 --package-path Packages/DotCounterCore
```

Native UI/hosted tests use the `DotCounterIOS` scheme with Debug and an explicit local simulator destination. DEBUG QA sessions isolate recovery using a fresh `DOTCOUNTER_QA_SESSION` UUID. These tests do not prove the `PublicStore` binary's runtime or detector accuracy. Optional retained research probes skip when their local corpus/results are absent; `DOTCOUNTER_RESEARCH_ROOT` may point to a separately held research directory for the two hosted probes. Research photographs and cached inference outputs are not part of the public source tree.

The app build uses the already converted graph, so no Python, PyTorch, downloaded executable dependency or training dataset is needed. Selected original conversion scripts are retained in `tools/model-origin/`. In the private preparation checkout those same scripts live under the original research path and are mapped by the snapshot tool. They record fixed-text caching, rank-five attention and valid-token-max conversion changes. They depend on pinned upstream source, original weights, a cached prompt tensor, a research crop and a historical Python environment; clean-checkout model regeneration and bit-for-bit Core ML compiler output are **not verified**. The model notices identify revisions and grants. Do not describe the app build recipe as a reproducible training/conversion pipeline.

Source identity means exact input bytes, not bit-for-bit signed archives: Xcode's generated project, compiled model, code signature, timestamps and provisioning can vary by toolchain and publisher. Record the allowlisted source-tree manifest, Xcode version, build settings and actual packaged resource/executable hashes with each release candidate.
