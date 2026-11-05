# Flock Dotter privacy policy

Last updated: 4 November 2026.

Flock Dotter processes your selected photos and counts on your device. The app has no account, advertising, tracking, analytics service or developer-operated server. The app does not send photos, marker coordinates, counts or detection results to the developer or a third party.

## Photos and files you choose

Use the system Photos picker or Files picker to choose an image. Flock Dotter receives the selected item; it does not request access to your entire Photos library. A Files or Photos provider may download your selection from its own cloud service under that provider’s terms. Flock Dotter copies the selected image into its local workspace without changing the original bytes. Embedded image metadata can remain in that copy.

## Local storage and detection

The app retains one active photo and its committed markers in app-local recovery storage so you can continue after relaunching. It requests that the recovery directory be excluded from system backups; backup behavior is ultimately controlled by the operating system. Appearance and connection preferences are stored locally. Undo history and uncommitted detection-review decisions are temporary and are not restored after relaunch.

If you choose **Detect birds**, the bundled experimental model runs locally. Photos are not uploaded for inference. The app checks local memory and available cache space and may create temporary compiled-model files. Detection can refuse a photo, fail, time out, miss birds or suggest false positives. Suggestions change the committed count only after your review and explicit addition.

## Exports and clearing

You choose whether and where to save editable count JSON, an unchanged original-photo copy, or an annotated PNG. JSON contains image dimensions, a hash identifying the original image and marker identifiers/coordinates. An original-photo export retains the original file, including any embedded metadata. Your chosen destination or file provider may sync or share exported files according to its settings.

**Clear workspace** requires confirmation and removes the active workspace and its local recovery. It does not delete the original in Photos/Files, any exported files, or copies held by another provider. Export anything you want to keep before clearing, replacing the workspace or removing the app. The app has no remote copy from which the developer can restore your work.

## Links and support

Opening the source, license or support links uses your browser and network connection. GitHub and any linked website have their own privacy policies. If you voluntarily submit a support report, the information you include is visible to its recipient; public GitHub issues are public. Do not include private photographs, precise sensitive wildlife locations or personal information in a public report.

For privacy questions or support, email [developer@dtgibson.com](mailto:developer@dtgibson.com). Email is handled outside the app by the sender’s and recipient’s email providers. See [Flock Dotter support](https://github.com/dtgibson/flockdotter/blob/main/docs/public/support.md). Source and policy changes are available in the [source repository](https://github.com/dtgibson/flockdotter).

The app bundles a privacy manifest describing the local system APIs it uses and declaring no tracking or collected data types. See the [implementation notes](privacy-implementation.md) for the source-level mapping.
