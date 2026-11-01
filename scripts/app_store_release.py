#!/usr/bin/env python3
"""Prepare and submit a Sofatap iPhone version through the App Store Connect API.

Steps, each one opt-in by flag:
  --plan              read-only: show the version, build and metadata differences
  --apply-metadata    create the version if missing, then write app-info and version localizations
  --attach-build      wait for the uploaded build to finish processing and attach it
  --review-notes FILE set the reviewer notes; contact details are copied from the previous version
  --submit            submit the version for App Review

Credentials come from the environment: ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH (the .p8 file).
Nothing is deleted. Locales that exist in App Store Connect but not in the repository are left alone.
"""
import argparse
import json
import os
import pathlib
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

import jwt  # PyJWT with the cryptography extra

API = "https://api.appstoreconnect.apple.com"
VERSION_FIELDS = ("description", "keywords", "promotionalText", "whatsNew", "supportUrl", "marketingUrl")
APP_INFO_FIELDS = ("name", "subtitle", "privacyPolicyUrl")
LIVE_STATES = {"READY_FOR_DISTRIBUTION", "READY_FOR_SALE", "REPLACED_WITH_NEW_INFO", "REMOVED_FROM_SALE"}
CONTACT_FIELDS = ("contactFirstName", "contactLastName", "contactPhone", "contactEmail")


class Client:
    def __init__(self):
        self.key_id = os.environ["ASC_KEY_ID"]
        self.issuer = os.environ["ASC_ISSUER_ID"]
        self.key = pathlib.Path(os.environ["ASC_KEY_PATH"]).read_text()
        self._token, self._expires = None, 0

    def token(self):
        now = int(time.time())
        if now > self._expires - 60:
            self._expires = now + 15 * 60
            self._token = jwt.encode(
                {"iss": self.issuer, "iat": now, "exp": self._expires, "aud": "appstoreconnect-v1"},
                self.key, algorithm="ES256", headers={"kid": self.key_id, "typ": "JWT"})
        return self._token

    def call(self, method, path, body=None, query=None, allow_404=False):
        url = API + path
        if query:
            url += "?" + urllib.parse.urlencode(query)
        data = json.dumps(body).encode() if body is not None else None
        request = urllib.request.Request(url, data=data, method=method, headers={
            "Authorization": "Bearer " + self.token(), "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                raw = response.read()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as error:
            if allow_404 and error.code == 404:
                return None
            detail = error.read().decode(errors="replace")
            raise SystemExit(f"{method} {path} failed with HTTP {error.code}: {detail}")

    def all(self, path, query=None):
        query = dict(query or {}, limit="200")
        page = self.call("GET", path, query=query)
        items = list(page.get("data", []))
        while page.get("links", {}).get("next"):
            nxt = urllib.parse.urlparse(page["links"]["next"])
            page = self.call("GET", nxt.path, query=dict(urllib.parse.parse_qsl(nxt.query)))
            items.extend(page.get("data", []))
        return items


def load_dir(directory):
    out = {}
    for path in sorted(pathlib.Path(directory).glob("*.json")):
        out[path.stem] = json.loads(path.read_text())
    if not out:
        raise SystemExit(f"No metadata files in {directory}")
    return out


def check_limits(app_info, version):
    limits = {"name": 30, "subtitle": 30, "keywords": 100, "promotionalText": 170,
              "description": 4000, "whatsNew": 4000}
    problems = []
    for kind, files in (("app-info", app_info), ("version", version)):
        for locale, fields in files.items():
            for field, value in fields.items():
                if field in limits and len(value) > limits[field]:
                    problems.append(f"{kind}/{locale}.{field} is {len(value)} > {limits[field]}")
    if set(app_info) != set(version):
        problems.append(f"locale mismatch: app-info {sorted(app_info)} vs version {sorted(version)}")
    if problems:
        raise SystemExit("Metadata validation failed:\n  " + "\n  ".join(problems))


def find_version(asc, app, version_string):
    found = asc.all(f"/v1/apps/{app}/appStoreVersions",
                    {"filter[platform]": "IOS", "filter[versionString]": version_string})
    return found[0] if found else None


def editable_app_info(asc, app):
    infos = asc.all(f"/v1/apps/{app}/appInfos")
    for info in infos:
        state = info["attributes"].get("state") or info["attributes"].get("appStoreState")
        if state not in LIVE_STATES:
            return info
    return None


def diff(kind, locale, wanted, current, fields):
    changes = []
    for field in fields:
        if field in wanted and (current or {}).get(field) != wanted[field]:
            changes.append(field)
    status = "new locale" if current is None else (", ".join(changes) if changes else "unchanged")
    print(f"  {kind:8} {locale:8} {status}")
    return changes


def sync_localizations(asc, kind, parent_type, parent_id, wanted_by_locale, fields, apply):
    list_path = (f"/v1/appStoreVersions/{parent_id}/appStoreVersionLocalizations" if kind == "version"
                 else f"/v1/appInfos/{parent_id}/appInfoLocalizations")
    resource = "appStoreVersionLocalizations" if kind == "version" else "appInfoLocalizations"
    relation = "appStoreVersion" if kind == "version" else "appInfo"
    existing = {item["attributes"]["locale"]: item for item in asc.all(list_path)}
    for locale, wanted in wanted_by_locale.items():
        current = existing.get(locale)
        changes = diff(kind, locale, wanted, current and current["attributes"], fields)
        if not apply:
            continue
        values = {field: wanted[field] for field in fields if field in wanted}
        if current is None:
            asc.call("POST", f"/v1/{resource}", {"data": {
                "type": resource, "attributes": dict(values, locale=locale),
                "relationships": {relation: {"data": {"type": parent_type, "id": parent_id}}}}})
        elif changes:
            asc.call("PATCH", f"/v1/{resource}/{current['id']}", {"data": {
                "type": resource, "id": current["id"],
                "attributes": {field: values[field] for field in changes}}})


def wait_for_build(asc, app, version_string, build_number, timeout):
    deadline = time.time() + timeout
    while True:
        builds = asc.all("/v1/builds", {"filter[app]": app, "filter[version]": build_number,
                                        "filter[preReleaseVersion.version]": version_string})
        if builds:
            state = builds[0]["attributes"].get("processingState")
            print(f"Build {version_string} ({build_number}): {state}")
            if state == "VALID":
                return builds[0]
            if state in ("FAILED", "INVALID"):
                raise SystemExit("The uploaded build failed App Store Connect processing")
        else:
            print(f"Build {version_string} ({build_number}) not visible yet")
        if time.time() > deadline:
            raise SystemExit("Timed out waiting for the build to finish processing")
        time.sleep(60)


def set_review_notes(asc, app, version, notes):
    detail = asc.call("GET", f"/v1/appStoreVersions/{version['id']}/appStoreReviewDetail", allow_404=True)
    detail = detail and detail.get("data")
    if detail:
        asc.call("PATCH", f"/v1/appStoreReviewDetails/{detail['id']}", {"data": {
            "type": "appStoreReviewDetails", "id": detail["id"], "attributes": {"notes": notes}}})
        print("Updated reviewer notes")
        return
    # Copy contact details from the newest other version that has them; they are not stored in the repository.
    for other in asc.all(f"/v1/apps/{app}/appStoreVersions", {"filter[platform]": "IOS"}):
        if other["id"] == version["id"]:
            continue
        previous = asc.call("GET", f"/v1/appStoreVersions/{other['id']}/appStoreReviewDetail", allow_404=True)
        previous = previous and previous.get("data")
        if previous and all(previous["attributes"].get(field) for field in CONTACT_FIELDS):
            attributes = {field: previous["attributes"][field] for field in CONTACT_FIELDS}
            attributes.update(notes=notes, demoAccountRequired=False)
            asc.call("POST", "/v1/appStoreReviewDetails", {"data": {
                "type": "appStoreReviewDetails", "attributes": attributes,
                "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": version["id"]}}}}})
            print(f"Created reviewer details with the contact from version {other['attributes']['versionString']}")
            return
    raise SystemExit("No earlier version has review contact details to copy; add them in App Store Connect")


def submit(asc, app, version):
    open_submissions = asc.all("/v1/reviewSubmissions", {
        "filter[app]": app, "filter[platform]": "IOS", "filter[state]": "READY_FOR_REVIEW"})
    if open_submissions:
        submission = open_submissions[0]
    else:
        submission = asc.call("POST", "/v1/reviewSubmissions", {"data": {
            "type": "reviewSubmissions", "attributes": {"platform": "IOS"},
            "relationships": {"app": {"data": {"type": "apps", "id": app}}}}})["data"]
    items = asc.all(f"/v1/reviewSubmissions/{submission['id']}/items")
    if not items:
        asc.call("POST", "/v1/reviewSubmissionItems", {"data": {
            "type": "reviewSubmissionItems",
            "relationships": {
                "reviewSubmission": {"data": {"type": "reviewSubmissions", "id": submission["id"]}},
                "appStoreVersion": {"data": {"type": "appStoreVersions", "id": version["id"]}}}}})
    result = asc.call("PATCH", f"/v1/reviewSubmissions/{submission['id']}", {"data": {
        "type": "reviewSubmissions", "id": submission["id"], "attributes": {"submitted": True}}})
    print(f"Submitted for review: submission {submission['id']}, state {result['data']['attributes'].get('state')}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--metadata", default="docs/app-store/metadata")
    parser.add_argument("--plan", action="store_true")
    parser.add_argument("--apply-metadata", action="store_true")
    parser.add_argument("--attach-build", action="store_true")
    parser.add_argument("--review-notes")
    parser.add_argument("--submit", action="store_true")
    parser.add_argument("--build-timeout", type=int, default=3600)
    args = parser.parse_args()

    app_info_files = load_dir(pathlib.Path(args.metadata) / "app-info")
    version_files = load_dir(pathlib.Path(args.metadata) / "version" / args.version)
    check_limits(app_info_files, version_files)
    print(f"Repository metadata for {args.version}: {len(version_files)} locales, limits OK")

    asc = Client()
    version = find_version(asc, args.app, args.version)
    if version is None:
        print(f"Version {args.version} does not exist yet")
        if not args.apply_metadata:
            print("Plan: --apply-metadata would create it with release type AFTER_APPROVAL")
            return
        version = asc.call("POST", "/v1/appStoreVersions", {"data": {
            "type": "appStoreVersions",
            "attributes": {"platform": "IOS", "versionString": args.version, "releaseType": "AFTER_APPROVAL"},
            "relationships": {"app": {"data": {"type": "apps", "id": args.app}}}}})["data"]
        print(f"Created version {args.version}")
    print(f"Version {args.version}: {version['attributes'].get('appStoreState') or version['attributes'].get('appVersionState')}")

    info = editable_app_info(asc, args.app)
    if info is None:
        raise SystemExit("No editable app info record (it appears after a new version is created)")
    sync_localizations(asc, "app-info", "appInfos", info["id"], app_info_files, APP_INFO_FIELDS, args.apply_metadata)
    sync_localizations(asc, "version", "appStoreVersions", version["id"], version_files, VERSION_FIELDS,
                       args.apply_metadata)

    if args.attach_build:
        build = wait_for_build(asc, args.app, args.version, args.build, args.build_timeout)
        asc.call("PATCH", f"/v1/appStoreVersions/{version['id']}/relationships/build",
                 {"data": {"type": "builds", "id": build["id"]}})
        print(f"Attached build {args.build}")
    if args.review_notes:
        set_review_notes(asc, args.app, version, pathlib.Path(args.review_notes).read_text().rstrip("\n"))
    if args.submit:
        submit(asc, args.app, version)


if __name__ == "__main__":
    main()
