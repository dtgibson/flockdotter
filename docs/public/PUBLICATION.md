# Preparing a source snapshot

From this checkout, use the following command to create a review copy of the app, tests, resources, licenses and build instructions.

```sh
python3 scripts/prepare-public-tree.py --destination "$PWD/build-public-tree-review"
```

The destination must be new. A sibling manifest records the selected files, exact hashes, excluded tracked paths and any signing-setting redactions. The tool excludes private operational records and generated output. Review the resulting snapshot and build it using [BUILDING.md](BUILDING.md). Each binary release should identify its matching source revision and retain the applicable licenses.
