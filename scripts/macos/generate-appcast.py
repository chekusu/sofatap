#!/usr/bin/env python3
"""Prepare a signed architecture-specific feed from a verified notarized ZIP.

Does not upload, publish, install, or change the user's installed application.
Publish the ZIP first, verify its public bytes, then commit the generated feed.
"""
import argparse
import base64
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET
import zipfile

from sparkle import CONFIG, digest, fetch

SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"


def public_key_from_file(path):
    """Public half of a Sparkle private key file, so CI can check it before signing anything.

    Sparkle exports either a 32-byte seed (generate_keys -x) or the legacy 96-byte form (64-byte secret key followed
    by the public key); libsodium's 64-byte secret key also ends with the public key.
    """
    raw = base64.b64decode(Path(path).read_text().strip(), validate=True)
    if len(raw) in (64, 96):
        return base64.b64encode(raw[-32:]).decode()
    if len(raw) != 32:
        raise ValueError("Sparkle key file must hold a base64 Ed25519 key")
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
    return base64.b64encode(Ed25519PrivateKey.from_private_bytes(raw).public_key().public_bytes_raw()).decode()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", required=True, type=Path)
    parser.add_argument("--receipt", required=True, type=Path, help="Completed notarize-macos.sh receipt")
    parser.add_argument("--architecture", choices=["arm64", "x64"], required=True)
    parser.add_argument("--tag", required=True, help="Desktop GitHub release tag, e.g. v0.8.0-beta.1")
    parser.add_argument("--output-dir", required=True, type=Path, help="A new, caller-owned staging directory")
    parser.add_argument("--previous-feed", type=Path, help="Current published feed for this architecture")
    args = parser.parse_args()
    config = json.loads(CONFIG.read_text())
    if not re.fullmatch(r"v\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?", args.tag):
        raise ValueError("Expected a desktop semantic-version tag")
    archive = args.archive.resolve()
    receipt = json.loads(args.receipt.read_text())
    if not (receipt.get("stage") == "complete" and receipt.get("notarized") is True
            and receipt.get("stapled") is True and receipt.get("gatekeeperAccepted") is True
            and receipt.get("runtime") == "osx-" + args.architecture
            and receipt.get("finalArchive") == archive.name
            and receipt.get("finalZIP_SHA256") == digest(archive)):
        raise ValueError("Archive must match a completed notarization/staple/Gatekeeper receipt")
    with zipfile.ZipFile(archive) as bundle:
        candidates = [name for name in bundle.namelist() if name.endswith(".app/Contents/Info.plist")
                      and "Sparkle.framework/" not in name and "__MACOSX/" not in name]
        if len(candidates) != 1:
            raise ValueError("Update must contain one receiver app")
        info = plistlib.loads(bundle.read(candidates[0]))
    expected_feed = config["feedBaseURL"] + "/" + args.architecture + "/appcast.xml"
    if not (info.get("CFBundleIdentifier") == "com.chekusu.sofatap.receiver"
            and info.get("SUPublicEDKey") == config["publicEdKey"]
            and info.get("SUFeedURL") == expected_feed
            and info.get("SURequireSignedFeed") is True
            and info.get("SUVerifyUpdateBeforeExtraction") is True
            and info.get("SUSignedFeedFailureExpirationInterval") == 0
            and re.fullmatch(r"[1-9][0-9]*", info.get("CFBundleVersion", ""))
            and args.tag[1:].split("-")[0] == info.get("CFBundleShortVersionString")
            and args.tag[1:] == info.get("SofatapReleaseVersion")):
        raise ValueError("Archive version, feed, or signature policy differs from release configuration")
    root = CONFIG.parents[2]
    dependency = fetch(root / ".tools" / ("Sparkle-" + config["sparkleVersion"]))
    # The release workflow passes the key as a 0600 file outside the repository (SOFATAP_SPARKLE_KEY_FILE); the
    # publishing Mac keeps it in its Keychain account instead.
    key_file = os.environ.get("SOFATAP_SPARKLE_KEY_FILE")
    if key_file:
        key = ["--ed-key-file", key_file]
        public_key = public_key_from_file(key_file)
    else:
        key = ["--account", config["keychainAccount"]]
        public_key = subprocess.check_output([str(dependency / "bin/generate_keys"), *key, "-p"], text=True).strip()
    if public_key != config["publicEdKey"]:
        raise ValueError("Release signing key does not match embedded public key")
    if args.output_dir.exists():
        raise ValueError("Choose a new staging output directory; previous feeds are never edited in place")
    with tempfile.TemporaryDirectory(prefix="sofatap-appcast-") as temporary:
        stage = Path(temporary)
        shutil.copyfile(archive, stage / archive.name)
        if args.previous_feed:
            subprocess.run([str(dependency / "bin/sign_update"), *key, "--verify", str(args.previous_feed)], check=True)
            previous = ET.parse(args.previous_feed)
            versions = [int(e.text) for e in previous.iter(SPARKLE + "version") if e.text and e.text.isdigit()]
            if versions and max(versions) >= int(info["CFBundleVersion"]):
                raise ValueError("Build number must increase beyond every previously published build")
            for item in previous.iter("enclosure"):
                if not item.get("url", "").startswith(config["releaseURLPrefix"]) or ("macOS-" + args.architecture + "-") not in item.get("url", ""):
                    raise ValueError("Previous feed contains an unexpected release or architecture")
            shutil.copyfile(args.previous_feed, stage / "appcast.xml")
        prefix = config["releaseURLPrefix"] + args.tag + "/"
        subprocess.run([str(dependency / "bin/generate_appcast"), *key,
                        "--maximum-deltas", "0", "--maximum-versions", "3",
                        "--download-url-prefix", prefix, "--link", "https://sofatap.app",
                        "--versions", info["CFBundleVersion"],
                        *(["--channel", "beta"] if "-" in args.tag else []), str(stage)], check=True)
        feed = stage / "appcast.xml"
        subprocess.run([str(dependency / "bin/sign_update"), *key, "--verify", str(feed)], check=True)
        xml = ET.parse(feed)
        candidates = [item for item in xml.iter("item") if item.findtext(SPARKLE + "version") == info["CFBundleVersion"]]
        if len(candidates) != 1:
            raise ValueError("Generated feed did not contain the exact new build")
        expected_channel = "beta" if "-" in args.tag else None
        if candidates[0].findtext(SPARKLE + "channel") != expected_channel:
            raise ValueError("Generated feed has an unexpected release channel")
        enclosure = candidates[0].find("enclosure")
        signature = enclosure.get(SPARKLE + "edSignature", "") if enclosure is not None else ""
        if enclosure is None or enclosure.get("url") != prefix + archive.name or int(enclosure.get("length", "0")) != archive.stat().st_size or len(base64.b64decode(signature, validate=True)) != 64:
            raise ValueError("Generated update enclosure does not match the notarized archive")
        subprocess.run([str(dependency / "bin/sign_update"), *key, "--verify", str(archive), signature], check=True)
        args.output_dir.mkdir(parents=True)
        shutil.copyfile(feed, args.output_dir / "appcast.xml")
        (args.output_dir / "APPCAST-RECEIPT.json").write_text(json.dumps({
            "published": False, "architecture": args.architecture, "version": info["CFBundleShortVersionString"],
            "build": info["CFBundleVersion"], "feedURL": expected_feed, "archiveURL": prefix + archive.name,
            "archiveSHA256": digest(archive), "feedSHA256": digest(feed), "signatureVerified": True,
            "requiredPublicationStep": "Upload the exact notarized ZIP, verify its anonymous public download hash, then commit this exact signed appcast without modification."
        }, indent=2) + "\n")
    print(args.output_dir / "appcast.xml")


if __name__ == "__main__":
    main()
