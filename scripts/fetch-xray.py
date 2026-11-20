#!/usr/bin/env python3
"""Fetch the pinned macOS core only. Never install or start a tunnel."""
import hashlib
import plistlib
from pathlib import Path
import shutil
import urllib.request
import zipfile
import sys

ROOT = Path(__file__).resolve().parent.parent
VERSION = "v26.11.9"
DIGEST = "7c58346709f1856782a48d8f9926fb815c8ad1bbaf9e5d9dec4ee0cd1f41ed6f"
SIZE = 102_548_590
PREFIX = "libxray-apple-cgo/LibXray.xcframework/"
VENDOR = ROOT / "Vendor"
VENDOR.mkdir(exist_ok=True)
ARCHIVE = VENDOR / "libxray-apple-cgo.zip"
OUTPUT = VENDOR / "LibXray.xcframework"
MAC_HASHES = {
    "macos-arm64_x86_64/libXray.a": "45cb0779449eab82a57de6452b5a6ec8a6d216f6d8d86b8e2f730ea6a590caf9",
    "macos-arm64_x86_64/Headers/libXray.h": "9d1374d9570ab21bc658efe638dc39eab9e424660d28669e009b8b87821db27c",
    "macos-arm64_x86_64/Headers/module.modulemap": "2352d2fa3aa2107d06f3e52e6566df9e5bb09d7fd4363cfdc24c5ef3768e7d46",
}

def cached_core_matches():
    try:
        for name, digest in MAC_HASHES.items():
            with (OUTPUT / name).open("rb") as file:
                if hashlib.file_digest(file, "sha256").hexdigest() != digest:
                    return False
        info = plistlib.loads((OUTPUT / "Info.plist").read_bytes())
        return len(info["AvailableLibraries"]) == 1 and info["AvailableLibraries"][0]["SupportedPlatform"] == "macos"
    except (OSError, ValueError, KeyError):
        return False

if cached_core_matches():
    print(f"Pinned libXray {VERSION} is already verified")
    sys.exit(0)

if not ARCHIVE.exists():
    request = urllib.request.Request(
        f"https://github.com/XTLS/libXray/releases/download/{VERSION}/libxray-apple-cgo.zip",
        headers={"User-Agent": "VibeMonitoring-build"},
    )
    temporary = ARCHIVE.with_suffix(".partial")
    try:
        with urllib.request.urlopen(request, timeout=60) as response, temporary.open("wb") as file:
            total = 0
            while block := response.read(256 * 1024):
                total += len(block)
                if total > SIZE:
                    raise RuntimeError("Core archive exceeds pinned size")
                file.write(block)
        temporary.replace(ARCHIVE)
    finally:
        temporary.unlink(missing_ok=True)

with ARCHIVE.open("rb") as file:
    actual = hashlib.file_digest(file, "sha256").hexdigest()
if ARCHIVE.stat().st_size != SIZE or actual != DIGEST:
    raise RuntimeError("Core archive does not match the pinned SHA-256/size")

stage = VENDOR / ".LibXray-stage"
shutil.rmtree(stage, ignore_errors=True)
stage.mkdir()
try:
    with zipfile.ZipFile(ARCHIVE) as archive:
        info = plistlib.loads(archive.read(PREFIX + "Info.plist"))
        libraries = [item for item in info["AvailableLibraries"] if item["SupportedPlatform"] == "macos"]
        if len(libraries) != 1:
            raise RuntimeError("Expected one universal macOS library")
        identifier = libraries[0]["LibraryIdentifier"]
        for member in archive.infolist():
            if not member.filename.startswith(PREFIX + identifier + "/"):
                continue
            relative = Path(member.filename.removeprefix(PREFIX))
            if relative.is_absolute() or ".." in relative.parts or member.file_size > 100_000_000:
                raise RuntimeError("Unsafe core archive member")
            destination = stage / relative
            if member.is_dir():
                destination.mkdir(parents=True, exist_ok=True)
            else:
                destination.parent.mkdir(parents=True, exist_ok=True)
                with archive.open(member) as source, destination.open("wb") as target:
                    shutil.copyfileobj(source, target)
        info["AvailableLibraries"] = libraries
        (stage / "Info.plist").write_bytes(plistlib.dumps(info))
    shutil.rmtree(OUTPUT, ignore_errors=True)
    stage.replace(OUTPUT)
finally:
    shutil.rmtree(stage, ignore_errors=True)
ARCHIVE.unlink()
print(f"Verified libXray {VERSION}; retained only the macOS slice at {OUTPUT}")
