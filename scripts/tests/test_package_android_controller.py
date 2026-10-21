"""Release validation only. Never creates or uses a signing key."""

import importlib.util
import io
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import zipfile


SOURCE = Path(__file__).resolve().parents[1] / "package-android-controller.py"
SPEC = importlib.util.spec_from_file_location("android_package", SOURCE)
PACKAGE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PACKAGE)

GRADLE = """
applicationId 'com.chekusu.sofatap'
versionName '0.1.0-beta.1'
versionCode 2
minSdk 26
targetSdk 36
"""
BADGING = """package: name='com.chekusu.sofatap' versionCode='2' versionName='0.1.0-beta.1' platformBuildVersionName='16'
sdkVersion:'26'
targetSdkVersion:'36'
application: label='Sofatap' icon='res/icon.png'
"""


class PackageValidationTest(unittest.TestCase):
    def test_release_metadata_matches_and_debug_package_is_refused(self):
        expected = PACKAGE.gradle_metadata(GRADLE)
        PACKAGE.verify_badging(BADGING, expected)
        for changed in (BADGING.replace("com.chekusu.sofatap'", "com.chekusu.sofatap.dev'"),
                        BADGING.replace("versionCode='2'", "versionCode='1'"),
                        BADGING.replace("sdkVersion:'26'", "sdkVersion:'25'"),
                        BADGING + "application-debuggable\n"):
            with self.subTest(), self.assertRaises(PACKAGE.ReleaseError):
                PACKAGE.verify_badging(changed, expected)

    def test_ambiguous_or_unsafe_source_metadata_is_refused(self):
        for changed in (GRADLE + "versionCode 3\n", GRADLE.replace("0.1.0-beta.1", "../other"),
                        GRADLE.replace("com.chekusu.sofatap", "com.chekusu.receiver")):
            with self.subTest(), self.assertRaises(PACKAGE.ReleaseError):
                PACKAGE.gradle_metadata(changed)

    @staticmethod
    def zip_bytes(signature=None):
        result = io.BytesIO()
        with zipfile.ZipFile(result, "w") as archive:
            archive.writestr("AndroidManifest.xml", b"synthetic fixture")
            if signature:
                archive.writestr(signature, b"synthetic existing signature")
        return result.getvalue()

    def test_existing_v1_and_v2_signing_identities_are_refused(self):
        with tempfile.TemporaryDirectory() as temporary:
            apk = Path(temporary) / "input.apk"
            original = self.zip_bytes()
            apk.write_bytes(original)
            PACKAGE.require_unsigned(apk)
            apk.write_bytes(self.zip_bytes("META-INF/RELEASE.RSA"))
            with self.assertRaises(PACKAGE.ReleaseError):
                PACKAGE.require_unsigned(apk)
            end = original.rfind(b"PK\x05\x06")
            central = struct.unpack_from("<I", original, end + 16)[0]
            block = struct.pack("<Q", 24) + struct.pack("<Q", 24) + b"APK Sig Block 42"
            signed = bytearray(original[:central] + block + original[central:])
            struct.pack_into("<I", signed, end + len(block) + 16, central + len(block))
            apk.write_bytes(signed)
            with self.assertRaises(PACKAGE.ReleaseError):
                PACKAGE.require_unsigned(apk)
            with zipfile.ZipFile(apk, "a") as archive:
                archive.comment = b"PK\x05\x06" + bytes(18)
            with self.assertRaises(PACKAGE.ReleaseError):
                PACKAGE.require_unsigned(apk)

    def test_full_commit_and_clean_tree_are_required(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            def git(*arguments):
                return subprocess.check_output(["git", *arguments], cwd=root, stderr=subprocess.DEVNULL).decode().strip()
            git("init")
            (root / "source.txt").write_text("committed\n")
            git("add", "source.txt")
            git("-c", "user.name=Release Test", "-c", "user.email=release-test@example.invalid", "commit", "-m", "fixture")
            commit = git("rev-parse", "HEAD")
            self.assertEqual(commit, PACKAGE.verified_commit(root, commit))
            with self.assertRaises(PACKAGE.ReleaseError):
                PACKAGE.verified_commit(root, commit[:8])
            with self.assertRaises(PACKAGE.ReleaseError):
                PACKAGE.verified_commit(root, "0" * 40)
            (root / "untracked.txt").write_text("new source\n")
            with self.assertRaises(PACKAGE.ReleaseError):
                PACKAGE.verified_commit(root, commit)
            (root / "untracked.txt").unlink()
            (root / "source.txt").write_text("modified\n")
            with self.assertRaises(PACKAGE.ReleaseError):
                PACKAGE.verified_commit(root, commit)

    def test_missing_key_is_not_created_and_existing_identity_is_never_regenerated(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            key_directory = root / "signing"
            with patch.object(PACKAGE, "KEY_DIRECTORY", key_directory), patch.object(PACKAGE.Path, "home", return_value=root):
                with self.assertRaises(PACKAGE.ReleaseError):
                    PACKAGE.prepare_key_directory(False)
                self.assertFalse(key_directory.exists())
                key_directory.mkdir(mode=0o700)
                (key_directory / PACKAGE.KEY_NAME).write_bytes(b"existing identity placeholder")
                with patch.object(PACKAGE, "run", side_effect=AssertionError("Key tool must not execute")):
                    with self.assertRaises(PACKAGE.ReleaseError):
                        PACKAGE.initialize_key(Path("keytool"), {})
                self.assertEqual(b"existing identity placeholder", (key_directory / PACKAGE.KEY_NAME).read_bytes())

    def test_signing_material_cannot_be_public_or_symlinked(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            file = root / "private"
            file.write_bytes(b"fixture")
            file.chmod(0o600)
            PACKAGE.private_path(file)
            file.chmod(0o644)
            with self.assertRaises(PACKAGE.ReleaseError):
                PACKAGE.private_path(file)
            file.chmod(0o600)
            link = root / "linked"
            link.symlink_to(file)
            with self.assertRaises(PACKAGE.ReleaseError):
                PACKAGE.private_path(link)

    def test_exclusive_outputs_refuse_overwrite(self):
        with tempfile.TemporaryDirectory() as temporary:
            file = Path(temporary) / "artifact"
            PACKAGE.exclusive_write(file, b"first")
            with self.assertRaises(FileExistsError):
                PACKAGE.exclusive_write(file, b"second")
            self.assertEqual(b"first", file.read_bytes())


if __name__ == "__main__":
    unittest.main()
