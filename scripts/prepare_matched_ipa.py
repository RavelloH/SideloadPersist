#!/usr/bin/env python3
"""Patch an UNSIGNED iOS IPA's CFBundleIdentifier before code-signing.

Purpose: compare behavior of a side-loaded app with matching or mismatching
Info.plist CFBundleIdentifier and signed application-identifier entitlement.

Usage:
    python scripts/prepare_matched_ipa.py INPUT.ipa OUTPUT.ipa app.example.id

The input must be UNSIGNED. Never modify a signed package without re-signing.
No certificate or provisioning profile is read or modified.
"""
import argparse
import io
import plistlib
import re
import sys
import zipfile
from pathlib import Path

BUNDLE_RE = re.compile(r"^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    parser.add_argument("bundle_id", help="app identifier suffix after the first dot of the signed application-identifier")
    args = parser.parse_args()
    if not BUNDLE_RE.fullmatch(args.bundle_id):
        parser.error("Invalid bundle identifier (must be dotted alphanumeric/hyphen segments)")
    if args.source.resolve() == args.destination.resolve():
        parser.error("Destination must differ from source")
    if args.destination.exists():
        parser.error("Refusing to overwrite an existing destination")

    result = io.BytesIO()
    found = []
    with zipfile.ZipFile(args.source, "r") as inp:
        infos = inp.infolist()
        for info in infos:
            if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", info.filename):
                found.append(info.filename)
        if len(found) != 1:
            parser.error(f"Expected 1 top-level app Info.plist, found {len(found)}")
        target = found[0]
        with zipfile.ZipFile(result, "w") as out:
            for info in infos:
                name = info.filename
                if "/_CodeSignature/" in name or name.endswith("/embedded.mobileprovision"):
                    raise ValueError("Input appears signed; supply the unsigned build artifact instead")
                content = inp.read(name)
                if name == target:
                    data = plistlib.loads(content)
                    previous = data.get("CFBundleIdentifier")
                    if not previous:
                        raise ValueError("Missing CFBundleIdentifier")
                    data["CFBundleIdentifier"] = args.bundle_id
                    content = plistlib.dumps(data, fmt=plistlib.FMT_XML, sort_keys=False)
                    print(f"Bundle identifier: {previous} -> {args.bundle_id}")
                out.writestr(info, content)

    args.destination.parent.mkdir(parents=True, exist_ok=True)
    args.destination.write_bytes(result.getvalue())
    with zipfile.ZipFile(args.destination) as output:
        actual = plistlib.loads(output.read(target))["CFBundleIdentifier"]
        assert actual == args.bundle_id
        print(f"Validated: {args.destination} ({args.destination.stat().st_size} bytes)")
        print("IMPORTANT: Sign this IPA normally. Confirm runtime 'signedBundle' and 'plistBundle' MATCH after signing.")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, zipfile.BadZipFile) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(1)
