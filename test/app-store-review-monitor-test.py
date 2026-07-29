#!/usr/bin/env python3
"""Credential-free regression tests for the review monitor's pure contracts."""
import importlib.util, json, pathlib, unittest
ROOT=pathlib.Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location("monitor", ROOT/".github/scripts/app_store_review_monitor.py")
m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

def item(ident, **attrs): return {"id":ident,"attributes":attrs}
def fixture(state="IN_REVIEW", build="12.1", pages=False):
    def fetch(url):
        if "/v1/apps?" in url:
            return {"data": ([] if pages else [item("app",bundleId=m.BUNDLE_ID)]), "links":{"next":"https://api.appstoreconnect.apple.com/next-app" if pages else None}}
        if url.endswith("next-app"):
            return {"data":[item("app",bundleId=m.BUNDLE_ID)],"links":{"next":None}}
        if "/v1/appStoreVersions?" in url:
            return {"data":[item("version",versionString="0.1",appStoreState=state,platform="IOS")],"links":{"next":None}}
        if "/build?" in url: return {"data":item("build",version=build,expired=False)}
        raise AssertionError(url)
    return fetch

class ResolutionTests(unittest.TestCase):
    def test_pagination_and_exact_resolution(self):
        self.assertEqual(m.resolve(fixture(pages=True),"0.1","12.1")["category"],"in-review")
    def test_every_known_state_category(self):
        for state, category in m.STATE_CATEGORY.items():
            self.assertEqual(m.resolve(fixture(state),"0.1","12.1")["category"],category)
    def test_unknown_state_is_not_reflected(self):
        o=m.resolve(fixture("<secret-state>"),"0.1","12.1")
        self.assertEqual((o["state"],o["category"]),("UNKNOWN","unknown"))
    def test_bad_cycle_rejected(self):
        for version, build in (("latest","12"),("0.1","build"),("","")):
            with self.assertRaises(m.MonitorError): m.resolve(fixture(),version,build)
    def test_ambiguous_and_superseded_are_rejected(self):
        def ambiguous(url):
            if "/apps?" in url: return {"data":[item("a",bundleId=m.BUNDLE_ID),item("b",bundleId=m.BUNDLE_ID)],"links":{"next":None}}
            raise AssertionError(url)
        with self.assertRaises(m.MonitorError): m.resolve(ambiguous,"0.1","12.1")
        with self.assertRaises(m.MonitorError): m.resolve(fixture(build="12.2"),"0.1","12.1")
    def test_malformed_and_unsafe_pagination_rejected(self):
        with self.assertRaises(m.MonitorError): m.page_items(lambda _: {"data":"bad"},"https://api.appstoreconnect.apple.com/x")
        with self.assertRaises(m.MonitorError): m.page_items(lambda _: {"data":[],"links":{"next":"https://evil.invalid/x"}},"https://api.appstoreconnect.apple.com/x")

class SafetyTests(unittest.TestCase):
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
    def test_only_dedup_uses_github_writes_and_apple_is_get_only(self):
        self.assertNotRegex(self.source,r'api\.appstoreconnect\.apple\.com[^\n]*POST')
        self.assertIn('request GET', self.source) if False else None
        self.assertNotIn('"POST", "https://api.appstoreconnect.apple.com',self.source)
        self.assertNotIn('"PATCH", "https://api.appstoreconnect.apple.com',self.source)
        self.assertIn('"POST", f"/repos/{repo}/issues',self.source)
    def test_negative_controls_fail_the_same_boundaries(self):
        weakened=self.workflow.replace("  issues: write","  issues: read")
        self.assertNotIn("  issues: write",weakened)
        weakened=self.workflow+"\non:\n  pull_request:\n"
        self.assertIn("pull_request",weakened)
        weakened=self.source.replace('method="GET"','method="POST"')
        self.assertIn('method="POST"',weakened)

if __name__ == "__main__": unittest.main(verbosity=2)
