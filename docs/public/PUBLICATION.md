# Source publication preparation

The source and store release are separate decisions. Local preparation does not push a commit, alter repository visibility, publish a website, upload a build or submit to App Review.

`scripts/prepare-public-tree.py` creates a new local snapshot from an explicit allowlist. It includes app/core sources and tests, licensed resources, the exact hydrated Core ML model and notices, public documentation, project generation configuration and selected original conversion scripts. It excludes Git metadata/history, generated Xcode projects, private pipeline reports, prior release receipts/packages, operational preview servers, local account configuration and research datasets/results. It refuses missing required files, LFS pointers, symlinks, unexpected file types and known private metadata patterns. This is a review aid, not proof that every possible confidential fact has been detected.

```sh
python3 scripts/prepare-public-tree.py --destination "$PWD/build-public-tree-review"
```

The destination must not exist; the tool never removes an old snapshot. A sibling JSON manifest records every input/output file hash, exclusions and any signing-setting transformation. The model files must match the frozen contract. Review the manifest before treating the snapshot as a publication proposal. Generate the Xcode project inside the snapshot with XcodeGen and follow [BUILDING.md](BUILDING.md). Recreate the snapshot after source or resource changes; an earlier hash does not identify a later binary.

The public recipe removes historical iOS signing team/profile/identity/style defaults if present, and requires the publisher to supply signing locally. All such transformations appear in the manifest. App sources and model bytes are copied unchanged. The `.gitignore` supplied by the snapshot tool is an explicitly generated public build-output/credential exclusion policy. The original private checkout and evidence remain intact.

Cleaning the latest tree does not clean Git history. Making an existing repository public can expose earlier trees, authorship, tags/branches, Git LFS objects and associated issues, pull requests, releases, Actions artifacts, wiki/Pages and other repository surfaces. A zero-finding credential scan does not clear contextual private information or guarantee that all secrets have been found.

Before publication, the owner must explicitly choose and authorize a concrete history plan. Retaining history keeps its historical content visible. A sanitized new-root/history replacement requires a reviewed exact candidate, a complete verified private backup, an impact plan for clones/refs/LFS and separate authorization before any ref rewrite. No history rewrite, mirror publication, force push, branch/tag deletion or visibility change is performed by this tooling.

A backup should cover all remote refs, Git objects, Git LFS objects and repository-surface records needed for restoration, separately from local-only source changes, ignored evidence and immutable packages. Verify object integrity and LFS inventory, test restoration in an isolated private directory, record checksums and keep every copy private. A Git bundle alone does not contain LFS content or GitHub issues/releases/Actions settings. The preparation report records the current read-only inventory and what remains unverified; it is intentionally excluded from this public tree.

Public support, privacy and corresponding-source links must resolve for a person outside the developer's private network before a store submission. Local Markdown files and private development previews do not satisfy that requirement. Publishing these endpoints, resolving AGPL/App Store distribution rights and accepting legal/regional declarations require their own final disposition.
