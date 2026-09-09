#!/usr/bin/env python3
"""Manage App Store Connect metadata and screenshots for MDDock iOS.

Usage:
    python3 scripts/ios-app-store-metadata.py --version 0.3.7 --metadata
    python3 scripts/ios-app-store-metadata.py --version 0.3.7 --screenshots
    python3 scripts/ios-app-store-metadata.py --version 0.3.7 --metadata --screenshots

Environment:
    Loads App Store Connect API credentials from ~/.config/mddock/ios-release.env
    (APPLE_API_KEY, APPLE_API_ISSUER, APPLE_API_KEY_PATH).
"""

import argparse
import base64
import hashlib
import json
import os
import subprocess
import sys
import time
import urllib.request
import urllib.error
from pathlib import Path

# App Store Connect API does not work through local auto-detected proxies
# (common in Chinese dev environments). Force direct connections.
os.environ["no_proxy"] = "appstoreconnect.apple.com," + os.environ.get("no_proxy", "")
urllib.request.install_opener(urllib.request.build_opener(urllib.request.ProxyHandler({})))


SCRIPT_DIR = Path(__file__).resolve().parent
ROOT = SCRIPT_DIR.parent
METADATA_PATH = SCRIPT_DIR / "ios-metadata.json"
DEFAULT_SCREENSHOTS_DIR = ROOT / "ios-screenshots"

DISPLAY_TYPES = {
    "iphone67": "APP_IPHONE_67",
    "iphone65": "APP_IPHONE_65",
    "iphone55": "APP_IPHONE_55",
    "ipad129": "APP_IPAD_PRO_3GEN_129",
}

SCREENSHOT_SIZES = {
    "iphone67": (1290, 2796),
    "iphone65": (1242, 2688),
    "iphone55": (1242, 2208),
    "ipad129": (2048, 2732),
}


def load_env():
    env_file = Path.home() / ".config" / "mddock" / "ios-release.env"
    if env_file.exists():
        with open(env_file) as f:
            for line in f:
                if "=" in line and not line.strip().startswith("#"):
                    k, v = line.strip().split("=", 1)
                    os.environ.setdefault(k, os.path.expandvars(v))
    missing = [k for k in ("APPLE_API_KEY", "APPLE_API_ISSUER", "APPLE_API_KEY_PATH")
               if not os.environ.get(k)]
    if missing:
        print(f"Missing env: {missing}", file=sys.stderr)
        sys.exit(1)


def jwt_token():
    key_path = os.environ["APPLE_API_KEY_PATH"]
    key_id = os.environ["APPLE_API_KEY"]
    issuer_id = os.environ["APPLE_API_ISSUER"]

    def b64url(data):
        if isinstance(data, str):
            data = data.encode()
        return base64.urlsafe_b64encode(data).decode().rstrip("=")

    def der_to_raw(der):
        assert der[0] == 0x30
        idx = 2
        assert der[idx] == 0x02
        r_len = der[idx + 1]
        r = der[idx + 2:idx + 2 + r_len]
        idx = idx + 2 + r_len
        assert der[idx] == 0x02
        s_len = der[idx + 1]
        s = der[idx + 2:idx + 2 + s_len]
        if len(r) == 33 and r[0] == 0:
            r = r[1:]
        if len(s) == 33 and s[0] == 0:
            s = s[1:]
        return r.rjust(32, b"\x00") + s.rjust(32, b"\x00")

    now = int(time.time()) - 60
    exp = now + 900
    header = b64url('{"alg":"ES256","kid":"%s","typ":"JWT"}' % key_id)
    payload = b64url('{"iss":"%s","iat":%s,"exp":%s,"aud":"appstoreconnect-v1"}' % (issuer_id, now, exp))
    signing_input = f"{header}.{payload}"
    der = subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", key_path],
        input=signing_input.encode(), capture_output=True
    ).stdout
    raw = der_to_raw(der)
    return f"{signing_input}.{b64url(raw)}"


class ASCClient:
    def __init__(self):
        self.token = jwt_token()
        self.headers = {
            "Authorization": f"Bearer {self.token}",
            "Accept": "application/json",
            "Content-Type": "application/json",
        }

    def request(self, method, url, data=None):
        body = json.dumps(data).encode() if data is not None else None
        req = urllib.request.Request(url, data=body, headers=self.headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=120) as r:
                return json.loads(r.read().decode())
        except urllib.error.HTTPError as e:
            print(f"HTTP {e.code} {method} {url}", file=sys.stderr)
            print(e.read().decode()[:1200], file=sys.stderr)
            raise

    def get(self, url): return self.request("GET", url)
    def post(self, url, data): return self.request("POST", url, data)
    def patch(self, url, data): return self.request("PATCH", url, data)


def load_metadata():
    with open(METADATA_PATH) as f:
        return json.load(f)


def get_or_create_version(client, app_id, platform, version_string, create=False):
    versions = client.get(
        f"https://api.appstoreconnect.apple.com/v1/apps/{app_id}/appStoreVersions?"
        f"filter[platform]={platform}&filter[versionString]={version_string}&limit=5"
    )
    for v in versions.get("data", []):
        return v["id"]
    if not create:
        print(f"App Store version {version_string} not found. Use --create-version to create it.", file=sys.stderr)
        sys.exit(1)
    print(f"Creating App Store version {version_string}...")
    result = client.post("https://api.appstoreconnect.apple.com/v1/appStoreVersions", {
        "data": {
            "type": "appStoreVersions",
            "attributes": {"platform": platform, "versionString": version_string},
            "relationships": {
                "app": {"data": {"type": "apps", "id": app_id}}
            }
        }
    })
    return result["data"]["id"]


def update_metadata(client, version_id, metadata, version_string):
    locs = client.get(
        f"https://api.appstoreconnect.apple.com/v1/appStoreVersions/{version_id}/appStoreVersionLocalizations?limit=20"
    )
    existing = {loc["attributes"]["locale"]: loc["id"] for loc in locs.get("data", [])}

    for locale, attrs in metadata["locales"].items():
        payload = {"data": {"type": "appStoreVersionLocalizations", "attributes": {}}}
        for key in ("description", "keywords", "marketingUrl", "supportUrl", "promotionalText"):
            if key in attrs:
                payload["data"]["attributes"][key] = attrs.get(key)
        # whatsNew is only editable for updates (not the very first release).
        # Only send it when explicitly provided in the metadata JSON.
        whats_new = attrs.get("whatsNew")
        if whats_new:
            payload["data"]["attributes"]["whatsNew"] = whats_new

        if locale in existing:
            loc_id = existing[locale]
            payload["data"]["id"] = loc_id
            print(f"  Updating localization {locale}...")
            client.patch(f"https://api.appstoreconnect.apple.com/v1/appStoreVersionLocalizations/{loc_id}", payload)
        else:
            payload["data"]["attributes"]["locale"] = locale
            payload["data"]["relationships"] = {
                "appStoreVersion": {"data": {"type": "appStoreVersions", "id": version_id}}
            }
            print(f"  Creating localization {locale}...")
            client.post("https://api.appstoreconnect.apple.com/v1/appStoreVersionLocalizations", payload)


def md5_file(path):
    h = hashlib.md5()
    with open(path, "rb") as f:
        while True:
            chunk = f.read(8192)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()


def upload_screenshot(client, set_id, path):
    size = os.path.getsize(path)
    checksum = md5_file(path)
    fname = os.path.basename(path)
    screenshot = client.post("https://api.appstoreconnect.apple.com/v1/appScreenshots", {
        "data": {
            "type": "appScreenshots",
            "attributes": {"fileName": fname, "fileSize": size},
            "relationships": {
                "appScreenshotSet": {"data": {"type": "appScreenshotSets", "id": set_id}}
            }
        }
    })
    shot_id = screenshot["data"]["id"]
    for op in screenshot["data"]["attributes"].get("uploadOperations", []):
        upload_url = op["url"]
        method = op.get("method", "PUT")
        upload_headers = {h["name"]: h["value"] for h in op.get("headers", [])}
        offset = op.get("offset", 0)
        length = op.get("length", size)
        with open(path, "rb") as f:
            f.seek(offset)
            chunk = f.read(length)
        req = urllib.request.Request(upload_url, data=chunk, headers=upload_headers, method=method)
        with urllib.request.urlopen(req, timeout=120) as r:
            r.read()
    client.patch(f"https://api.appstoreconnect.apple.com/v1/appScreenshots/{shot_id}", {
        "data": {
            "type": "appScreenshots",
            "id": shot_id,
            "attributes": {"uploaded": True, "sourceFileChecksum": checksum}
        }
    })
    return shot_id


def delete_existing_screenshot_set(client, set_id):
    """Remove all screenshots from a set so we can re-upload in order."""
    shots = client.get(
        f"https://api.appstoreconnect.apple.com/v1/appScreenshotSets/{set_id}/appScreenshots?limit=50"
    )
    for shot in shots.get("data", []):
        shot_id = shot["id"]
        req = urllib.request.Request(
            f"https://api.appstoreconnect.apple.com/v1/appScreenshots/{shot_id}",
            headers={"Authorization": f"Bearer {client.token}", "Accept": "application/json"},
            method="DELETE"
        )
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                r.read()
        except urllib.error.HTTPError as e:
            print(f"Warning: failed to delete screenshot {shot_id}: HTTP {e.code}", file=sys.stderr)


def update_screenshots(client, version_id, metadata, screenshots_dir):
    locales = list(metadata["locales"].keys())
    # We update screenshots for every locale that has metadata.
    locs = client.get(
        f"https://api.appstoreconnect.apple.com/v1/appStoreVersions/{version_id}/appStoreVersionLocalizations?limit=20"
    )
    locale_to_id = {loc["attributes"]["locale"]: loc["id"] for loc in locs.get("data", [])}

    for locale in locales:
        loc_id = locale_to_id.get(locale)
        if not loc_id:
            print(f"  Localization {locale} not found, skipping screenshots", file=sys.stderr)
            continue

        existing_sets = client.get(
            f"https://api.appstoreconnect.apple.com/v1/appStoreVersionLocalizations/{loc_id}/appScreenshotSets?limit=20"
        )
        existing_by_type = {
            s["attributes"]["screenshotDisplayType"]: s["id"]
            for s in existing_sets.get("data", [])
        }

        for key, display_type in DISPLAY_TYPES.items():
            files = metadata["screenshots"].get(key, [])
            if not files:
                continue

            if display_type in existing_by_type:
                set_id = existing_by_type[display_type]
                print(f"  Reusing {display_type} set for {locale}")
                delete_existing_screenshot_set(client, set_id)
            else:
                print(f"  Creating {display_type} set for {locale}...")
                result = client.post("https://api.appstoreconnect.apple.com/v1/appScreenshotSets", {
                    "data": {
                        "type": "appScreenshotSets",
                        "attributes": {"screenshotDisplayType": display_type},
                        "relationships": {
                            "appStoreVersionLocalization": {"data": {"type": "appStoreVersionLocalizations", "id": loc_id}}
                        }
                    }
                })
                set_id = result["data"]["id"]

            for slot in files:
                # Prefer per-locale screenshots, fall back to generic dir.
                path = screenshots_dir / locale / f"{key}-{slot}.png"
                if not path.exists():
                    path = screenshots_dir / f"{key}-{slot}.png"
                if not path.exists():
                    print(f"    Missing screenshot: {path}", file=sys.stderr)
                    continue
                print(f"    Uploading {path.name}...")
                upload_screenshot(client, set_id, path)


def main():
    parser = argparse.ArgumentParser(description="Update MDDock iOS App Store metadata and screenshots")
    parser.add_argument("--version", required=True, help="App Store version string (e.g. 0.3.7)")
    parser.add_argument("--metadata", action="store_true", help="Update metadata localizations")
    parser.add_argument("--screenshots", action="store_true", help="Upload screenshots")
    parser.add_argument("--create-version", action="store_true", help="Create App Store version if missing")
    parser.add_argument("--screenshots-dir", type=Path, default=DEFAULT_SCREENSHOTS_DIR,
                        help="Directory containing PNG screenshots")
    args = parser.parse_args()

    if not args.metadata and not args.screenshots:
        parser.error("Specify at least one of --metadata or --screenshots")

    load_env()
    metadata = load_metadata()
    client = ASCClient()

    print(f"App Store Connect: app {metadata['appId']}, version {args.version}")
    version_id = get_or_create_version(
        client, metadata["appId"], metadata["platform"], args.version, args.create_version
    )
    print(f"App Store version id: {version_id}")

    if args.metadata:
        print("Updating metadata...")
        update_metadata(client, version_id, metadata, args.version)

    if args.screenshots:
        print("Updating screenshots...")
        update_screenshots(client, version_id, metadata, args.screenshots_dir)

    print("Done.")


if __name__ == "__main__":
    main()
