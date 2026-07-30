#!/usr/bin/env python3
"""Read-only, exact-cycle App Store review monitor and bounded GitHub deduplicator."""
import argparse, base64, json, os, re, subprocess, sys, time, urllib.parse, urllib.request
from pathlib import Path

BUNDLE_ID = "com.kunchenguid.eddieswallet"
APP_ID = "6795664301"
ASC_HOST = "api.appstoreconnect.apple.com"
MAX_CYCLES = 32
VERSION_RE = re.compile(r"^[0-9]+(?:\.[0-9]+){1,2}$")
BUILD_RE = re.compile(r"^[0-9]+(?:\.[0-9]+){0,2}$")
STATE_CATEGORY = {
    "PREPARE_FOR_SUBMISSION": "not-submitted", "READY_FOR_REVIEW": "ready-for-review",
    "WAITING_FOR_REVIEW": "waiting-for-review", "IN_REVIEW": "in-review",
    "PENDING_DEVELOPER_RELEASE": "approved", "PENDING_APPLE_RELEASE": "approved",
    "ACCEPTED": "approved", "PROCESSING_FOR_DISTRIBUTION": "approved",
    "READY_FOR_DISTRIBUTION": "approved", "REJECTED": "action-required",
    "METADATA_REJECTED": "action-required", "INVALID_BINARY": "action-required",
    "WAITING_FOR_EXPORT_COMPLIANCE": "action-required", "DEVELOPER_REJECTED": "withdrawn",
    "REPLACED_WITH_NEW_VERSION": "superseded",
}
SAFE_STATES = set(STATE_CATEGORY)
ISSUE_TITLE_PREFIX = "App Store review monitor state"

class MonitorError(Exception): pass

def cycle(version, build):
    if not VERSION_RE.fullmatch(version or "") or not BUILD_RE.fullmatch(build or ""):
        raise MonitorError("Cycle must use a numeric marketing version and build number")
    return {"appId": APP_ID, "bundleId": BUNDLE_ID, "version": version, "build": build}

def safe_state(value):
    return value if value in SAFE_STATES else "UNKNOWN"

def observation(version, build, state):
    state = safe_state(state)
    return {"cycle": cycle(version, build), "state": state, "category": STATE_CATEGORY.get(state, "unknown")}

def issue_title(obs):
    c = obs["cycle"]
    return f"{ISSUE_TITLE_PREFIX}: version {c['version']}, build {c['build']}"

def validate_asc_url(url):
    if not isinstance(url, str):
        raise MonitorError("App Store Connect returned unsafe URL")
    try:
        parsed = urllib.parse.urlsplit(url)
        port = parsed.port
    except ValueError:
        raise MonitorError("App Store Connect returned unsafe URL")
    if parsed.scheme != "https" or parsed.hostname != ASC_HOST or port not in (None, 443) or parsed.username or parsed.password:
        raise MonitorError("App Store Connect returned unsafe URL")
    return url

def page_payloads(fetch, url):
    seen = set()
    while url:
        validate_asc_url(url)
        if url in seen: raise MonitorError("App Store Connect pagination loop")
        seen.add(url)
        payload = fetch(url)
        data = payload.get("data") if isinstance(payload, dict) else None
        if not isinstance(data, list): raise MonitorError("App Store Connect returned malformed collection")
        yield payload
        nxt = payload.get("links", {}).get("next") if isinstance(payload.get("links", {}), dict) else None
        if nxt is not None: validate_asc_url(nxt)
        url = nxt

def page_items(fetch, url):
    items = []
    for payload in page_payloads(fetch, url):
        items.extend(payload["data"])
    return items

def attr(item, kind):
    if not isinstance(item, dict) or not isinstance(item.get("id"), str) or not isinstance(item.get("attributes"), dict):
        raise MonitorError(f"App Store Connect returned malformed {kind}")
    return item["id"], item["attributes"]

def version_url(version):
    if not VERSION_RE.fullmatch(version or ""):
        raise MonitorError("Cycle must use a numeric marketing version and build number")
    q = urllib.parse.urlencode({
        "filter[versionString]": version,
        "filter[platform]": "IOS",
        "fields[appStoreVersions]": "versionString,appVersionState,platform,build",
        "include": "build",
        "fields[builds]": "version,expired",
        "limit": "50",
    })
    return f"https://{ASC_HOST}/v1/apps/{APP_ID}/appStoreVersions?{q}"

def token_scope(version):
    parsed = urllib.parse.urlsplit(version_url(version))
    return [f"GET {parsed.path}?{parsed.query}"]

def validate_scope(scope, version):
    if not isinstance(scope, list) or scope != token_scope(version) or any(not value.startswith("GET /") for value in scope):
        raise MonitorError("Review monitor token scope is invalid")
    return scope

def jwt_header(key_id):
    return {"alg": "ES256", "kid": key_id, "typ": "JWT"}

def jwt_payload(version, issued_at=None, scope=None):
    now = int(time.time()) if issued_at is None else issued_at
    selected_scope = token_scope(version) if scope is None else scope
    validate_scope(selected_scope, version)
    return {"sub": "user", "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1", "scope": selected_scope}

def resolve(fetch, version, build):
    target = cycle(version, build)
    versions = []
    builds = {}
    for payload in page_payloads(fetch, version_url(version)):
        included = payload.get("included", [])
        if not isinstance(included, list): raise MonitorError("App Store Connect returned malformed included resources")
        for resource in included:
            if not isinstance(resource, dict) or resource.get("type") != "builds":
                raise MonitorError("App Store Connect returned unexpected included resource")
            build_id, build_attrs = attr(resource, "bound build")
            if build_id in builds: raise MonitorError("Exact build is ambiguous")
            builds[build_id] = build_attrs
        for item in payload["data"]:
            if not isinstance(item, dict) or item.get("type") != "appStoreVersions":
                raise MonitorError("App Store Connect returned malformed app store version")
            _, attributes = attr(item, "app store version")
            if attributes.get("versionString") == version and attributes.get("platform") == "IOS":
                versions.append(item)
    if len(versions) != 1: raise MonitorError("Exact marketing version is absent, ambiguous, or superseded")
    _, attributes = attr(versions[0], "app store version")
    relationships = versions[0].get("relationships")
    linkage = relationships.get("build", {}).get("data") if isinstance(relationships, dict) else None
    if not isinstance(linkage, dict) or linkage.get("type") != "builds" or not isinstance(linkage.get("id"), str):
        raise MonitorError("Exact version has no bound build")
    build_attrs = builds.get(linkage["id"])
    if build_attrs is None or build_attrs.get("version") != build or build_attrs.get("expired") is not False:
        raise MonitorError("Exact build is absent, mismatched, expired, or superseded")
    return observation(target["version"], target["build"], attributes.get("appVersionState"))

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

def jwt(version):
    key_id, private = (os.environ.get(x, "") for x in ("ASC_REVIEW_MONITOR_KEY_ID", "ASC_REVIEW_MONITOR_PRIVATE_KEY"))
    if not all((key_id, private)): raise MonitorError("Review monitor credential is not configured")
    def enc(v): return base64.urlsafe_b64encode(v).rstrip(b"=").decode()
    header = enc(json.dumps(jwt_header(key_id), separators=(",", ":")).encode())
    payload = enc(json.dumps(jwt_payload(version), separators=(",", ":")).encode())
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
    class SameOriginRedirectHandler(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, req, fp, code, msg, headers, newurl):
            validate_asc_url(newurl)
            return super().redirect_request(req, fp, code, msg, headers, newurl)
    opener = urllib.request.build_opener(SameOriginRedirectHandler)
    def fetch(url):
        validate_asc_url(url)
        request=urllib.request.Request(url, method="GET", headers={"Authorization":"Bearer "+token, "Accept":"application/json"})
        try:
            with opener.open(request, timeout=30) as response: return json.loads(response.read())
        except MonitorError: raise
        except Exception: raise MonitorError("App Store Connect read request failed")
    return fetch

def gh(method, path, payload=None):
    token=os.environ.get("GH_TOKEN", "")
    if not token: raise MonitorError("GitHub notification token is unavailable")
    req=urllib.request.Request("https://api.github.com"+path, data=(json.dumps(payload).encode() if payload else None), method=method,
        headers={"Authorization":"Bearer "+token,"Accept":"application/vnd.github+json","X-GitHub-Api-Version":"2022-11-28"})
    with urllib.request.urlopen(req, timeout=30) as r: return json.loads(r.read())

def notify(obs, rearm, event_name):
    if rearm and event_name != "workflow_dispatch":
        raise MonitorError("Review monitor rearm requires trusted manual dispatch")
    repo=os.environ.get("GITHUB_REPOSITORY", "")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo): raise MonitorError("GitHub repository identity is invalid")
    issues, page = [], 1
    while True:
        batch=gh("GET", f"/repos/{repo}/issues?state=all&per_page=100&page={page}")
        if not isinstance(batch, list): raise MonitorError("GitHub returned malformed issue collection")
        issues.extend(batch)
        if len(batch) < 100: break
        page += 1
    title = issue_title(obs)
    matches=[x for x in issues if isinstance(x,dict) and x.get("title")==title and "pull_request" not in x]
    if len(matches)>1: raise MonitorError("Notification state issue is ambiguous")
    issue = matches[0] if matches else None
    if issue is not None and issue.get("state") == "closed" and not rearm:
        return "disabled"
    if issue is not None and issue.get("state") not in ("open", "closed"):
        raise MonitorError("Notification state issue is malformed")
    entries, changed=update_dedup(parse_state(issue.get("body") if issue else ""),obs,rearm)
    body = state_document(entries)
    if issue is None:
        issue=gh("POST", f"/repos/{repo}/issues", {"title":title,"body":body})
    else:
        payload = {"body": body}
        if issue.get("state") == "closed": payload["state"] = "open"
        gh("PATCH", f"/repos/{repo}/issues/{issue.get('number')}", payload)
    number=issue.get("number")
    if not isinstance(number, int): raise MonitorError("Notification state issue is malformed")
    if changed:
        c=obs["cycle"]
        message=f"Review status changed: version {c['version']}, build {c['build']}, {obs['category']} ({obs['state']})."
        gh("POST", f"/repos/{repo}/issues/{number}/comments", {"body":message})
        return "sent"
    return "deduplicated"

def main():
    p=argparse.ArgumentParser(); p.add_argument("--version", required=True); p.add_argument("--build", required=True); p.add_argument("--rearm", action="store_true"); args=p.parse_args()
    try:
        if args.rearm and os.environ.get("GITHUB_EVENT_NAME") != "workflow_dispatch":
            raise MonitorError("Review monitor rearm requires trusted manual dispatch")
        obs=resolve(asc_fetch(jwt(args.version)), args.version, args.build)
        outcome=notify(obs,args.rearm,os.environ.get("GITHUB_EVENT_NAME", ""))
        print(f"ASC_REVIEW_MONITOR version={obs['cycle']['version']} build={obs['cycle']['build']} category={obs['category']} state={obs['state']} notification={outcome}")
    except MonitorError as e:
        print("ASC_REVIEW_MONITOR " + redact(e), file=sys.stderr); return 1
    except Exception:
        # Do not turn HTTP bodies, headers, or tracebacks into runner output.
        print("ASC_REVIEW_MONITOR unexpected monitor failure", file=sys.stderr); return 1
    return 0
if __name__ == "__main__": sys.exit(main())
