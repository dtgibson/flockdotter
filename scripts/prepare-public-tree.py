#!/usr/bin/env python3
"""Copy the reviewed publication allowlist; never change Git history or publish.

The destination must not exist. The audit manifest remains beside the tree so
private checkout identity is not silently made part of public documentation.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT_FILES = ("README.md", "LICENSE", "NOTICE", "THIRD_PARTY_NOTICES.md", "project.yml")
SOURCE_DIRS = ("DotCounter/Shared", "DotCounter/iOS", "DotCounter/macOS", "DotCounter/Configuration",
               "DotCounterUITests", "DotCounterRegressionTests",
               "Packages/DotCounterCore/Sources", "Packages/DotCounterCore/Tests", "docs/public")
RESOURCE_DIRS = ("DotCounter/Resources",)
EXACT_FILES = ("Packages/DotCounterCore/Package.swift", "Packages/DotCounterCore/README.md", "scripts/prepare-public-tree.py")
EXTENSIONS = {".swift", ".md", ".txt", ".json", ".plist", ".xcprivacy", ".entitlements", ".ttf", ".png", ".jpg"}
REQUIRED = ("DotCounter/Resources/PrivacyInfo.xcprivacy", "DotCounter/Resources/Fonts/OFL-IBM-Plex-Sans.txt",
            "DotCounter/Resources/Fonts/OFL-IBM-Plex-Mono.txt")
PRIVATE_PATTERNS = (r"https?://[^\s\"<>]*\.ts\.net", r"/" + r"Users/[^/\s]+/")
PUBLIC_IGNORE = ".DS_Store\n/build*/\nPackages/*/.build/\nPackages/*/.swiftpm/\n**/xcuserdata/\n*.xcresult/\n*.xcarchive/\n*.app/\n*.dSYM/\n__pycache__/\n*.py[cod]\n.env\n.env.*\n*.p8\n*.p12\n*.mobileprovision\n*.provisionprofile\nDotCounter.xcodeproj/\n"

def sha(path):
    value = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--destination", type=Path, required=True)
    args = parser.parse_args()
    source, destination = args.source.resolve(), args.destination.resolve()
    manifest_path = destination.with_name(destination.name + ".manifest.json")
    if destination.exists():
        parser.error("destination already exists; choose a new review snapshot (nothing was removed)")
    if manifest_path.exists():
        parser.error("destination manifest already exists; choose a new review snapshot (nothing was removed)")
    if destination == source or source in destination.parents and (destination.parent != source or not destination.name.startswith("build-public-tree")):
        parser.error("inside-checkout destination must be named build-public-tree* so it remains ignored")
    selected = {}
    for name in ROOT_FILES + EXACT_FILES:
        selected[name] = source / name
    for directory in SOURCE_DIRS + RESOURCE_DIRS:
        base = source / directory
        if not base.is_dir():
            parser.error(f"required allowlisted directory missing: {directory}")
        for path in sorted(base.rglob("*")):
            if path.is_symlink():
                parser.error(f"symlinks are not allowed: {path.relative_to(source)}")
            if path.is_file() and path.name != ".DS_Store":
                if path.suffix not in EXTENSIONS:
                    parser.error(f"unreviewed extension: {path.relative_to(source)}")
                selected[path.relative_to(source).as_posix()] = path
    for name in REQUIRED:
        if name not in selected:
            parser.error(f"required public resource missing: {name}")
    records, payloads, transforms = [], {}, []
    for relative, path in sorted(selected.items()):
        if not path.is_file() or path.resolve() != path:
            parser.error(f"required allowlisted file missing or symlink: {relative}")
        data = path.read_bytes()
        source_sha = hashlib.sha256(data).hexdigest()
        if relative == "project.yml":
            # Historical private signing defaults are not part of a public build recipe.
            text = data.decode("utf-8")
            lines = text.splitlines(keepends=True)
            filtered = [line for line in lines if not re.search(r"'(?:DEVELOPMENT_TEAM|PROVISIONING_PROFILE_SPECIFIER|CODE_SIGN_IDENTITY|CODE_SIGN_STYLE)\[sdk=iphoneos\*\]'", line)]
            if filtered != lines:
                transforms.append({"path": relative, "operation": "remove historical iphoneos signing team/profile/identity/style defaults; caller supplies signing separately"})
            data = "".join(filtered).encode()
        if path.suffix not in {".ttf", ".png", ".jpg"}:
            text = data.decode("utf-8")
            for pattern in PRIVATE_PATTERNS:
                if re.search(pattern, text):
                    parser.error(f"private metadata pattern {pattern!r} in {relative}; review source rather than silently replacing it")
        payloads[relative] = data
        records.append({"path": relative, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest(),
                        "source_path": path.relative_to(source).as_posix(), "source_sha256": source_sha})
    for record in records:
        if sha(source / record["source_path"]) != record["source_sha256"]:
            parser.error(f"source changed during snapshot: {record['source_path']}; retry after edits finish")
    ignore_data = PUBLIC_IGNORE.encode()
    payloads[".gitignore"] = ignore_data
    records.append({"path": ".gitignore", "bytes": len(ignore_data), "sha256": hashlib.sha256(ignore_data).hexdigest(),
                    "source_path": None, "source_sha256": None})
    records.sort(key=lambda record: record["path"])
    tree_records = [{key: record[key] for key in ("path", "bytes", "sha256")} for record in records]
    tree_sha = hashlib.sha256(json.dumps(tree_records, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    try:
        head = subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True, stderr=subprocess.DEVNULL).strip()
        tracked = subprocess.check_output(["git", "-C", str(source), "ls-files", "-z"], stderr=subprocess.DEVNULL).decode().split("\0")
    except subprocess.CalledProcessError:
        head, tracked = None, []
    manifest = {"format": 1, "scope": "local allowlisted working-tree snapshot; no Git history, publication or release acceptance",
                "source_head": head, "tree_sha256": tree_sha, "file_count": len(records),
                "bytes": sum(record["bytes"] for record in records), "transformations": transforms,
                "excluded_tracked_paths": sorted(path for path in tracked if path and path not in {r["source_path"] for r in records}), "files": records}
    destination.mkdir(parents=True)
    for relative, data in payloads.items():
        path = destination / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps({"destination": str(destination), "manifest": str(manifest_path), "tree_sha256": tree_sha,
                      "file_count": len(records), "bytes": manifest["bytes"], "signing_transforms": len(transforms)}, indent=2))

if __name__ == "__main__":
    main()
