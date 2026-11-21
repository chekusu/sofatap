#!/usr/bin/env python3
"""Pinned Sparkle download, reviewed nested signing, and post-signing inventory."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request

CONFIG = Path(__file__).with_name("update-config.json")
FRAMEWORK = "Contents/Frameworks/Sparkle.framework"
CODE = {
    "Versions/B/Autoupdate": "org.sparkle-project.Sparkle.Autoupdate",
    "Versions/B/Updater.app": "org.sparkle-project.Sparkle.Updater",
    "Versions/B/XPCServices/Installer.xpc": "org.sparkle-project.InstallerLauncher",
    "Versions/B/XPCServices/Downloader.xpc": "org.sparkle-project.DownloaderService",
    ".": "org.sparkle-project.Sparkle",
}
NATIVE = {
    "Versions/B/Autoupdate", "Versions/B/Sparkle",
    "Versions/B/Updater.app/Contents/MacOS/Updater",
    "Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer",
    "Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader",
}


def digest(path):
    sha = hashlib.sha256()
    with Path(path).open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            sha.update(block)
    return sha.hexdigest()


def inventory(framework):
    framework = Path(framework).resolve()
    result = {}
    for path in sorted(framework.rglob("*")):
        name = str(path.relative_to(framework))
        if path.is_symlink():
            target = os.readlink(path)
            if Path(target).is_absolute() or not path.resolve().is_relative_to(framework):
                raise ValueError("Sparkle link escapes its framework")
            if not path.exists():
                raise ValueError("Dangling Sparkle link")
            result[name] = {"symlink": target}
        elif path.is_file():
            result[name] = {"sha256": digest(path)}
    return result


def links(root):
    root = Path(root)
    return {str(p.relative_to(root)): os.readlink(p) for p in sorted(root.rglob("*")) if p.is_symlink()}


def cached(destination, config):
    """True only when the cache matches the pinned archive file for file and link for link."""
    try:
        receipt = json.loads((destination / "SOFATAP-DEPENDENCY.json").read_text())
        if receipt.get("archiveSHA256") != config["sparkleArchiveSHA256"] or "links" not in receipt:
            return False
        # Check code/tools before executing the cached release tooling.
        for name, expected in receipt["files"].items():
            path = destination / name
            if path.is_symlink() or digest(path) != expected:
                return False
        if links(destination) != receipt["links"]:
            return False
        inventory(destination / "Sparkle.framework")
        return True
    except (OSError, ValueError, KeyError, RuntimeError):
        return False


def fetch(destination):
    config = json.loads(CONFIG.read_text())
    destination = Path(destination).resolve()
    destination.parent.mkdir(parents=True, exist_ok=True)
    with (destination.parent / (destination.name + ".lock")).open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if destination.exists() or destination.is_symlink():
            if cached(destination, config):
                return destination
            # A persistent runner or an interrupted copy can leave a cache whose links
            # loop or whose files changed. Never use it; replace it with a fresh,
            # SHA-256 verified download.
            if destination.is_symlink() or not destination.is_dir():
                destination.unlink()
            else:
                shutil.rmtree(destination)
        with tempfile.TemporaryDirectory(dir=destination.parent, prefix="sparkle-") as temporary:
            temporary = Path(temporary)
            archive = temporary / "sparkle.tar.xz"
            with urllib.request.urlopen(config["sparkleArchiveURL"], timeout=60) as response, archive.open("wb") as output:
                shutil.copyfileobj(response, output)
            if digest(archive) != config["sparkleArchiveSHA256"]:
                raise ValueError("Sparkle archive failed SHA-256 verification")
            unpacked = temporary / "unpacked"
            unpacked.mkdir()
            with tarfile.open(archive) as source:
                for member in source.getmembers():
                    target = unpacked / member.name
                    if not target.resolve().is_relative_to(unpacked) or member.islnk() or member.isdev():
                        raise ValueError("Unsafe dependency archive member")
                    if member.issym() and (Path(member.linkname).is_absolute()
                            or not (target.parent / member.linkname).resolve().is_relative_to(unpacked)):
                        raise ValueError("Unsafe dependency symlink")
                source.extractall(unpacked, filter="data")
            inventory(unpacked / "Sparkle.framework")
            files = {str(p.relative_to(unpacked)): digest(p) for p in unpacked.rglob("*") if p.is_file() and not p.is_symlink()}
            (unpacked / "SOFATAP-DEPENDENCY.json").write_text(json.dumps({
                "version": config["sparkleVersion"], "archiveSHA256": config["sparkleArchiveSHA256"], "files": files,
                "links": links(unpacked),
            }, indent=2) + "\n")
            os.replace(unpacked, destination)
    return destination


def sign(app, identity):
    framework = Path(app) / FRAMEWORK
    inventory(framework)
    flags = ["codesign", "--force", "--sign", identity, "--options", "runtime"]
    if identity != "-":
        flags += ["--timestamp"]
    for relative, identifier in CODE.items():
        subprocess.run([*flags, "--identifier", identifier, str(framework / relative)], check=True)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(framework)], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    get = sub.add_parser("fetch"); get.add_argument("destination", type=Path)
    signing = sub.add_parser("sign"); signing.add_argument("app", type=Path); signing.add_argument("identity")
    listing = sub.add_parser("inventory"); listing.add_argument("framework", type=Path)
    args = parser.parse_args()
    if args.command == "fetch": print(fetch(args.destination))
    elif args.command == "sign": sign(args.app, args.identity)
    else: print(json.dumps(inventory(args.framework), indent=2))


if __name__ == "__main__":
    main()
