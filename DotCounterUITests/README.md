# Native runtime acceptance

`CountingWorkflowTests.swift` runs the shared counting workflow through the real UIKit or AppKit interface. It opens a bundled QA photo, adds three markers, checks Undo/Redo, identifies an existing center without duplication, switches to Edit, removes/restores a marker, verifies a horizontal renumber changes the rightmost label to 3, drags without placement, navigates with zoom/Fit, and verifies recovery plus a new appended marker after relaunch.

The UIKit-only second case rotates to landscape, verifies the count remains intact, generates the actual full-resolution annotated PNG preview, checks that its save action becomes available, checks editable-count/original-photo guidance, dismisses export, and returns to portrait without changing the count.

Each case supplies a unique `DOTCOUNTER_QA_SESSION` UUID. DEBUG app startup uses a separate temporary recovery directory for that session, with the bundled `QA-flock.jpg` only when that session has no current count. Relaunch keeps the same UUID. Tests do not clear or read the user's ordinary current workspace, select Photos, save into external folders, or access any physical device.

Run only explicit development-Mac or local-simulator destinations. For example:

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project DotCounter.xcodeproj -scheme DotCounterIOS \
  -destination 'platform=iOS Simulator,id=54B95BBD-192C-44CB-A33C-19ACA1BB1008' \
  -jobs 4 -parallel-testing-enabled NO
```

The development Mac's `xcode-select`, accessibility permissions, and other settings are preserved. No physical-device inventory command is needed. The build/test SDK is iOS 27.1; the verified local runtimes below are iOS 27.0, separate from the app's iOS 17 minimum deployment target.

Evidence is under `pipeline/image-counting/implementation-evidence/`:

- `ios-ui-tests.xcresult` / `.log`: iPhone 18 Pro, iOS 27.0 (24A434), arm64; full counting workflow passed, 86.057 seconds.
- `ipad-ui-tests.xcresult` / `.log`: iPad Pro 13-inch (M5), iOS 27.0 (24A434), arm64; full counting workflow passed, 118.191 seconds.
- `ipad-rotation-export-final.xcresult` / `.log`: focused iPad rotation/generated-preview case passed, 36.635 seconds.
- `iphone-ui-final.xcresult` / `.log`: final native Count/Edit control and button-style smoke on iPhone 18 Pro, full counting workflow passed, 80.906 seconds.
- `iphone-workspace.png`, `ipad-workspace.png`: final-style native recovered-workspace screenshots. iPhone is exported from the final XCTest result; iPad was refreshed by installing the same latest binary, reopening its completed isolated four-marker QA session, and capturing through explicit local `simctl io` after verifying a real frame.
- `ipad-export-preview.png`: generated-PNG preview attachment. XCTest's landscape screenshot includes EXIF orientation metadata; keep the original result as authoritative capture evidence.
- `mac-ui-tests-3.xcresult` / `mac-ui-tests.log`: native Mac app and UI test runner built. The runner never reached a case startup during a bounded wait, so only task-owned runner/build processes were stopped. This is an automation-startup limitation; it does not establish a pass or failure of the Mac product workflow. The Engineer separately verifies Mac interaction through CUA.

Earlier interrupted/compile-retry results are retained for diagnostics, not counted as successful runtime checks. These functional tests do not establish dense-image frame latency, minimum-OS execution, VoiceOver behavior or every native destination's save/cancel/failure behavior.
