# Building Flock Dotter

Use Xcode, XcodeGen and the local Swift package. The development toolchain is Xcode 27.2 with Swift 6.4.2. Deployment targets are iOS/iPadOS 17 and macOS 14.

```sh
git clone https://github.com/dtgibson/flockdotter.git
cd flockdotter
xcodegen generate
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test --jobs 4 --package-path Packages/DotCounterCore
```

Build the native Mac app on your development Mac:

```sh
xcodebuild -jobs 4 -project DotCounter.xcodeproj -scheme DotCounterMac \
  -configuration PublicStore -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build-mac 'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO build
```

For iOS tests, replace SIMULATOR_UUID with an installed local simulator’s identifier. The Debug workflow tests use a bundled sample photo and isolate their counts in a temporary workspace.

```sh
xcodebuild -jobs 4 -project DotCounter.xcodeproj -scheme DotCounterIOS \
  -configuration Debug -destination 'platform=iOS Simulator,id=SIMULATOR_UUID' \
  -parallel-testing-enabled NO -derivedDataPath build-ios-tests test
```

Build an unsigned iOS distribution archive:

```sh
xcodebuild -jobs 4 -project DotCounter.xcodeproj -scheme DotCounterPublicStoreIOS \
  -configuration PublicStore -destination 'generic/platform=iOS' \
  -archivePath build-archive/Flock-Dotter.xcarchive \
  -derivedDataPath build-archive CODE_SIGNING_ALLOWED=NO archive
```

PublicStore uses optimized code and excludes the Debug-only fixture and test hooks. Publishers supply their own signing identity and provisioning for TestFlight, App Store and notarized Mac distribution. Find the matching source for a shipped build in its release notes. The [Mac 1.0 (9) release](https://github.com/dtgibson/flockdotter/releases/tag/v1.0-mac-build9) retains its original source and build instructions.
