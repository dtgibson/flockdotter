# DotCounterCore

Apple-framework-only shared logic for iOS 17 and macOS 14 or newer. Build and run its XCTest acceptance fixtures on the development Mac:

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path Packages/DotCounterCore
```

The public JSON trust boundary is `CountDocument.decode(_:)`, not a direct `JSONDecoder` call. It checks UTF-8, bounded syntax, duplicate required keys, required types, finite/ranged coordinates, UUID uniqueness, exact format/version, image dimensions and filename safety before returning a count. Unknown fields have no semantic effect. `JSONValidation.validateSyntax(_:)` provides the same syntax/duplicate-key preflight for the private recovery manifest, which must then be decoded and validated by the recovery service.

Current explicit ceilings: 32 MiB of marker JSON, 64 levels of JSON nesting, 100,000 markers, 64,000,000 upright source pixels and 32,768 pixels per side. File/image services also bound source-byte and image allocation work before decode. These ceilings admit the required 6,000 × 4,000 image with 1,000 markers; an oversized input is rejected as a candidate rather than truncated or partially committed.

`contentDigest` uses a versioned canonical byte encoding, independent of JSON key ordering: length-prefixed UTF-8 strings, unsigned big-endian 64-bit dimension/count integers, ordered lowercase UUID strings, and big-endian IEEE-754 coordinate bits. Negative zero is normalized. The digest includes source identity including its filename hint and all markers in label order.

`MarkerHistory` stores commands, not document/image snapshots. A reorder stores UUID order only; move stores one before/after marker; insert/delete retain one marker and index. It retains exactly the latest 1,000 commands, with a redo branch until the next committed edit. The UI owns history on its main actor and increments its revision only when a command returns `true`.

`ViewportTransform` uses top-left canvas coordinates and full-source normalized marker positions. It permits exact boundary centers, rejects points outside the image, keeps fit as the minimum, supports 32× fit, preserves focal points within pan limits and keeps the image focal point during resize. Marker hit testing uses the nearest center and lower current label to resolve exact ties.
