#!/usr/bin/env python3
"""Read-only, exact-cycle App Store review monitor and bounded GitHub deduplicator."""
import argparse, base64, json, os, re, subprocess, sys, time, urllib.parse, urllib.request
from pathlib import Path

BUNDLE_ID = "com.kunchenguid.eddieswallet"
MAX_CYCLES = 32
VERSION_RE = re.compile(r"^[0-9]+(?:\.[0-9]+){1,2}$")
BUILD_RE = re.compile(r"^[0-9]+(?:\.[0-9]+){0,2}$")
STATE_CATEGORY = {
    "PREPARE_FOR_SUBMISSION": "not-submitted", "READY_FOR_REVIEW": "ready-for-review",
    "WAITING_FOR_REVIEW": "waiting-for-review", "IN_REVIEW": "in-review",
    "PENDING_DEVELOPER_RELEASE": "approved", "PENDING_APPLE_RELEASE": "approved",
    "READY_FOR_SALE": "approved", "REJECTED": "action-required",
    "METADATA_REJECTED": "action-required", "INVALID_BINARY": "action-required",
    "DEVELOPER_REJECTED": "withdrawn", "DEVELOPER_REMOVED_FROM_SALE": "not-for-sale",
    "REMOVED_FROM_SALE": "not-for-sale",
}
SAFE_STATES = set(STATE_CATEGORY)
ISSUE_TITLE = "App Store review monitor state"

class MonitorError(Exception): pass

def cycle(version, build):
    if not VERSION_RE.fullmatch(version or "") or not BUILD_RE.fullmatch(build or ""):
        raise MonitorError("Cycle must use a numeric marketing version and build number")
    return {"bundleId": BUNDLE_ID, "version": version, "build": build}

def safe_state(value):
    return value if value in SAFE_STATES else "UNKNOWN"

def observation(version, build, state):
    state = safe_state(state)
    return {"cycle": cycle(version, build), "state": state, "category": STATE_CATEGORY.get(state, "unknown")}

def page_items(fetch, url):
    """Follow only same-origin ASC pagination links and require JSON:API lists."""
    seen, items = set(), []
    while url:
        if url in seen: raise MonitorError("App Store Connect pagination loop")
        seen.add(url)
        payload = fetch(url)
        data = payload.get("data") if isinstance(payload, dict) else None
        if not isinstance(data, list): raise MonitorError("App Store Connect returned malformed collection")
        items.extend(data)
        nxt = payload.get("links", {}).get("next") if isinstance(payload.get("links", {}), dict) else None
        if nxt is not None and (not isinstance(nxt, str) or not nxt.startswith("https://api.appstoreconnect.apple.com/")):
            raise MonitorError("App Store Connect returned unsafe pagination link")
        url = nxt
    return items

def attr(item, kind):
    if not isinstance(item, dict) or not isinstance(item.get("id"), str) or not isinstance(item.get("attributes"), dict):
        raise MonitorError(f"App Store Connect returned malformed {kind}")
    return item["id"], item["attributes"]

def resolve(fetch, version, build):
    target = cycle(version, build)
    q = urllib.parse.urlencode({"filter[bundleId]": BUNDLE_ID, "fields[apps]": "bundleId", "limit": "50"})
    apps = [x for x in page_items(fetch, "https://api.appstoreconnect.apple.com/v1/apps?" + q)
            if attr(x, "app")[1].get("bundleId") == BUNDLE_ID]
    if len(apps) != 1: raise MonitorError("Exact app identity is absent or ambiguous")
    app_id, _ = attr(apps[0], "app")
    q = urllib.parse.urlencode({"filter[app]": app_id, "filter[versionString]": version,
                                "fields[appStoreVersions]": "versionString,appStoreState,platform", "limit": "50"})
    versions = []
    for item in page_items(fetch, "https://api.appstoreconnect.apple.com/v1/appStoreVersions?" + q):
        _, attributes = attr(item, "app store version")
        if attributes.get("versionString") == version: versions.append(item)
    if len(versions) != 1: raise MonitorError("Exact marketing version is absent, ambiguous, or superseded")
    version_id, attributes = attr(versions[0], "app store version")
    build_item = fetch(f"https://api.appstoreconnect.apple.com/v1/appStoreVersions/{version_id}/build?fields[builds]=version,expired")
    data = build_item.get("data") if isinstance(build_item, dict) else None
    if data is None: raise MonitorError("Exact version has no bound build")
    _, build_attrs = attr(data, "bound build")
    if build_attrs.get("version") != build or build_attrs.get("expired") is True:
        raise MonitorError("Exact build is absent, mismatched, expired, or superseded")
    return observation(target["version"], target["build"], attributes.get("appStoreState"))

def redact(text):
    # Bounded, ASCII-only diagnostics cannot carry server payloads or credentials.
    return re.sub(r"[^A-Za-z0-9 .,:()/-]", "?", str(text))[:180]

def state_document(entries):
    return "<!-- asc-review-monitor-state " + json.dumps({"v": 1, "cycles": entries}, separators=(",", ":"), sort_keys=True) + " -->"

def parse_state(body):
    marker = re.search(r"<!-- asc-review-monitor-state ([^\n]{1,12000}) -->", body or "")
    if not marker: return []
    try: value = json.loads(marker.group(1))
    except json.JSONDecodeError: return []
    rows = value.get("cycles") if isinstance(value, dict) and value.get("v") == 1 else None
    if not isinstance(rows, list): return []
    valid = []
    for row in rows:
        if not isinstance(row, dict): continue
        try:
            c = cycle(row.get("version"), row.get("build"))
            status = row.get("status")
            if isinstance(status, str) and status in SAFE_STATES | {"UNKNOWN"}:
                valid.append({"version": c["version"], "build": c["build"], "status": status})
        except MonitorError: pass
    return valid[-MAX_CYCLES:]

def update_dedup(entries, obs, rearm=False):
    key = (obs["cycle"]["version"], obs["cycle"]["build"])
    prior = next((x for x in entries if (x["version"], x["build"]) == key), None)
    changed = rearm or prior is None or prior["status"] != obs["state"]
    entries = [x for x in entries if (x["version"], x["build"]) != key]
    entries.append({"version": key[0], "build": key[1], "status": obs["state"]})
    return entries[-MAX_CYCLES:], changed

def jwt():
    key_id, issuer, private = (os.environ.get(x, "") for x in ("ASC_REVIEW_MONITOR_KEY_ID", "ASC_REVIEW_MONITOR_ISSUER_ID", "ASC_REVIEW_MONITOR_PRIVATE_KEY"))
    if not all((key_id, issuer, private)): raise MonitorError("Review monitor credential is not configured")
    def enc(v): return base64.urlsafe_b64encode(v).rstrip(b"=").decode()
    header = enc(json.dumps({"alg":"ES256","kid":key_id,"typ":"JWT"}, separators=(",", ":")).encode())
    payload = enc(json.dumps({"iss":issuer,"iat":int(time.time()),"exp":int(time.time())+600,"aud":"appstoreconnect-v1"}, separators=(",", ":")).encode())
    signing = f"{header}.{payload}"
    key_path = Path(os.environ["RUNNER_TEMP"]) / "asc-review-monitor-key.p8"
    sig_path = Path(os.environ["RUNNER_TEMP"]) / "asc-review-monitor-signature.bin"
    key_path.write_text(private, encoding="utf-8"); os.chmod(key_path, 0o600)
    try:
        subprocess.run(["openssl","dgst","-sha256","-sign",str(key_path),"-out",str(sig_path)], input=signing.encode(), check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        der = sig_path.read_bytes(); p=2
        if not der or der[0] != 0x30: raise ValueError()
        def integer():
            nonlocal p
            if der[p] != 2: raise ValueError()
            p += 1; length=der[p]; p += 1; raw=der[p:p+length]; p += length
            raw=(raw.lstrip(b"\0") or b"\0")
            if len(raw)>32: raise ValueError()
            return raw.rjust(32,b"\0")
        raw=integer()+integer()
        return signing+"."+enc(raw)
    except Exception: raise MonitorError("Review monitor credential could not sign a request")
    finally:
        key_path.unlink(missing_ok=True); sig_path.unlink(missing_ok=True)

def asc_fetch(token):
    def fetch(url):
        request=urllib.request.Request(url, method="GET", headers={"Authorization":"Bearer "+token, "Accept":"application/json"})
        try:
            with urllib.request.urlopen(request, timeout=30) as response: return json.loads(response.read())
        except Exception: raise MonitorError("App Store Connect read request failed")
    return fetch

def gh(method, path, payload=None):
    token=os.environ.get("GH_TOKEN", "")
    if not token: raise MonitorError("GitHub notification token is unavailable")
    req=urllib.request.Request("https://api.github.com"+path, data=(json.dumps(payload).encode() if payload else None), method=method,
        headers={"Authorization":"Bearer "+token,"Accept":"application/vnd.github+json","X-GitHub-Api-Version":"2022-11-28"})
    with urllib.request.urlopen(req, timeout=30) as r: return json.loads(r.read())

def notify(obs, rearm):
    repo=os.environ.get("GITHUB_REPOSITORY", "")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo): raise MonitorError("GitHub repository identity is invalid")
    issues=gh("GET", f"/repos/{repo}/issues?state=open&per_page=100")
    matches=[x for x in issues if isinstance(x,dict) and x.get("title")==ISSUE_TITLE and "pull_request" not in x]
    if len(matches)>1: raise MonitorError("Notification state issue is ambiguous")
    if matches: issue=matches[0]
    else: issue=gh("POST", f"/repos/{repo}/issues", {"title":ISSUE_TITLE,"body":state_document([])})
    entries, changed=update_dedup(parse_state(issue.get("body")),obs,rearm)
    number=issue.get("number")
    gh("PATCH", f"/repos/{repo}/issues/{number}", {"body":state_document(entries)})
    if changed:
        c=obs["cycle"]
        message=f"Review status changed: version {c['version']}, build {c['build']}, {obs['category']} ({obs['state']})."
        gh("POST", f"/repos/{repo}/issues/{number}/comments", {"body":message})
    return changed

def main():
    p=argparse.ArgumentParser(); p.add_argument("--version", required=True); p.add_argument("--build", required=True); p.add_argument("--rearm", action="store_true"); args=p.parse_args()
    try:
        obs=resolve(asc_fetch(jwt()), args.version, args.build)
        changed=notify(obs,args.rearm)
        print(f"ASC_REVIEW_MONITOR version={obs['cycle']['version']} build={obs['cycle']['build']} category={obs['category']} state={obs['state']} notification={'sent' if changed else 'deduplicated'}")
    except MonitorError as e:
        print("ASC_REVIEW_MONITOR " + redact(e), file=sys.stderr); return 1
    except Exception:
        # Do not turn HTTP bodies, headers, or tracebacks into runner output.
        print("ASC_REVIEW_MONITOR unexpected monitor failure", file=sys.stderr); return 1
    return 0
if __name__ == "__main__": sys.exit(main())
