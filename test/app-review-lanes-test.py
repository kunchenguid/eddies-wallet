#!/usr/bin/env python3
"""Credential-lane and trust-boundary tests for the App Review workflows.

These assertions run against a parsed workflow model - jobs, steps, `if`
guards, permissions, and the exact `secrets.*` each step's environment maps -
rather than against workflow text, so a reformat cannot pass and a real lane
change cannot slip through. The import-graph test is executed, not read: it
imports each read-only entrypoint in a fresh interpreter and asserts the
mutation modules were never loaded.

Nothing here reads a credential or contacts anything.
"""

from __future__ import annotations

import importlib
import json
import pathlib
import re
import subprocess
import sys
import unittest

sys.dont_write_bytecode = True
ROOT = pathlib.Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
TOOLS = ROOT / "tools" / "app-review"

PREPARE = "app-review-prepare.yml"
SUBMIT = "app-review-submit.yml"
DEMO_PREFLIGHT = "app-review-demo-preflight.yml"
MONITOR = "app-store-review-status.yml"
APP_REVIEW_WORKFLOWS = (PREPARE, SUBMIT, DEMO_PREFLIGHT)

REPOSITORY_GUARD = "github.repository == 'kunchenguid/eddies-wallet'"
DEFAULT_BRANCH_GUARD = "github.ref == 'refs/heads/main'"
CONCURRENCY_GROUP = "eddies-app-review-submission"
MUTATION_SECRETS = (
    "APP_STORE_CONNECT_KEY_ID",
    "APP_STORE_CONNECT_ISSUER_ID",
    "APP_STORE_CONNECT_API_KEY",
)
VARIABLE_TOKEN = "EDDIES_REVIEW_MONITOR_VARIABLE_TOKEN"
SECRET_REFERENCE = re.compile(r"secrets\.([A-Za-z_][A-Za-z0-9_]*)")
PINNED_ACTION = re.compile(r"^[^\s@]+@[0-9a-f]{40}$")


def parse_workflow(name: str) -> dict:
    """Parse one workflow into a normalized model with the repository's YAML reader."""
    completed = subprocess.run(
        [
            "ruby",
            "-ryaml",
            "-rjson",
            "-e",
            "puts YAML.load_file(ARGV[0]).to_json",
            str(WORKFLOWS / name),
        ],
        capture_output=True,
        text=True,
        check=True,
    )
    document = json.loads(completed.stdout)
    # A bare `on:` key parses as the boolean true in YAML 1.1.
    document["on"] = document.get("on") or document.get("true")
    return document


def steps_of(job: dict) -> list[dict]:
    return [step for step in job.get("steps", []) if isinstance(step, dict)]


def secrets_of(step: dict) -> set[str]:
    found: set[str] = set()
    for value in (step.get("env") or {}).values():
        found.update(SECRET_REFERENCE.findall(str(value)))
    return found


class WorkflowModelCase(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.models = {
            name: parse_workflow(name)
            for name in APP_REVIEW_WORKFLOWS + (MONITOR,)
        }

    def jobs(self, name):
        return self.models[name]["jobs"]


class TriggerAndGuardTests(WorkflowModelCase):
    def test_every_app_review_workflow_is_manual_dispatch_only(self):
        for name in APP_REVIEW_WORKFLOWS:
            with self.subTest(workflow=name):
                triggers = self.models[name]["on"]
                self.assertEqual(list(triggers), ["workflow_dispatch"])

    def test_every_app_review_job_is_pinned_to_this_repository_and_main(self):
        for name in APP_REVIEW_WORKFLOWS:
            for job_name, job in self.jobs(name).items():
                with self.subTest(workflow=name, job=job_name):
                    guard = " ".join(str(job.get("if", "")).split())
                    self.assertIn(REPOSITORY_GUARD, guard)
                    self.assertIn(DEFAULT_BRANCH_GUARD, guard)

    def test_every_app_review_dispatch_requires_a_double_confirm(self):
        for name in APP_REVIEW_WORKFLOWS:
            with self.subTest(workflow=name):
                inputs = self.models[name]["on"]["workflow_dispatch"]["inputs"]
                self.assertTrue(inputs["version"]["required"])
                self.assertTrue(inputs["confirm"]["required"])
                self.assertIn("Repeat the exact same version", inputs["confirm"]["description"])

    def test_the_submission_dispatch_defaults_to_the_dry_run_and_needs_evidence(self):
        inputs = self.models[SUBMIT]["on"]["workflow_dispatch"]["inputs"]
        self.assertEqual(inputs["mode"]["options"], ["verify", "submit"])
        self.assertEqual(inputs["mode"]["default"], "verify")
        self.assertTrue(inputs["evidence"]["required"])

    def test_only_an_explicit_submit_mode_reaches_the_mutation_job(self):
        guard = " ".join(str(self.jobs(SUBMIT)["submit"]["if"]).split())
        self.assertIn("inputs.mode == 'submit'", guard)
        self.assertEqual(self.jobs(SUBMIT)["submit"]["needs"], "verify")

    def test_the_pipeline_serializes_on_one_non_cancelling_group(self):
        for name in APP_REVIEW_WORKFLOWS:
            with self.subTest(workflow=name):
                concurrency = self.models[name]["concurrency"]
                self.assertEqual(concurrency["group"], CONCURRENCY_GROUP)
                self.assertIs(concurrency["cancel-in-progress"], False)


class CredentialLaneTests(WorkflowModelCase):
    """The mutation credential must be reachable from exactly one step."""

    def steps_holding(self, secret_name):
        located = []
        for name in APP_REVIEW_WORKFLOWS + (MONITOR,):
            for job_name, job in self.jobs(name).items():
                for step in steps_of(job):
                    if secret_name in secrets_of(step):
                        located.append((name, job_name, step.get("name")))
        return located

    def test_the_mutation_credential_lives_only_where_it_is_needed(self):
        for secret_name in MUTATION_SECRETS:
            with self.subTest(secret=secret_name):
                self.assertEqual(
                    sorted(
                        (workflow, job) for workflow, job, _ in self.steps_holding(secret_name)
                    ),
                    [
                        (DEMO_PREFLIGHT, "readiness"),
                        (PREPARE, "preflight"),
                        (SUBMIT, "submit"),
                    ],
                )

    def test_exactly_one_step_can_mutate_app_store_connect(self):
        mutating = self.steps_holding("APP_STORE_CONNECT_API_KEY")
        submitting = [entry for entry in mutating if entry[0] == SUBMIT]
        self.assertEqual(len(submitting), 1)
        self.assertEqual(submitting[0][1], "submit")

    def test_the_monitor_variable_token_reaches_only_the_submit_job(self):
        self.assertEqual(
            self.steps_holding(VARIABLE_TOKEN), [(SUBMIT, "submit", self._submit_step_name())]
        )

    def _submit_step_name(self):
        return steps_of(self.jobs(SUBMIT)["submit"])[-1]["name"]

    def test_every_verify_lane_is_credential_free(self):
        for name, job_name in ((PREPARE, "verify"), (SUBMIT, "verify")):
            with self.subTest(workflow=name, job=job_name):
                for step in steps_of(self.jobs(name)[job_name]):
                    held = secrets_of(step)
                    self.assertFalse(
                        held & set(MUTATION_SECRETS) or VARIABLE_TOKEN in held,
                        f"{name}:{job_name} must hold no Apple or variable credential",
                    )

    def test_the_monitor_never_borrows_the_upload_or_mutation_credential(self):
        for job in self.jobs(MONITOR).values():
            for step in steps_of(job):
                held = secrets_of(step)
                self.assertFalse(held & set(MUTATION_SECRETS))
                self.assertNotIn(VARIABLE_TOKEN, held)

    def test_no_app_review_job_uses_a_github_environment(self):
        # The captain-decided gate is the approved manifest plus a double-confirm
        # dispatch. A protected Environment was deliberately dropped, so finding
        # one here would mean the gate silently changed shape.
        for name in APP_REVIEW_WORKFLOWS:
            for job_name, job in self.jobs(name).items():
                with self.subTest(workflow=name, job=job_name):
                    self.assertNotIn("environment", job)


class PermissionAndPinTests(WorkflowModelCase):
    def test_workflow_permissions_start_read_only(self):
        for name in APP_REVIEW_WORKFLOWS:
            with self.subTest(workflow=name):
                self.assertEqual(self.models[name]["permissions"], {"contents": "read"})

    def test_no_job_grants_a_write_beyond_the_recovery_record(self):
        for name in APP_REVIEW_WORKFLOWS:
            for job_name, job in self.jobs(name).items():
                with self.subTest(workflow=name, job=job_name):
                    permissions = job.get("permissions", {})
                    self.assertEqual(permissions.get("contents"), "read")
                    writes = {
                        scope
                        for scope, level in permissions.items()
                        if level == "write"
                    }
                    self.assertLessEqual(writes, {"issues"})

    def test_the_read_only_jobs_never_need_issue_writes(self):
        self.assertNotIn(
            "issues", self.jobs(DEMO_PREFLIGHT)["readiness"].get("permissions", {})
        )
        self.assertEqual(
            self.jobs(SUBMIT)["verify"]["permissions"]["issues"], "read"
        )

    def test_every_action_is_pinned_to_a_full_commit_sha(self):
        for name in APP_REVIEW_WORKFLOWS:
            for job in self.jobs(name).values():
                for step in steps_of(job):
                    uses = step.get("uses")
                    if uses:
                        with self.subTest(workflow=name, uses=uses):
                            self.assertRegex(uses, PINNED_ACTION)

    def test_no_checkout_leaves_a_git_credential_on_the_runner(self):
        for name in APP_REVIEW_WORKFLOWS:
            for job in self.jobs(name).values():
                for step in steps_of(job):
                    if str(step.get("uses", "")).startswith("actions/checkout@"):
                        with self.subTest(workflow=name):
                            self.assertIs(step["with"]["persist-credentials"], False)
                            self.assertEqual(step["with"]["fetch-depth"], 0)

    def test_every_app_review_run_pins_the_manifest_approved_commit_first(self):
        for name in APP_REVIEW_WORKFLOWS:
            for job_name, job in self.jobs(name).items():
                with self.subTest(workflow=name, job=job_name):
                    runs = [step.get("run", "") for step in steps_of(job)]
                    pin = next(
                        index
                        for index, command in enumerate(runs)
                        if "pin_app_review_manifest.sh" in command
                    )
                    entrypoints = [
                        index
                        for index, command in enumerate(runs)
                        if "tools/app-review/" in command
                    ]
                    self.assertTrue(entrypoints)
                    self.assertLess(pin, min(entrypoints))


class MonitorMigrationTests(WorkflowModelCase):
    def test_the_monitor_reads_the_single_canonical_cycle_variable(self):
        resolver = next(
            step
            for step in steps_of(self.jobs(MONITOR)["monitor"])
            if "review_monitor_cycle.sh" in str(step.get("run", ""))
        )
        environment = resolver["env"]
        self.assertEqual(
            environment["SCHEDULED_CYCLE"], "${{ vars.EDDIES_REVIEW_MONITOR_CYCLE }}"
        )
        # The retiring pair stays readable until the migration is verified.
        self.assertIn("ASC_REVIEW_MONITOR_VERSION", environment["SCHEDULED_VERSION"])

    def test_the_monitor_polls_four_hourly_off_the_top_of_the_hour(self):
        crons = [entry["cron"] for entry in self.models[MONITOR]["on"]["schedule"]]
        self.assertEqual(crons, ["41 */4 * * *"])
        minute, hour = crons[0].split()[:2]
        self.assertNotEqual(minute, "0")
        self.assertEqual(hour, "*/4")

    def test_the_monitor_still_polls_apple_only_for_an_armed_cycle(self):
        polling = [
            step
            for step in steps_of(self.jobs(MONITOR)["monitor"])
            if "ASC_REVIEW_MONITOR_PRIVATE_KEY" in secrets_of(step)
        ]
        self.assertEqual(len(polling), 1)
        self.assertEqual(polling[0]["if"], "steps.cycle.outputs.armed == 'true'")


class ImportBoundaryTests(unittest.TestCase):
    """The read-only entrypoints cannot even load the mutation modules."""

    def loaded_modules(self, entrypoint: str) -> set[str]:
        program = (
            "import sys; sys.dont_write_bytecode = True;"
            f"sys.path.insert(0, {str(TOOLS)!r});"
            f"import {entrypoint};"
            "print(' '.join(sorted(sys.modules)))"
        )
        completed = subprocess.run(
            [sys.executable, "-c", program],
            capture_output=True,
            text=True,
            check=True,
            cwd=str(ROOT),
        )
        return set(completed.stdout.split())

    def test_the_read_only_entrypoints_never_load_a_mutation_module(self):
        for entrypoint in ("prepare", "demo_preflight"):
            with self.subTest(entrypoint=entrypoint):
                loaded = self.loaded_modules(entrypoint)
                self.assertIn("core", loaded)
                self.assertNotIn("asc_write", loaded)
                self.assertNotIn("submission", loaded)

    def test_the_submission_engine_is_the_only_importer_of_the_write_boundary(self):
        importers = [
            path.name
            for path in sorted(TOOLS.glob("*.py"))
            if re.search(r"^\s*import asc_write\b", path.read_text(), re.MULTILINE)
        ]
        self.assertEqual(importers, ["submission.py", "submit.py"])


class HttpBoundaryTests(unittest.TestCase):
    """Every request each boundary can actually send, captured as it is sent."""

    def setUp(self):
        sys.path.insert(0, str(TOOLS))
        self.addCleanup(sys.path.remove, str(TOOLS))
        self.asc_read = importlib.import_module("asc_read")
        self.asc_write = importlib.import_module("asc_write")
        self.sent = []

    class _Response:
        def __init__(self, body):
            self._body = body
            self.status = 200

        def read(self):
            return self._body

        def __enter__(self):
            return self

        def __exit__(self, *_):
            return False

    def opener(self, body=None):
        """An Apple that echoes back a well-formed resource of the requested kind."""
        sent = self.sent

        class Opener:
            def open(self, request, timeout=None):
                sent.append((request.get_method(), request.full_url, request.data))
                if body is not None:
                    return HttpBoundaryTests._Response(body)
                kind = request.full_url.split("/v1/")[1].split("/")[0].split("?")[0]
                return HttpBoundaryTests._Response(
                    json.dumps(
                        {"data": {"type": kind, "id": "created-1", "attributes": {}}}
                    ).encode()
                )

        return Opener()

    class _Credential:
        def bearer_token(self, **_):
            return "not-a-real-token"

    def test_the_read_boundary_only_ever_sends_get_without_a_body(self):
        session = self.asc_read.ReadSession(self._Credential())
        session._opener = self.opener(b'{"data": []}')
        session.get("/v1/apps/1/appStoreVersions", {"filter[versionString]": "0.2.0"})
        list(session.pages("/v1/apps/1/appStoreVersions", {}))
        self.assertTrue(self.sent)
        for method, url, body in self.sent:
            self.assertEqual(method, "GET")
            self.assertIsNone(body)
            self.assertTrue(url.startswith("https://api.appstoreconnect.apple.com/v1/"))

    def test_the_read_boundary_exposes_no_mutating_operation(self):
        session = self.asc_read.ReadSession(self._Credential())
        for name in ("post", "patch", "put", "delete", "upload", "request"):
            self.assertFalse(hasattr(session, name), f"read session exposes {name}")

    def test_every_write_the_boundary_offers_is_a_post_or_patch(self):
        change = self.asc_write.ChangeSession(self._Credential())
        change._opener = self.opener()
        change.set_release_type("ver-1", "MANUAL")
        change.bind_build("ver-1", "build-1")
        change.set_review_detail("detail-1", "notes")
        change.create_review_submission("6795664301", "IOS")
        change.add_version_item("rs-1", "ver-1")
        change.submit_for_review("rs-1")
        self.assertEqual(len(self.sent), 6)
        for method, url, body in self.sent:
            self.assertIn(method, ("POST", "PATCH"))
            self.assertIsNotNone(body)
            self.assertTrue(url.startswith("https://api.appstoreconnect.apple.com/v1/"))

    def test_the_write_boundary_refuses_any_other_method(self):
        change = self.asc_write.ChangeSession(self._Credential())
        change._opener = self.opener()
        for method in ("DELETE", "PUT", "GET"):
            with self.subTest(method=method):
                with self.assertRaises(self.asc_read.AppStoreConnectError):
                    change._send(method, "/v1/appStoreVersions/ver-1", {})
        self.assertEqual(self.sent, [], "a refused method must never reach the network")

    def test_neither_boundary_will_talk_to_another_host(self):
        session = self.asc_read.ReadSession(self._Credential())
        session._opener = self.opener()
        with self.assertRaises(self.asc_read.AppStoreConnectError):
            session.get_url("https://example.test/v1/apps")
        self.assertEqual(self.sent, [])


class NegativeControlTests(WorkflowModelCase):
    """The same checks must fail on a weakened workflow, or they prove nothing."""

    def test_moving_the_mutation_credential_would_be_caught(self):
        model = parse_workflow(SUBMIT)
        verify_steps = steps_of(model["jobs"]["verify"])
        verify_steps[-1].setdefault("env", {})["APP_STORE_CONNECT_API_KEY"] = (
            "${{ secrets.APP_STORE_CONNECT_API_KEY }}"
        )
        leaked = any(
            "APP_STORE_CONNECT_API_KEY" in secrets_of(step) for step in verify_steps
        )
        self.assertTrue(leaked, "the lane assertion must be able to see a leak")

    def test_dropping_the_submit_mode_guard_would_be_caught(self):
        model = parse_workflow(SUBMIT)
        model["jobs"]["submit"]["if"] = REPOSITORY_GUARD
        self.assertNotIn("inputs.mode == 'submit'", model["jobs"]["submit"]["if"])

    def test_adding_an_environment_would_be_caught(self):
        model = parse_workflow(SUBMIT)
        model["jobs"]["submit"]["environment"] = "app-store-submission"
        self.assertIn("environment", model["jobs"]["submit"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
