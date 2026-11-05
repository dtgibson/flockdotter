# Privacy implementation notes

These notes map the source implementation to the bundled `DotCounter/Resources/PrivacyInfo.xcprivacy`. They do not replace inspection of the exact app archive or the App Store privacy questionnaire. The user-facing [privacy policy](privacy.md) explains selection, local retention, exports and clearing.

| Manifest category and reason | Actual use |
| --- | --- |
| UserDefaults — `CA92.1` | Read and write the app’s own appearance and connection preferences in `Workspace`, `MarkerAppearance` and `ConnectionPresentation`. No cross-app identifier or tracking use. |
| Disk space — `E174.1` | `BirdDetectionExecutor` checks `volumeAvailableCapacityForImportantUsage` for at least 1,536 MiB before compiling the local model into cache. It refuses when space is insufficient. The value is not sent off-device or used to identify the installation. |
| File timestamp — `C617.1` | `TransientDirectory` uses `fstat` on app-owned transient reader files to validate regular-file identity, byte size and leases. No timestamp is sent off-device. |
| File timestamp — `3B52.1` | The import/export workflow obtains filesystem metadata for files/directories selected through the system document picker. Access stays within the selected document/workspace workflow. |
| System boot time — `35F9.1` | `ContinuousClock` measures elapsed work and enforces detection cancellation/deadline boundaries. This is duration measurement, not an installation identifier; it is not transmitted. |

The manifest declares an empty collected-data-types array, no tracking and no tracking domains. Source inspection found no app network client, analytics or advertising integration. Explicit Help links open GitHub in the browser; that external service’s terms and privacy policy apply. System file providers may perform their own network operations when selecting or saving a document. Local unified logs and DEBUG-only measurement hooks do not represent developer-side analytics collection.

The final release check must confirm the manifest and all selected resources are actually copied into the `PublicStore` app. Source declarations alone do not prove packaged behavior. The App Store “Data Not Collected” label is the proposed answer for the audited app behavior, subject to exact candidate verification and publisher confirmation. A privacy manifest is a separate declaration from the App Store label.

Apple references: [describing required-reason API use](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api), [TN3183](https://developer.apple.com/documentation/technotes/tn3183-adding-required-reason-api-entries-to-your-privacy-manifest), and [App Store review privacy requirements](https://developer.apple.com/app-store/review/guidelines/#privacy).
