"""Fills Bubbleg's App Store Connect listing from AppStore/asc/listing.json through the App Store Connect API.

    python3 AppStore/asc/fill.py <KEY_ID> <ISSUER_ID> [steps...]

Steps (default: all but `build`, in this order): info, version, review, age, price, media, build.
Each step reads what exists first and patches it, so running again is safe. Media steps skip a set that
already holds files; pass --replace to delete them and upload again. It never submits for review.
Review contact email and phone come from the environment: ASC_CONTACT_EMAIL, ASC_CONTACT_PHONE.
"""
import hashlib
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
STORE = os.path.dirname(HERE)
API = "https://api.appstoreconnect.apple.com"

args = [a for a in sys.argv[1:] if not a.startswith("--")]
REPLACE = "--replace" in sys.argv
KEY_ID, ISSUER = args[0], args[1]
STEPS = args[2:] or ["info", "version", "review", "age", "price", "media"]
L = json.load(open(os.path.join(HERE, "listing.json")))

TOKEN = subprocess.run(["swift", os.path.join(HERE, "token.swift"), KEY_ID, ISSUER],
                       check=True, capture_output=True, text=True).stdout.strip()


def call(method, path, body=None, ok_missing=False):
    url = path if path.startswith("http") else API + path
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers={
        "Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as r:
            raw = r.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        detail = e.read().decode()
        if ok_missing and e.code == 404:
            return None
        raise SystemExit(f"{method} {path} → {e.code}\n{detail}")


def log(step, msg):
    print(f"[{step}] {msg}")


def find_app():
    apps = call("GET", f"/v1/apps?filter[bundleId]={L['bundleId']}")["data"]
    if not apps:
        raise SystemExit(f"No app record for {L['bundleId']} yet. Create it in App Store Connect first.")
    return apps[0]


def editable_app_info(app_id):
    infos = call("GET", f"/v1/apps/{app_id}/appInfos")["data"]
    for info in infos:
        if info["attributes"].get("state") in ("PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "WAITING_FOR_REVIEW") \
                or info["attributes"].get("appStoreState") == "PREPARE_FOR_SUBMISSION":
            return info
    return infos[0]


def mac_version(app_id):
    versions = call("GET", f"/v1/apps/{app_id}/appStoreVersions?filter[platform]=MAC_OS")["data"]
    for v in versions:
        if v["attributes"]["appStoreState"] in ("PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED"):
            return v
    if versions:
        raise SystemExit("No editable macOS version (all are in review or live).")
    return call("POST", "/v1/appStoreVersions", {"data": {
        "type": "appStoreVersions", "attributes": {"platform": "MAC_OS", "versionString": L["version"]},
        "relationships": {"app": {"data": {"type": "apps", "id": app_id}}}}})["data"]


def localization(collection_path, kind, parent_rel, parent_type, parent_id, attributes):
    """Patches the listing locale's localization, creating it when missing."""
    for loc in call("GET", collection_path)["data"]:
        if loc["attributes"]["locale"] == L["locale"]:
            call("PATCH", f"/v1/{kind}/{loc['id']}", {"data": {"type": kind, "id": loc["id"], "attributes": attributes}})
            return loc
    return call("POST", f"/v1/{kind}", {"data": {"type": kind, "attributes": {"locale": L["locale"], **attributes},
                                                 "relationships": {parent_rel: {"data": {"type": parent_type, "id": parent_id}}}}})["data"]


app = find_app()
APP_ID = app["id"]
print(f"App: {app['attributes']['name']} ({APP_ID})")
version = mac_version(APP_ID)
VERSION_ID = version["id"]

if "info" in STEPS:
    info = editable_app_info(APP_ID)
    call("PATCH", f"/v1/appInfos/{info['id']}", {"data": {"type": "appInfos", "id": info["id"], "relationships": {
        "primaryCategory": {"data": {"type": "appCategories", "id": L["primaryCategory"]}},
        "secondaryCategory": {"data": {"type": "appCategories", "id": L["secondaryCategory"]}}}}})
    log("info", f"categories {L['primaryCategory']} / {L['secondaryCategory']}")
    localization(f"/v1/appInfos/{info['id']}/appInfoLocalizations", "appInfoLocalizations", "appInfo", "appInfos", info["id"],
                 {"subtitle": L["subtitle"], "privacyPolicyUrl": L["privacyPolicyUrl"]})
    log("info", f"subtitle and privacy policy URL ({L['locale']})")

if "version" in STEPS:
    call("PATCH", f"/v1/appStoreVersions/{VERSION_ID}", {"data": {"type": "appStoreVersions", "id": VERSION_ID, "attributes": {
        "versionString": L["version"], "copyright": L["copyright"]}}})
    log("version", f"version {L['version']}, copyright")
    localization(f"/v1/appStoreVersions/{VERSION_ID}/appStoreVersionLocalizations", "appStoreVersionLocalizations",
                 "appStoreVersion", "appStoreVersions", VERSION_ID,
                 {k: L[k] for k in ("description", "keywords", "promotionalText", "supportUrl", "marketingUrl")})
    log("version", "description, keywords, promotional text, support and marketing URLs")

if "review" in STEPS:
    attrs = dict(L["review"])
    if os.environ.get("ASC_CONTACT_EMAIL"):
        attrs["contactEmail"] = os.environ["ASC_CONTACT_EMAIL"]
    if os.environ.get("ASC_CONTACT_PHONE"):
        attrs["contactPhone"] = os.environ["ASC_CONTACT_PHONE"]
    existing = call("GET", f"/v1/appStoreVersions/{VERSION_ID}/appStoreReviewDetail", ok_missing=True)
    if existing and existing.get("data"):
        rid = existing["data"]["id"]
        call("PATCH", f"/v1/appStoreReviewDetails/{rid}", {"data": {"type": "appStoreReviewDetails", "id": rid, "attributes": attrs}})
    else:
        call("POST", "/v1/appStoreReviewDetails", {"data": {"type": "appStoreReviewDetails", "attributes": attrs, "relationships": {
            "appStoreVersion": {"data": {"type": "appStoreVersions", "id": VERSION_ID}}}}})
    missing = [k for k in ("contactEmail", "contactPhone") if k not in attrs]
    log("review", "notes and contact name" + (f"; still needed: {', '.join(missing)}" if missing else ", email, phone"))

if "age" in STEPS:
    info = editable_app_info(APP_ID)
    decl = call("GET", f"/v1/appInfos/{info['id']}/ageRatingDeclaration")["data"]
    attrs = {}
    for k, v in decl["attributes"].items():
        if "Override" in k:  # Apple's own overrides; setting the v1 one clashes with v2
            continue
        if isinstance(v, bool):
            attrs[k] = False
        elif isinstance(v, str) and v in ("NONE", "INFREQUENT_OR_MILD", "FREQUENT_OR_INTENSE", "INFREQUENT", "FREQUENT"):
            attrs[k] = "NONE"
    # Unset fields come back null; answer the ones every app has to.
    for k in ("alcoholTobaccoOrDrugUseOrReferences", "contests", "gamblingSimulated", "horrorOrFearThemes",
              "matureOrSuggestiveThemes", "medicalOrTreatmentInformation", "profanityOrCrudeHumor",
              "sexualContentGraphicAndNudity", "sexualContentOrNudity", "violenceCartoonOrFantasy",
              "violenceRealistic", "violenceRealisticProlongedGraphicOrSadistic", "gunsOrOtherWeapons"):
        if k in decl["attributes"] and decl["attributes"][k] is None:
            attrs[k] = "NONE"
    for k in ("gambling", "unrestrictedWebAccess", "lootBox", "messagingAndChat", "parentalControls", "ageAssurance",
              "userGeneratedContent", "advertising", "healthOrWellnessTopics", "socialMedia"):
        if k in decl["attributes"] and decl["attributes"][k] is None:
            attrs[k] = False
    call("PATCH", f"/v1/ageRatingDeclarations/{decl['id']}", {"data": {"type": "ageRatingDeclarations", "id": decl["id"], "attributes": attrs}})
    log("age", f"answered {len(attrs)} questions: none of them apply")

if "price" in STEPS:
    points = call("GET", f"/v1/apps/{APP_ID}/appPricePoints?filter[territory]=USA&limit=200")["data"]
    free = next(p for p in points if float(p["attributes"]["customerPrice"]) == 0)
    call("POST", "/v1/appPriceSchedules", {"data": {"type": "appPriceSchedules", "relationships": {
        "app": {"data": {"type": "apps", "id": APP_ID}},
        "baseTerritory": {"data": {"type": "territories", "id": "USA"}},
        "manualPrices": {"data": [{"type": "appPrices", "id": "${free}"}]}}},
        "included": [{"type": "appPrices", "id": "${free}", "attributes": {"startDate": None},
                      "relationships": {"appPricePoint": {"data": {"type": "appPricePoints", "id": free["id"]}}}}]})
    log("price", "free")
    territories, url = [], "/v1/territories?limit=200"
    while url:
        page = call("GET", url)
        territories += [t["id"] for t in page["data"]]
        url = page.get("links", {}).get("next")
    existing = call("GET", f"/v1/apps/{APP_ID}/appAvailabilityV2", ok_missing=True)
    if existing and existing.get("data"):
        log("price", "availability already set; left as is")
    else:
        call("POST", "/v2/appAvailabilities", {"data": {"type": "appAvailabilities", "attributes": {"availableInNewTerritories": True},
            "relationships": {"app": {"data": {"type": "apps", "id": APP_ID}},
                              "territoryAvailabilities": {"data": [{"type": "territoryAvailabilities", "id": f"${{{t}}}"} for t in territories]}}},
            "included": [{"type": "territoryAvailabilities", "id": f"${{{t}}}", "attributes": {"available": True},
                          "relationships": {"territory": {"data": {"type": "territories", "id": t}}}} for t in territories]})
        log("price", f"available in all {len(territories)} territories and new ones")


def upload(kind, set_rel, set_type, set_id, path, extra=None):
    """Reserve → upload the parts Apple asks for → commit with an MD5 checksum."""
    blob = open(path, "rb").read()
    attrs = {"fileName": os.path.basename(path), "fileSize": len(blob), **(extra or {})}
    asset = call("POST", f"/v1/{kind}", {"data": {"type": kind, "attributes": attrs,
                                                 "relationships": {set_rel: {"data": {"type": set_type, "id": set_id}}}}})["data"]
    for op in asset["attributes"]["uploadOperations"]:
        part = blob[op["offset"]:op["offset"] + op["length"]]
        req = urllib.request.Request(op["url"], data=part, method=op["method"],
                                     headers={h["name"]: h["value"] for h in op["requestHeaders"]})
        urllib.request.urlopen(req).read()
    commit = {"uploaded": True, "sourceFileChecksum": hashlib.md5(blob).hexdigest()}
    call("PATCH", f"/v1/{kind}/{asset['id']}", {"data": {"type": kind, "id": asset["id"], "attributes": commit}})
    return asset["id"]


if "media" in STEPS:
    loc = localization(f"/v1/appStoreVersions/{VERSION_ID}/appStoreVersionLocalizations", "appStoreVersionLocalizations",
                       "appStoreVersion", "appStoreVersions", VERSION_ID, {})
    sets = call("GET", f"/v1/appStoreVersionLocalizations/{loc['id']}/appScreenshotSets")["data"]
    shots = next((s for s in sets if s["attributes"]["screenshotDisplayType"] == "APP_DESKTOP"), None) or call(
        "POST", "/v1/appScreenshotSets", {"data": {"type": "appScreenshotSets", "attributes": {"screenshotDisplayType": "APP_DESKTOP"},
            "relationships": {"appStoreVersionLocalization": {"data": {"type": "appStoreVersionLocalizations", "id": loc["id"]}}}}})["data"]
    have = call("GET", f"/v1/appScreenshotSets/{shots['id']}/appScreenshots")["data"]
    if have and REPLACE:
        for s in have:
            call("DELETE", f"/v1/appScreenshots/{s['id']}")
        have = []
    if have:
        log("media", f"screenshot set already has {len(have)}; skipped (--replace to redo)")
    else:
        for p in L["screenshots"]:
            upload("appScreenshots", "appScreenshotSet", "appScreenshotSets", shots["id"], os.path.join(STORE, p))
            log("media", f"screenshot {os.path.basename(p)}")

    psets = call("GET", f"/v1/appStoreVersionLocalizations/{loc['id']}/appPreviewSets")["data"]
    pset = next((s for s in psets if s["attributes"]["previewType"] == "DESKTOP"), None) or call(
        "POST", "/v1/appPreviewSets", {"data": {"type": "appPreviewSets", "attributes": {"previewType": "DESKTOP"},
            "relationships": {"appStoreVersionLocalization": {"data": {"type": "appStoreVersionLocalizations", "id": loc["id"]}}}}})["data"]
    have = call("GET", f"/v1/appPreviewSets/{pset['id']}/appPreviews")["data"]
    if have and REPLACE:
        for s in have:
            call("DELETE", f"/v1/appPreviews/{s['id']}")
        have = []
    if have:
        log("media", "preview already uploaded; skipped (--replace to redo)")
    else:
        pid = upload("appPreviews", "appPreviewSet", "appPreviewSets", pset["id"], os.path.join(STORE, L["preview"]),
                     {"mimeType": "video/mp4"})
        call("PATCH", f"/v1/appPreviews/{pid}", {"data": {"type": "appPreviews", "id": pid,
                                                         "attributes": {"previewFrameTimeCode": L["previewFrameTimeCode"]}}})
        log("media", f"App Preview {os.path.basename(L['preview'])}, poster at {L['previewFrameTimeCode']}")

if "poster" in STEPS:
    # The poster frame can only be set once Apple has finished processing the uploaded video.
    loc = localization(f"/v1/appStoreVersions/{VERSION_ID}/appStoreVersionLocalizations", "appStoreVersionLocalizations",
                       "appStoreVersion", "appStoreVersions", VERSION_ID, {})
    psets = call("GET", f"/v1/appStoreVersionLocalizations/{loc['id']}/appPreviewSets")["data"]
    previews = [p for s in psets for p in call("GET", f"/v1/appPreviewSets/{s['id']}/appPreviews")["data"]]
    if not previews:
        raise SystemExit("[poster] no preview uploaded")
    p = previews[0]
    state = (p["attributes"].get("assetDeliveryState") or {}).get("state")
    if state != "COMPLETE":
        raise SystemExit(f"[poster] video still processing ({state})")
    call("PATCH", f"/v1/appPreviews/{p['id']}", {"data": {"type": "appPreviews", "id": p["id"],
                                                         "attributes": {"previewFrameTimeCode": L["previewFrameTimeCode"]}}})
    log("poster", f"poster frame at {L['previewFrameTimeCode']}")

if "build" in STEPS:
    builds = call("GET", f"/v1/builds?filter[app]={APP_ID}&filter[preReleaseVersion.platform]=MAC_OS&sort=-uploadedDate&limit=5")["data"]
    ready = [b for b in builds if b["attributes"]["processingState"] == "VALID"]
    if not ready:
        states = ", ".join(f"{b['attributes']['version']}: {b['attributes']['processingState']}" for b in builds) or "none uploaded"
        raise SystemExit(f"[build] no processed build yet ({states})")
    b = ready[0]
    call("PATCH", f"/v1/appStoreVersions/{VERSION_ID}/relationships/build", {"data": {"type": "builds", "id": b["id"]}})
    log("build", f"attached build {b['attributes']['version']} to version {L['version']}")

print("Done. Nothing was submitted for review.")
