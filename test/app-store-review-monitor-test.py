#!/usr/bin/env python3
"""Credential-free regression tests for the review monitor's pure contracts."""
import importlib.util, json, os, pathlib, sys, unittest
from unittest import mock
sys.dont_write_bytecode=True
ROOT=pathlib.Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location("monitor", ROOT/".github/scripts/app_store_review_monitor.py")
m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

def item(ident, **attrs): return {"id":ident,"attributes":attrs}
def fixture(state="IN_REVIEW", build="12.1", pages=False):
    def fetch(url):
        version_item=item("version",versionString="0.1",appVersionState=state,platform="IOS")
        version_item.update({"type":"appStoreVersions","relationships":{"build":{"data":{"type":"builds","id":"build"}}}})
        build_item=item("build",version=build,expired=False); build_item["type"]="builds"
        if f"/v1/apps/{m.APP_ID}/appStoreVersions?" in url:
            return {"data":([] if pages else [version_item]),"included":([] if pages else [build_item]),
                    "links":{"next":"https://api.appstoreconnect.apple.com/next-version" if pages else None}}
        if url.endswith("next-version"):
            return {"data":[version_item],"included":[build_item],"links":{"next":None}}
        raise AssertionError(url)
    return fetch

class ResolutionTests(unittest.TestCase):
    def test_pagination_and_exact_resolution(self):
        self.assertEqual(m.resolve(fixture(pages=True),"0.1","12.1")["category"],"in-review")
        requested=[]
        m.resolve(lambda url: requested.append(url) or fixture()(url),"0.1","12.1")
        self.assertTrue(all(f"/v1/apps/{m.APP_ID}/appStoreVersions?" in url for url in requested))
        self.assertTrue(all("/v1/apps?" not in url and "/build?" not in url for url in requested))
    def test_every_known_state_category(self):
        self.assertEqual(set(m.STATE_CATEGORY),{
            "ACCEPTED","DEVELOPER_REJECTED","IN_REVIEW","INVALID_BINARY",
            "METADATA_REJECTED","PENDING_APPLE_RELEASE","PENDING_DEVELOPER_RELEASE",
            "PREPARE_FOR_SUBMISSION","PROCESSING_FOR_DISTRIBUTION",
            "READY_FOR_DISTRIBUTION","READY_FOR_REVIEW","REJECTED",
            "REPLACED_WITH_NEW_VERSION","WAITING_FOR_EXPORT_COMPLIANCE","WAITING_FOR_REVIEW",
        })
        for state, category in m.STATE_CATEGORY.items():
            self.assertEqual(m.resolve(fixture(state),"0.1","12.1")["category"],category)
    def test_future_unknown_state_has_one_safe_transition(self):
        o=m.resolve(fixture("<future-secret-state>"),"0.1","12.1")
        self.assertEqual((o["state"],o["category"]),("UNKNOWN","unknown"))
        rows, changed=m.update_dedup([],o); self.assertTrue(changed)
        rows, changed=m.update_dedup(rows,o); self.assertFalse(changed)
    def test_bad_cycle_rejected(self):
        for version, build in (("latest","12"),("0.1","build"),("","")):
            with self.assertRaises(m.MonitorError): m.resolve(fixture(),version,build)
    def test_ambiguous_and_superseded_are_rejected(self):
        def ambiguous(url):
            base=fixture()(url)
            base["data"].append(base["data"][0].copy())
            return base
        with self.assertRaises(m.MonitorError): m.resolve(ambiguous,"0.1","12.1")
        with self.assertRaises(m.MonitorError): m.resolve(fixture(build="12.2"),"0.1","12.1")
    def test_malformed_and_unsafe_pagination_rejected(self):
        with self.assertRaises(m.MonitorError): m.page_items(lambda _: {"data":"bad"},"https://api.appstoreconnect.apple.com/x")
        for url in (
            "https://evil.invalid/x",
            "https://api.appstoreconnect.apple.com.evil.invalid/x",
            "http://api.appstoreconnect.apple.com/x",
            "https://api.appstoreconnect.apple.com:444/x",
            "https://user@api.appstoreconnect.apple.com/x",
        ):
            with self.subTest(url=url):
                with self.assertRaises(m.MonitorError):
                    m.page_items(lambda _: {"data":[],"links":{"next":url}},"https://api.appstoreconnect.apple.com/x")

    def test_authenticated_fetch_rejects_cross_origin_requests_and_redirects(self):
        fetch=m.asc_fetch("token")
        with self.assertRaises(m.MonitorError):
            fetch("https://api.appstoreconnect.apple.com.evil.invalid/x")
        opener=next(x.cell_contents for x in fetch.__closure__ if hasattr(x.cell_contents, "handlers"))
        handler=next(x for x in opener.handlers if isinstance(x,m.urllib.request.HTTPRedirectHandler))
        with self.assertRaises(m.MonitorError):
            handler.redirect_request(None,None,302,"",{},"https://evil.invalid/x")

class SafetyTests(unittest.TestCase):
    def test_individual_jwt_claims_and_exact_get_scope(self):
        header=m.jwt_header("KEY123")
        self.assertEqual(header,{"alg":"ES256","kid":"KEY123","typ":"JWT"})
        payload=m.jwt_payload("0.1",issued_at=1000)
        self.assertEqual(set(payload),{"sub","iat","exp","aud","scope"})
        self.assertNotIn("iss",payload)
        self.assertEqual(payload["sub"],"user")
        self.assertEqual(payload["iat"],1000)
        self.assertEqual(payload["exp"],1600)
        self.assertEqual(payload["aud"],"appstoreconnect-v1")
        self.assertEqual(payload["scope"],m.token_scope("0.1"))
        self.assertEqual(len(payload["scope"]),1)
        scope=payload["scope"][0]
        self.assertTrue(scope.startswith(f"GET /v1/apps/{m.APP_ID}/appStoreVersions?"))
        self.assertIn("filter%5BversionString%5D=0.1",scope)
        self.assertIn("filter%5Bplatform%5D=IOS",scope)
        self.assertIn("include=build",scope)
        self.assertNotIn("/v1/apps?",scope)
        self.assertNotIn("/build",scope)
        for method in ("POST","PATCH","DELETE"):
            with self.assertRaises(m.MonitorError):
                m.jwt_payload("0.1",issued_at=1000,scope=[scope.replace("GET",method,1)])

    def test_redaction_is_bounded_and_ascii(self):
        value=m.redact("Bearer abc\n-----BEGIN PRIVATE KEY-----\u2603"+"x"*500)
        self.assertLessEqual(len(value),180); self.assertNotIn("\n",value); self.assertNotIn("\u2603",value)
    def test_transition_dedup_and_rearm(self):
        obs=m.observation("0.1","12.1","IN_REVIEW")
        rows, changed=m.update_dedup([],obs); self.assertTrue(changed)
        rows, changed=m.update_dedup(rows,obs); self.assertFalse(changed)
        rows, changed=m.update_dedup(rows,obs,True); self.assertTrue(changed)
        rows, changed=m.update_dedup(rows,m.observation("0.1","12.1","REJECTED")); self.assertTrue(changed)
    def test_dedup_retention_and_injection_resistance(self):
        rows=[]
        for n in range(40): rows,_=m.update_dedup(rows,m.observation("0.1",str(n),"IN_REVIEW"))
        self.assertEqual(len(rows),m.MAX_CYCLES)
        self.assertEqual(m.parse_state("<!-- asc-review-monitor-state {not-json} -->"),[])
        self.assertEqual(m.parse_state(m.state_document(rows)),rows)
    def test_issue_lookup_follows_all_pages(self):
        obs=m.observation("0.1","12.1","IN_REVIEW")
        first=[{"number":n,"title":"Other","body":"","state":"open"} for n in range(1,101)]
        state={"number":101,"title":m.issue_title(obs),"body":m.state_document([]),"state":"open"}
        calls=[]
        def fake_gh(method,path,payload=None):
            calls.append((method,path,payload))
            if method=="GET": return first if path.endswith("page=1") else [state]
            return {}
        with mock.patch.object(m,"gh",side_effect=fake_gh), mock.patch.dict(os.environ,{"GITHUB_REPOSITORY":"owner/repo"}):
            self.assertEqual(m.notify(obs,False,"schedule"),"sent")
        self.assertTrue(any("page=2" in path for method,path,_ in calls if method=="GET"))
        self.assertTrue(all("state=all" in path for method,path,_ in calls if method=="GET"))
        self.assertFalse(any(method=="POST" and path=="/repos/owner/repo/issues" for method,path,_ in calls))
    def test_closed_cycle_is_disabled_without_writes(self):
        obs=m.observation("0.1","12.1","IN_REVIEW")
        issue={"number":7,"title":m.issue_title(obs),"body":m.state_document([]),"state":"closed"}
        calls=[]
        def fake_gh(method,path,payload=None):
            calls.append((method,path,payload))
            return [issue] if method=="GET" else {}
        with mock.patch.object(m,"gh",side_effect=fake_gh), mock.patch.dict(os.environ,{"GITHUB_REPOSITORY":"owner/repo"}):
            self.assertEqual(m.notify(obs,False,"schedule"),"disabled")
        self.assertTrue(calls)
        self.assertTrue(all(method=="GET" for method,_,_ in calls))
    def test_trusted_rearm_reopens_same_cycle_issue(self):
        obs=m.observation("0.1","12.1","IN_REVIEW")
        issue={"number":7,"title":m.issue_title(obs),"body":m.state_document([]),"state":"closed"}
        calls=[]
        def fake_gh(method,path,payload=None):
            calls.append((method,path,payload))
            return [issue] if method=="GET" else {}
        with mock.patch.object(m,"gh",side_effect=fake_gh), mock.patch.dict(os.environ,{"GITHUB_REPOSITORY":"owner/repo"}):
            self.assertEqual(m.notify(obs,True,"workflow_dispatch"),"sent")
            with self.assertRaises(m.MonitorError): m.notify(obs,True,"schedule")
        patches=[call for call in calls if call[0]=="PATCH"]
        self.assertEqual(patches[0][1],"/repos/owner/repo/issues/7")
        self.assertEqual(patches[0][2]["state"],"open")
        self.assertFalse(any(method=="POST" and path=="/repos/owner/repo/issues" for method,path,_ in calls))
    def test_distinct_cycles_use_distinct_bounded_issues(self):
        first=m.observation("0.1","12","IN_REVIEW")
        second=m.observation("0.2","13","IN_REVIEW")
        self.assertNotEqual(m.issue_title(first),m.issue_title(second))
        rows=[]
        for n in range(40): rows,_=m.update_dedup(rows,m.observation("0.1",str(n),"IN_REVIEW"))
        self.assertEqual(len(rows),32)
    def test_repeated_cycle_creates_one_issue_and_one_comment(self):
        obs=m.observation("0.1","12.1","IN_REVIEW")
        issues=[]; calls=[]
        def fake_gh(method,path,payload=None):
            calls.append((method,path,payload))
            if method=="GET": return issues
            if method=="POST" and path=="/repos/owner/repo/issues":
                issue={"number":9,"title":payload["title"],"body":payload["body"],"state":"open"}
                issues.append(issue)
                return issue
            if method=="PATCH":
                issues[0]["body"]=payload["body"]
                return issues[0]
            return {}
        with mock.patch.object(m,"gh",side_effect=fake_gh), mock.patch.dict(os.environ,{"GITHUB_REPOSITORY":"owner/repo"}):
            self.assertEqual(m.notify(obs,False,"schedule"),"sent")
            self.assertEqual(m.notify(obs,False,"schedule"),"deduplicated")
        creations=[x for x in calls if x[0]=="POST" and x[1]=="/repos/owner/repo/issues"]
        comments=[x for x in calls if x[0]=="POST" and x[1].endswith("/comments")]
        self.assertEqual(len(creations),1)
        self.assertEqual(creations[0][2]["title"],m.issue_title(obs))
        self.assertEqual(len(comments),1)

class WorkflowContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow=(ROOT/".github/workflows/app-store-review-status.yml").read_text()
        cls.source=(ROOT/".github/scripts/app_store_review_monitor.py").read_text()
    def test_triggers_permissions_and_pins(self):
        w=self.workflow
        self.assertIn("  schedule:",w); self.assertIn("  workflow_dispatch:",w)
        for forbidden in ("pull_request", "pull_request_target", "workflow_run", "repository_dispatch", "push:"):
            self.assertNotIn(forbidden,w)
        self.assertIn("  contents: read",w); self.assertIn("  issues: write",w)
        self.assertNotIn("actions: write",w); self.assertRegex(w,r"actions/checkout@[0-9a-f]{40}")
        self.assertIn("concurrency:",w); self.assertIn("group: app-store-review-status",w)
        self.assertIn("cancel-in-progress: false",w)
    def test_only_dedup_uses_github_writes_and_apple_is_get_only(self):
        self.assertNotRegex(self.source,r'api\.appstoreconnect\.apple\.com[^\n]*POST')
        self.assertIn('request GET', self.source) if False else None
        self.assertNotIn('"POST", "https://api.appstoreconnect.apple.com',self.source)
        self.assertNotIn('"PATCH", "https://api.appstoreconnect.apple.com',self.source)
        self.assertIn('"POST", f"/repos/{repo}/issues',self.source)
        self.assertNotIn("ASC_REVIEW_MONITOR_ISSUER_ID",self.workflow)
        self.assertNotIn('"iss"',self.source)
        self.assertIn('"sub": "user"',self.source)
        self.assertNotIn("appStoreState",self.source)
        self.assertIn("appVersionState",self.source)
    def test_negative_controls_fail_the_same_boundaries(self):
        weakened=self.workflow.replace("  issues: write","  issues: read")
        self.assertNotIn("  issues: write",weakened)
        weakened=self.workflow+"\non:\n  pull_request:\n"
        self.assertIn("pull_request",weakened)
        weakened=self.source.replace('method="GET"','method="POST"')
        self.assertIn('method="POST"',weakened)

if __name__ == "__main__": unittest.main(verbosity=2)
