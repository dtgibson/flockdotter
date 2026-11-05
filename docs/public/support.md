# Flock Dotter support

Flock Dotter helps you count birds in a still photo by adding visible marks. You identify the birds and check the result. Optional experimental **Detect birds** makes local suggestions that require review; it can fail, miss birds or include false positives. Manual counting remains available.

## Keep a count you can edit later

Export both **Count JSON** and **Original photo**. Reopening the JSON requires the exact original image bytes; an edited, recompressed or resized copy will not match. A PNG is a picture of your count, not an editable count file. The app recovers one current workspace, so export it before replacing it or confirming **Clear workspace**.

## Common questions

- **A photo will not open:** use a supported still-image file. Image limits are 64 megapixels, 32,768 pixels on a side and 256 MiB of original data. A provider error can require choosing or downloading the file again.
- **Detection refuses or stops:** the experimental detector has stricter workload and resource limits than manual counting. Many full-resolution phone photos are refused. It needs substantial local memory and cache space and a scan may time out. Continue manually; a canceled or failed scan must leave committed markers unchanged.
- **A suggestion is wrong:** reject or skip it during review, add missed birds manually and check all proposed additions before applying. The app does not certify a total or recognize species.
- **Dense counts feel slow:** very large counts, especially with connection lines, can cause visible delays on cold or zoomed frames. The file-format maximum of 100,000 markers is a capacity limit, not a responsiveness promise. Turn off connection lines or work with smaller counts if useful; keep an export before changing your work.
- **Undo after reopening:** undo history is in memory for the current session, not part of recovery or exported JSON.
- **Clearing:** confirmed clearing removes the app’s active count and recovery. It leaves your original and exports alone.

## Report a problem

Email [developer@dtgibson.com](mailto:developer@dtgibson.com) for support. Include the app version/build, operating system, the steps you took and what happened. Mention whether the problem concerns manual marking, import, export, recovery or detection. Do not publish private photos or sensitive location information. A small non-sensitive reproduction is more useful than a full personal library. Do not post credentials, signing files or account receipts.

There is no app account to delete and no developer-held photo/count database. See the [privacy policy](privacy.md), [source and licensing guide](licensing.md) and [credits](credits.md).
