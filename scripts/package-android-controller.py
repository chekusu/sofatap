#!/usr/bin/env python3
"""Sign a prebuilt Android controller release APK with its persistent private identity.

Initialization and packaging are separate operations. This script never builds,
publishes, uploads, replaces an existing output, or repairs a missing signing key.
"""

import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import stat
import struct
import subprocess
import sys
import tempfile
import zipfile


APPLICATION_ID = "com.chekusu.sofatap"
KEY_ALIAS = "sofatap-android-controller"
KEY_DIRECTORY = Path.home() / "Library/Application Support/Chekusu/Sofatap/signing/android-controller"
KEY_NAME = "controller-release.p12"
PASSWORD_NAME = "keystore-password"
IDENTITY_NAME = "identity.json"


class ReleaseError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise ReleaseError(message)


def run(command, *, cwd=None, environment=None):
    # Never echo a command or subprocess diagnostics: signing tools may include
    # private paths and credential details in errors. Passwords are file arguments.
    result = subprocess.run([str(value) for value in command], cwd=cwd, env=environment,
                            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, check=False)
    require(result.returncode == 0, f"{Path(command[0]).name} failed (exit {result.returncode}); no output published.")
    return result.stdout


def digest(file):
    hasher = hashlib.sha256()
    with file.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            hasher.update(block)
    return hasher.hexdigest()


def exclusive_write(file, data, mode=0o600):
    descriptor = os.open(file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
    with os.fdopen(descriptor, "wb") as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())


def json_bytes(value):
    return (json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode("utf-8")


def sync_directory(directory):
    descriptor = os.open(directory, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def private_path(file, directory=False):
    metadata = file.lstat()
    expected_kind = stat.S_ISDIR if directory else stat.S_ISREG
    require(expected_kind(metadata.st_mode) and metadata.st_uid == os.getuid(), "Signing material must be owned by this user and cannot be a symlink.")
    require(stat.S_IMODE(metadata.st_mode) == (0o700 if directory else 0o600), "Signing material has unsafe permissions; refusing to use or change it.")


def prepare_key_directory(initialize):
    # The fixed identity location must not be redirected through a symlink.
    current = Path.home()
    for segment in KEY_DIRECTORY.relative_to(current).parts:
        current = current / segment
        if current.exists() or current.is_symlink():
            require(not current.is_symlink() and current.is_dir(), "Signing directory cannot contain symlinks or non-directories.")
        elif initialize:
            current.mkdir(mode=0o700)
        else:
            raise ReleaseError("Controller signing key is missing. Use --init-key only for the first release identity.")
    private_path(KEY_DIRECTORY, directory=True)


@contextmanager
def signing_lock():
    file = KEY_DIRECTORY / ".signing.lock"
    try:
        exclusive_write(file, str(os.getpid()).encode("ascii"))
    except FileExistsError:
        raise ReleaseError("Another signing operation or an interrupted lock exists; refusing concurrent signing.") from None
    try:
        yield
    finally:
        file.unlink()


def java_tools(java_home):
    configured = java_home or os.environ.get("JAVA_HOME")
    keytool = Path(configured) / "bin/keytool" if configured else Path(shutil.which("keytool") or "/missing/keytool")
    require(keytool.is_file() and os.access(keytool, os.X_OK), "Provide a working JDK with --java-home or JAVA_HOME.")
    environment = dict(os.environ)
    if configured:
        environment["JAVA_HOME"] = str(Path(configured).resolve())
        environment["PATH"] = str(Path(configured) / "bin") + os.pathsep + environment.get("PATH", "")
    run([keytool, "-help"], environment=environment)
    return keytool, environment


def certificate_digest(keytool, key, password, environment):
    encoded = run([keytool, "-exportcert", "-keystore", key, "-storetype", "PKCS12",
                   "-alias", KEY_ALIAS, "-storepass:file", password], environment=environment)
    require(bool(encoded), "Signing certificate could not be read.")
    return hashlib.sha256(encoded).hexdigest()


def initialize_key(keytool, environment):
    prepare_key_directory(True)
    with signing_lock():
        require(not any((KEY_DIRECTORY / name).exists() or (KEY_DIRECTORY / name).is_symlink()
                        for name in (KEY_NAME, PASSWORD_NAME, IDENTITY_NAME)),
                "Signing identity already exists or is incomplete; it will never be overwritten or regenerated.")
        require(not list(KEY_DIRECTORY.glob(".initializing-*")), "An interrupted key initialization exists; preserve and recover it before continuing.")
        staging = Path(tempfile.mkdtemp(prefix=".initializing-", dir=KEY_DIRECTORY))
        staging.chmod(0o700)
        password = staging / PASSWORD_NAME
        key = staging / KEY_NAME
        exclusive_write(password, secrets.token_urlsafe(48).encode("ascii") + b"\n")
        # Preserve staging on failure: silently generating a replacement could
        # strand installed users on an unrecoverable update identity.
        run([keytool, "-genkeypair", "-noprompt", "-keystore", key, "-storetype", "PKCS12",
             "-alias", KEY_ALIAS, "-keyalg", "RSA", "-keysize", "3072", "-sigalg", "SHA256withRSA",
             "-validity", "10000", "-dname", "CN=Sofatap Android Controller, O=Chekusu Inc., C=JP",
             "-storepass:file", password, "-keypass:file", password], environment=environment)
        key.chmod(0o600)
        with key.open("rb") as stream:
            os.fsync(stream.fileno())
        fingerprint = certificate_digest(keytool, key, password, environment)
        identity = {"schema": 1, "applicationId": APPLICATION_ID, "alias": KEY_ALIAS,
                    "certificateSha256": fingerprint, "keyAlgorithm": "RSA", "keySize": 3072,
                    "createdAt": datetime.now(timezone.utc).isoformat()}
        exclusive_write(staging / IDENTITY_NAME, json_bytes(identity))
        for name in (KEY_NAME, PASSWORD_NAME, IDENTITY_NAME):
            os.link(staging / name, KEY_DIRECTORY / name)  # Atomic, refuses replacement.
            (staging / name).unlink()
        staging.rmdir()
        sync_directory(KEY_DIRECTORY)
    print("Created the persistent Android controller signing identity. No APK was signed.")


def signing_identity(keytool, environment):
    for name in (KEY_NAME, PASSWORD_NAME, IDENTITY_NAME):
        require((KEY_DIRECTORY / name).exists(), "Signing identity is missing or incomplete; refusing to regenerate it.")
        private_path(KEY_DIRECTORY / name)
    identity = json.loads((KEY_DIRECTORY / IDENTITY_NAME).read_text(encoding="utf-8"))
    require(identity.get("schema") == 1 and identity.get("applicationId") == APPLICATION_ID
            and identity.get("alias") == KEY_ALIAS and identity.get("keyAlgorithm") == "RSA"
            and identity.get("keySize") == 3072, "Unexpected controller signing identity.")
    fingerprint = certificate_digest(keytool, KEY_DIRECTORY / KEY_NAME, KEY_DIRECTORY / PASSWORD_NAME, environment)
    require(fingerprint == identity.get("certificateSha256"), "Signing certificate no longer matches the persistent identity.")
    return fingerprint


def verified_commit(root, expected):
    require(re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", expected) is not None, "--source-commit must be the complete lowercase Git commit SHA.")
    actual = run(["git", "rev-parse", "HEAD"], cwd=root).decode().strip()
    require(actual == expected, "Source HEAD does not match --source-commit.")
    require(not run(["git", "status", "--porcelain=v1", "--untracked-files=all"], cwd=root).strip(),
            "Release signing requires a clean Git tree, including untracked source files.")
    return actual


def gradle_metadata(source):
    keys = {"applicationId": r"applicationId\s+['\"]([^'\"]+)['\"]",
            "versionName": r"versionName\s+['\"]([^'\"]+)['\"]",
            "versionCode": r"versionCode\s+(\d+)\b", "minSdk": r"minSdk\s+(\d+)\b",
            "targetSdk": r"targetSdk\s+(\d+)\b"}
    result = {}
    for key, pattern in keys.items():
        matches = re.findall(pattern, source)
        require(len(matches) == 1, "Controller Gradle version metadata is missing or ambiguous.")
        result[key] = int(matches[0]) if key in {"versionCode", "minSdk", "targetSdk"} else matches[0]
    require(result["applicationId"] == APPLICATION_ID and result["versionCode"] > 0 and result["minSdk"] >= 26,
            "Unexpected controller release package or SDK metadata.")
    require(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.+_-]{0,79}", result["versionName"]) is not None,
            "Release version is not safe for an artifact filename.")
    return result


def verify_badging(text, expected):
    package = re.search(r"^package: name='([^']+)' versionCode='(\d+)' versionName='([^']*)'", text, re.MULTILINE)
    minimum = re.search(r"^sdkVersion:'(\d+)'$", text, re.MULTILINE)
    target = re.search(r"^targetSdkVersion:'(\d+)'$", text, re.MULTILINE)
    require(package is not None and minimum is not None and target is not None, "APK manifest metadata could not be verified.")
    actual = {"applicationId": package[1], "versionCode": int(package[2]), "versionName": package[3],
              "minSdk": int(minimum[1]), "targetSdk": int(target[1])}
    require(actual == expected, "APK package, version, or SDK does not match committed release source.")
    require(re.search(r"^application-debuggable\b", text, re.MULTILINE) is None, "Refusing to publish a debuggable APK.")


def require_unsigned(apk):
    with zipfile.ZipFile(apk) as archive:
        require(not any(re.fullmatch(r"META-INF/[^/]+\.(RSA|DSA|EC|SF)", name, re.IGNORECASE) for name in archive.namelist()),
                "Input APK already contains a signing identity; provide the unsigned release APK.")
    # APK v2/v3 signatures live before the ZIP central directory, outside entries.
    with apk.open("rb") as stream:
        size = apk.stat().st_size
        stream.seek(max(0, size - 65557))
        tail = stream.read()
        end = tail.rfind(b"PK\x05\x06")
        require(end >= 0 and len(tail) == end + 22 and struct.unpack_from("<H", tail, end + 20)[0] == 0,
                "APK ZIP footer is invalid or contains an unexpected archive comment.")
        central = struct.unpack_from("<I", tail, end + 16)[0]
        central_size = struct.unpack_from("<I", tail, end + 12)[0]
        require(central != 0xffffffff and central + central_size == size - 22, "Unsupported APK ZIP layout.")
        if central >= 24:
            stream.seek(central - 16)
            require(stream.read(16) != b"APK Sig Block 42", "Input APK is already signed; refusing to replace its identity.")


def sdk_tools(configured):
    candidates = [configured, os.environ.get("ANDROID_HOME"), os.environ.get("ANDROID_SDK_ROOT"),
                  Path.home() / "Library/Android/sdk", Path.home() / "Library/Caches/SofatapBuild/android-sdk"]
    sdk = next((Path(value).expanduser().resolve() for value in candidates if value and (Path(value).expanduser() / "build-tools").is_dir()), None)
    require(sdk is not None, "Provide an Android SDK with --android-sdk or ANDROID_HOME.")
    versions = [directory for directory in (sdk / "build-tools").iterdir()
                if directory.is_dir() and re.fullmatch(r"\d+\.\d+\.\d+", directory.name)]
    require(bool(versions), "No stable Android build-tools installation is available.")
    selected = max(versions, key=lambda item: tuple(map(int, item.name.split("."))))
    for name in ("aapt", "apksigner", "zipalign"):
        require((selected / name).is_file() and os.access(selected / name, os.X_OK), "Android build-tools installation is incomplete.")
    return selected


def sign_apk(tools, aligned, signed, environment):
    # This PKCS12 identity uses the same store and key password. apksigner reads
    # repeated file: sources one line at a time, so providing the same single-line
    # file for --key-pass would consume EOF. Omit it to reuse the store password.
    # run() closes stdin so an unexpected key mismatch fails without prompting.
    password = "file:" + str(KEY_DIRECTORY / PASSWORD_NAME)
    run([tools / "apksigner", "sign", "--ks", KEY_DIRECTORY / KEY_NAME,
         "--ks-type", "PKCS12", "--ks-key-alias", KEY_ALIAS, "--ks-pass", password,
         "--v1-signing-enabled", "true", "--v2-signing-enabled", "true",
         "--v3-signing-enabled", "true", "--v4-signing-enabled", "false",
         "--out", signed, aligned], environment=environment)


def package(args, keytool, environment):
    root = Path(__file__).resolve().parent.parent
    source = verified_commit(root, args.source_commit)
    expected = gradle_metadata((root / "android/controller/build.gradle").read_text(encoding="utf-8"))
    apk = args.input_apk.expanduser().resolve(strict=True)
    require(apk.is_file() and 0 < apk.stat().st_size < 1024 * 1024 * 1024, "Input must be a regular APK smaller than 1 GiB.")
    output = args.output_dir.expanduser().absolute()
    require(not output.is_symlink(), "Output directory cannot be a symlink.")
    output = output.resolve()
    require(not output.is_relative_to(root), "Publish artifacts outside the source checkout to keep release provenance clean.")
    tools = sdk_tools(args.android_sdk)
    require_unsigned(apk)
    verify_badging(run([tools / "aapt", "dump", "badging", apk], environment=environment).decode("utf-8"), expected)
    prepare_key_directory(False)
    filename = f"Sofatap-Android-{expected['versionName']}.apk"
    receipt_name = f"Sofatap-Android-{expected['versionName']}.json"
    names = (filename, receipt_name, "SHA256SUMS")
    output.mkdir(parents=True, exist_ok=True)
    require(not any((output / name).exists() or (output / name).is_symlink() for name in names), "Release output already exists; refusing to overwrite it.")
    with signing_lock(), tempfile.TemporaryDirectory(prefix=".sofatap-sign-", dir=output) as temporary:
        fingerprint = signing_identity(keytool, environment)
        stage = Path(temporary)
        aligned, signed = stage / "aligned.apk", stage / filename
        input_hash = digest(apk)
        run([tools / "zipalign", "-P", "16", "4", apk, aligned], environment=environment)
        sign_apk(tools, aligned, signed, environment)
        verification = run([tools / "apksigner", "verify", "--verbose", "--print-certs", signed], environment=environment).decode("utf-8")
        signers = re.findall(r"^Signer #\d+ certificate SHA-256 digest: ([0-9a-fA-F]+)$", verification, re.MULTILINE)
        require(len(signers) == 1 and signers[0].lower() == fingerprint, "Signed APK does not match the persistent controller identity.")
        run([tools / "zipalign", "-c", "-P", "16", "4", signed], environment=environment)
        verify_badging(run([tools / "aapt", "dump", "badging", signed], environment=environment).decode("utf-8"), expected)
        require(digest(apk) == input_hash, "Input APK changed during signing.")
        verified_commit(root, source)
        signed_hash = digest(signed)
        receipt = {"schema": 1, "product": "Sofatap Android controller", "sourceCommit": source,
                   "sourceTreeClean": True, "sourceProvenance": "Verified clean HEAD; APK metadata matched committed build.gradle. No reproducible-build claim.",
                   "signedAt": datetime.now(timezone.utc).isoformat(), "apk": filename,
                   "sha256": signed_hash, "sizeBytes": signed.stat().st_size, "inputApkSha256": input_hash,
                   "certificateSha256": fingerprint, "debuggable": False, "buildTools": tools.name, **expected}
        exclusive_write(stage / receipt_name, json_bytes(receipt))
        sums = f"{signed_hash}  {filename}\n{digest(stage / receipt_name)}  {receipt_name}\n"
        exclusive_write(stage / "SHA256SUMS", sums.encode("ascii"))
        for name in names:
            (stage / name).chmod(0o644)
            os.link(stage / name, output / name)  # Refuses replacement even if another publisher raced us.
        sync_directory(output)
    print(json.dumps({"apk": str(output / filename), "receipt": str(output / receipt_name),
                      "checksums": str(output / "SHA256SUMS"), "sourceCommit": source,
                      "certificateSha256": fingerprint}, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--init-key", action="store_true", help="Create the identity once; does not sign an APK")
    parser.add_argument("--input-apk", type=Path, help="Existing unsigned controller release APK")
    parser.add_argument("--output-dir", type=Path, help="Artifact directory outside the checkout; outputs cannot exist")
    parser.add_argument("--source-commit", help="Exact full HEAD SHA, with a clean source tree")
    parser.add_argument("--android-sdk", type=Path)
    parser.add_argument("--java-home", type=Path)
    args = parser.parse_args()
    if args.init_key:
        require(not any((args.input_apk, args.output_dir, args.source_commit)), "--init-key is initialization only; sign separately afterwards.")
    else:
        require(all((args.input_apk, args.output_dir, args.source_commit)), "Signing requires --input-apk, --output-dir and --source-commit.")
    os.umask(0o077)
    keytool, environment = java_tools(args.java_home)
    if args.init_key:
        initialize_key(keytool, environment)
    else:
        package(args, keytool, environment)


if __name__ == "__main__":
    try:
        main()
    except ReleaseError as error:
        print(f"Release signing stopped: {error}", file=sys.stderr)
        sys.exit(1)
    except (OSError, ValueError, zipfile.BadZipFile):
        print("Release signing stopped: a file or tool could not be validated. Signing material was not regenerated.", file=sys.stderr)
        sys.exit(1)
