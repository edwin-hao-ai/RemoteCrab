#!/usr/bin/env python3
"""Manage TestFlight beta groups / testers / build assignment for RemoteCrab.

Usage:
    python3 scripts/ios-app-store-testflight.py --status
    python3 scripts/ios-app-store-testflight.py --setup-internal
    python3 scripts/ios-app-store-testflight.py --attach-build <build-number>
    python3 scripts/ios-app-store-testflight.py --submit-external-review

Environment: loads App Store Connect API credentials from
    ~/.config/mddock/ios-release.env
    (APPLE_API_KEY, APPLE_API_ISSUER, APPLE_API_KEY_PATH).
"""

import argparse
import base64
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

os.environ["no_proxy"] = "appstoreconnect.apple.com," + os.environ.get("no_proxy", "")
urllib.request.install_opener(urllib.request.build_opener(urllib.request.ProxyHandler({})))

SCRIPT_DIR = Path(__file__).resolve().parent
METADATA_PATH = SCRIPT_DIR / "ios-metadata.json"
INTERNAL_GROUP_NAME = "Internal"


def load_env():
    env_file = Path.home() / ".config" / "mddock" / "ios-release.env"
    if env_file.exists():
        for line in env_file.read_text().splitlines():
            if "=" in line and not line.strip().startswith("#"):
                k, v = line.strip().split("=", 1)
                os.environ.setdefault(k, os.path.expandvars(v))
    missing = [k for k in ("APPLE_API_KEY", "APPLE_API_ISSUER", "APPLE_API_KEY_PATH")
               if not os.environ.get(k)]
    if missing:
        print(f"Missing env: {missing}", file=sys.stderr)
        sys.exit(1)


def jwt_token():
    key_path, key_id, issuer_id = (os.environ["APPLE_API_KEY_PATH"],
                                   os.environ["APPLE_API_KEY"],
                                   os.environ["APPLE_API_ISSUER"])

    def b64url(data):
        if isinstance(data, str):
            data = data.encode()
        return base64.urlsafe_b64encode(data).decode().rstrip("=")

    def der_to_raw(der):
        idx = 2
        r_len = der[idx + 1]
        r = der[idx + 2:idx + 2 + r_len]
        idx = idx + 2 + r_len
        s_len = der[idx + 1]
        s = der[idx + 2:idx + 2 + s_len]
        if len(r) == 33 and r[0] == 0:
            r = r[1:]
        if len(s) == 33 and s[0] == 0:
            s = s[1:]
        return r.rjust(32, b"\x00") + s.rjust(32, b"\x00")

    now = int(time.time()) - 60
    header = b64url('{"alg":"ES256","kid":"%s","typ":"JWT"}' % key_id)
    payload = b64url('{"iss":"%s","iat":%s,"exp":%s,"aud":"appstoreconnect-v1"}'
                     % (issuer_id, now, now + 900))
    signing_input = f"{header}.{payload}"
    der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key_path],
                         input=signing_input.encode(), capture_output=True).stdout
    return f"{signing_input}.{b64url(der_to_raw(der))}"


class ASCClient:
    def __init__(self):
        self.token = jwt_token()
        self.headers = {"Authorization": f"Bearer {self.token}",
                        "Accept": "application/json",
                        "Content-Type": "application/json"}

    def request(self, method, url, data=None, ok=(200, 201, 204)):
        body = json.dumps(data).encode() if data is not None else None
        req = urllib.request.Request(url, data=body, headers=self.headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=120) as r:
                raw = r.read().decode()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as e:
            print(f"HTTP {e.code} {method} {url}", file=sys.stderr)
            print(e.read().decode()[:1500], file=sys.stderr)
            raise

    def get(self, url): return self.request("GET", url)
    def post(self, url, data): return self.request("POST", url, data)
    def patch(self, url, data): return self.request("PATCH", url, data)


def meta():
    return json.loads(METADATA_PATH.read_text())


def find_version(client, app_id, version_string):
    r = client.get(f"https://api.appstoreconnect.apple.com/v1/apps/{app_id}/appStoreVersions?"
                   f"filter[platform]=IOS&filter[versionString]={version_string}&limit=5")
    data = r.get("data", [])
    return data[0]["id"] if data else None


def find_build(client, app_id, build_number):
    r = client.get(f"https://api.appstoreconnect.apple.com/v1/builds?filter[app]={app_id}"
                   f"&filter[version]={build_number}&limit=5")
    data = r.get("data", [])
    return data[0] if data else None


def find_group(client, app_id, name):
    r = client.get(f"https://api.appstoreconnect.apple.com/v1/betaGroups?"
                   f"filter[app]={app_id}&filter[name]={urllib.parse.quote(name)}&limit=5")
    data = r.get("data", [])
    return data[0] if data else None


def cmd_status(client, m):
    app_id = m["appId"]
    print(f"App {app_id}")
    print("-- builds --")
    r = client.get(f"https://api.appstoreconnect.apple.com/v1/builds?filter[app]={app_id}"
                   f"&sort=-uploadedDate&limit=5")
    for b in r.get("data", []):
        a = b["attributes"]
        print(f"  {a.get('version'):>12}  {a.get('processingState'):10}  {a.get('uploadedDate')}  id={b['id']}")
    print("-- versions --")
    r = client.get(f"https://api.appstoreconnect.apple.com/v1/apps/{app_id}/appStoreVersions?limit=5")
    for v in r.get("data", []):
        a = v["attributes"]
        print(f"  {a.get('versionString'):>12}  {a.get('appStoreState')}")
    print("-- beta groups --")
    r = client.get(f"https://api.appstoreconnect.apple.com/v1/betaGroups?filter[app]={app_id}&limit=20")
    groups = r.get("data", [])
    if not groups:
        print("  (none)")
    for g in groups:
        a = g["attributes"]
        print(f"  {a.get('name')}  internal={a.get('isInternalGroup')}  id={g['id']}")
        tr = client.get(f"https://api.appstoreconnect.apple.com/v1/betaGroups/{g['id']}/betaTesters?limit=50")
        for t in tr.get("data", []):
            print(f"      tester: {t['attributes'].get('email')} ({t['attributes'].get('inviteType')})")
    print("-- testers --")
    r = client.get(f"https://api.appstoreconnect.apple.com/v1/betaTesters?limit=50")
    for t in r.get("data", []):
        a = t["attributes"]
        print(f"  {a.get('email')}  {a.get('inviteType')}  state={a.get('state')}")


def cmd_setup_internal(client, m):
    app_id = m["appId"]
    group = find_group(client, app_id, INTERNAL_GROUP_NAME)
    if group:
        print(f"Internal group exists: {group['id']}")
    else:
        print(f"Creating internal group '{INTERNAL_GROUP_NAME}'...")
        r = client.post("https://api.appstoreconnect.apple.com/v1/betaGroups", {
            "data": {"type": "betaGroups",
                     "attributes": {"name": INTERNAL_GROUP_NAME, "isInternalGroup": True},
                     "relationships": {"app": {"data": {"type": "apps", "id": app_id}}}}})
        group = r["data"]
        print(f"  created {group['id']}  internal={group['attributes'].get('isInternalGroup')}")
    return group["id"]


def attach_build_to_group(client, group_id, build_id):
    client.post(f"https://api.appstoreconnect.apple.com/v1/betaGroups/{group_id}/relationships/builds",
                {"data": [{"type": "builds", "id": build_id}]})
    print(f"  build {build_id} -> group {group_id}")


def attach_build_to_version(client, version_id, build_id):
    client.patch(f"https://api.appstoreconnect.apple.com/v1/appStoreVersions/{version_id}/relationships/build",
                 {"data": {"type": "builds", "id": build_id}})
    print(f"  build {build_id} -> version {version_id}")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--status", action="store_true")
    p.add_argument("--setup-internal", action="store_true")
    p.add_argument("--attach-build")
    p.add_argument("--version-string", default="1.0")
    args = p.parse_args()

    load_env()
    m = meta()
    client = ASCClient()

    if args.status or not any([args.setup_internal, args.attach_build]):
        cmd_status(client, m)
        return

    if args.setup_internal:
        group_id = cmd_setup_internal(client, m)
        m["_internal_group"] = group_id

    if args.attach_build:
        b = find_build(client, m["appId"], args.attach_build)
        if not b:
            print(f"Build {args.attach_build} not found", file=sys.stderr)
            sys.exit(1)
        if b["attributes"]["processingState"] != "VALID":
            print(f"Build {args.attach_build} not VALID yet: {b['attributes']['processingState']}")
        # attach to version (for eventual App Store submission)
        v = find_version(client, m["appId"], args.version_string)
        if v:
            attach_build_to_version(client, v, b["id"])
        # attach to internal group (for TestFlight)
        g = find_group(client, m["appId"], INTERNAL_GROUP_NAME)
        if g:
            attach_build_to_group(client, g["id"], b["id"])
        else:
            print("  (no internal group yet; run --setup-internal)")


if __name__ == "__main__":
    main()
