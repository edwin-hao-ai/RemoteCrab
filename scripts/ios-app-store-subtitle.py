#!/usr/bin/env python3
"""Set the App Store subtitle (app-level localization) for RemoteCrab.

Subtitles live on appInfoLocalizations, not version localizations, so
ios-app-store-metadata.py cannot set them. Reads subtitles from
ios-metadata.json ("subtitles": {locale: text}).

Usage:
    python3 scripts/ios-app-store-subtitle.py
"""
import importlib.util
import json
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("ascmeta", SCRIPT_DIR / "ios-app-store-metadata.py")
asc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(asc)


def main():
    asc.load_env()
    metadata = asc.load_metadata()
    subtitles = metadata.get("subtitles", {})
    if not subtitles:
        print("No 'subtitles' in ios-metadata.json", file=sys.stderr)
        sys.exit(1)

    client = asc.ASCClient()
    app_id = metadata["appId"]

    infos = client.get(f"https://api.appstoreconnect.apple.com/v1/apps/{app_id}/appInfos?limit=5")
    info_id = infos["data"][0]["id"]

    locs = client.get(
        f"https://api.appstoreconnect.apple.com/v1/appInfos/{info_id}/appInfoLocalizations?limit=20"
    )
    existing = {loc["attributes"]["locale"]: loc["id"] for loc in locs.get("data", [])}

    for locale, subtitle in subtitles.items():
        payload = {"data": {"type": "appInfoLocalizations", "attributes": {"subtitle": subtitle}}}
        if locale in existing:
            loc_id = existing[locale]
            payload["data"]["id"] = loc_id
            print(f"  Updating subtitle {locale}: {subtitle}")
            client.patch(f"https://api.appstoreconnect.apple.com/v1/appInfoLocalizations/{loc_id}", payload)
        else:
            payload["data"]["attributes"]["locale"] = locale
            payload["data"]["relationships"] = {
                "appInfo": {"data": {"type": "appInfos", "id": info_id}}
            }
            print(f"  Creating subtitle {locale}: {subtitle}")
            client.post("https://api.appstoreconnect.apple.com/v1/appInfoLocalizations", payload)
    print("Done.")


if __name__ == "__main__":
    main()
