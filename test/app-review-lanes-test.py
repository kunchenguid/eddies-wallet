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
EULA_APPEND = "app-review-eula-append.yml"
MONITOR = "app-review-monitor.yml"
MONITOR_E2E = "app-review-monitor-e2e.yml"
LIST_VERSIONS = "app-review-list-versions.yml"
LIST_APP_INFO = "app-review-list-app-info.yml"
APP_REVIEW_WORKFLOWS = (PREPARE, SUBMIT, DEMO_PREFLIGHT)
MODELED_WORKFLOWS = APP_REVIEW_WORKFLOWS + (
    MONITOR,
    MONITOR_E2E,
    EULA_APPEND,
    LIST_VERSIONS,
    LIST_APP_INFO,
)
SHARED_TOOL_PIN = "216a65513dbde70d04d0efd021792743f094ed77"
FIXED_MONITOR_ENGINE_SHA = "216a65513dbde70d04d0efd021792743f094ed77"
SUBMIT_ENGINE_PIN = "4e4638568bc74f4689c812a9b6a76edd4e438095"
SCREENSHOT_UPLOAD_ENGINE_ARGV = ["node", "app_review_pipeline.js", "upload-screenshots"]
SHARED_TOOL_REPO = "kunchenguid/app-review-submit"
MONITOR_CONFIG = TOOLS / "app-review.config.json"
OBSERVE_HARNESS = "tools/app-review/observe_review_status.js"

REPOSITORY_GUARD = "github.repository == 'kunchenguid/eddies-wallet'"
DEFAULT_BRANCH_GUARD = "github.ref == 'refs/heads/main'"
CONCURRENCY_GROUP = "eddies-app-review-submission"
MONITOR_CONCURRENCY_GROUP = "eddies-app-review-monitor"
MUTATION_SECRETS = (
    "APP_STORE_CONNECT_KEY_ID",
    "APP_STORE_CONNECT_ISSUER_ID",
    "APP_STORE_CONNECT_API_KEY",
)
VARIABLE_TOKEN = "EDDIES_REVIEW_MONITOR_VARIABLE_TOKEN"
MONITOR_VARIABLE_TOKEN = "APP_REVIEW_MONITOR_VARIABLE_TOKEN"
SHARED_TOOL_READ_TOKEN = "APP_REVIEW_SUBMIT_READ_TOKEN"
SECRET_REFERENCE = re.compile(r"secrets\.([A-Za-z_][A-Za-z0-9_]*)")
VAR_REFERENCE = re.compile(r"vars\.([A-Za-z_][A-Za-z0-9_]*)")
PINNED_ACTION = re.compile(r"^[^\s@]+@[0-9a-f]{40}$")
DEDICATED_MONITOR_SECRET = re.compile(r"ASC_REVIEW_MONITOR_")


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


def with_secrets_of(step: dict) -> set[str]:
    found: set[str] = set()
    for value in (step.get("with") or {}).values():
        found.update(SECRET_REFERENCE.findall(str(value)))
    return found


class WorkflowModelCase(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.models = {
            name: parse_workflow(name)
            for name in MODELED_WORKFLOWS
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
        self.assertEqual(inputs["mode"]["options"], ["verify", "assemble", "upload", "submit"])
        self.assertEqual(inputs["mode"]["default"], "verify")
        self.assertTrue(inputs["evidence"]["required"])

    def test_only_an_explicit_assemble_upload_or_submit_mode_reaches_its_mutation_job(self):
        assemble = " ".join(str(self.jobs(SUBMIT)["assemble"]["if"]).split())
        upload = " ".join(str(self.jobs(SUBMIT)["upload"]["if"]).split())
        submit = " ".join(str(self.jobs(SUBMIT)["submit"]["if"]).split())
        self.assertIn("inputs.mode == 'assemble'", assemble)
        self.assertNotIn("inputs.mode == 'submit'", assemble)
        self.assertNotIn("inputs.mode == 'upload'", assemble)
        self.assertIn("inputs.mode == 'upload'", upload)
        self.assertNotIn("inputs.mode == 'assemble'", upload)
        self.assertNotIn("inputs.mode == 'submit'", upload)
        self.assertIn("inputs.mode == 'submit'", submit)
        self.assertNotIn("inputs.mode == 'assemble'", submit)
        self.assertNotIn("inputs.mode == 'upload'", submit)
        self.assertEqual(self.jobs(SUBMIT)["assemble"]["needs"], "verify")
        self.assertEqual(self.jobs(SUBMIT)["upload"]["needs"], "verify")
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
        for name in MODELED_WORKFLOWS:
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
                        (EULA_APPEND, "append"),
                        (LIST_APP_INFO, "list"),
                        (LIST_VERSIONS, "list"),
                        (MONITOR_E2E, "observe"),
                        (MONITOR, "observe"),
                        (PREPARE, "preflight"),
                        (SUBMIT, "assemble"),
                        (SUBMIT, "submit"),
                        (SUBMIT, "upload"),
                    ],
                )

    def test_exactly_three_submit_workflow_steps_can_mutate_app_store_connect(self):
        mutating = self.steps_holding("APP_STORE_CONNECT_API_KEY")
        holders = sorted(job for workflow, job, _ in mutating if workflow == SUBMIT)
        self.assertEqual(holders, ["assemble", "submit", "upload"])

    def test_the_legacy_monitor_variable_token_is_never_mapped(self):
        self.assertEqual(self.steps_holding(VARIABLE_TOKEN), [])

    def test_the_monitor_variable_token_reaches_only_the_gated_submit_job(self):
        holders = [
            (workflow, job)
            for workflow, job, _ in self.steps_holding(MONITOR_VARIABLE_TOKEN)
        ]
        self.assertEqual(holders, [(SUBMIT, "submit")])
        for job_name in ("assemble", "upload"):
            for step in steps_of(self.jobs(SUBMIT)[job_name]):
                self.assertNotIn(MONITOR_VARIABLE_TOKEN, secrets_of(step))

    def test_every_verify_lane_is_credential_free(self):
        for name, job_name in ((PREPARE, "verify"), (SUBMIT, "verify")):
            with self.subTest(workflow=name, job=job_name):
                for step in steps_of(self.jobs(name)[job_name]):
                    held = secrets_of(step)
                    self.assertFalse(
                        held & set(MUTATION_SECRETS)
                        or VARIABLE_TOKEN in held
                        or MONITOR_VARIABLE_TOKEN in held,
                        f"{name}:{job_name} must hold no Apple or variable credential",
                    )

    def test_the_monitor_reuses_the_submit_key_and_never_a_dedicated_credential(self):
        polling = [
            step
            for step in steps_of(self.jobs(MONITOR)["observe"])
            if "APP_STORE_CONNECT_API_KEY" in secrets_of(step)
        ]
        self.assertEqual(len(polling), 1)
        held = secrets_of(polling[0])
        self.assertEqual(held, set(MUTATION_SECRETS))
        self.assertNotIn(VARIABLE_TOKEN, held)
        self.assertNotIn(MONITOR_VARIABLE_TOKEN, held)
        self.assertNotIn(SHARED_TOOL_READ_TOKEN, held)
        for job in self.jobs(MONITOR).values():
            for step in steps_of(job):
                blob = json.dumps(step)
                self.assertIsNone(DEDICATED_MONITOR_SECRET.search(blob))
                self.assertNotIn(MONITOR_VARIABLE_TOKEN, secrets_of(step))
                self.assertNotIn(VARIABLE_TOKEN, secrets_of(step))
                self.assertNotIn(SHARED_TOOL_READ_TOKEN, secrets_of(step))

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
        self.assertNotIn(
            "issues", self.jobs(SUBMIT)["assemble"].get("permissions", {})
        )
        self.assertNotIn(
            "issues", self.jobs(SUBMIT)["upload"].get("permissions", {})
        )
        self.assertNotIn(
            "issues", self.jobs(SUBMIT)["submit"].get("permissions", {})
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
                            if (step.get("with") or {}).get("repository") == SHARED_TOOL_REPO:
                                self.assertNotIn("fetch-depth", step.get("with") or {})
                            else:
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

    def test_demo_preflight_restores_its_reader_from_dispatch_after_pinning(self):
        steps = steps_of(self.jobs(DEMO_PREFLIGHT)["readiness"])
        pin = next(
            index
            for index, step in enumerate(steps)
            if "pin_app_review_manifest.sh" in step.get("run", "")
        )
        restore = next(
            index
            for index, step in enumerate(steps)
            if step.get("env", {}).get("DISPATCH_SHA") == "${{ github.sha }}"
        )
        read = next(
            index
            for index, step in enumerate(steps)
            if step.get("run", "").strip()
            == "python3 tools/app-review/demo_preflight.py"
        )
        self.assertLess(pin, restore)
        self.assertLess(restore, read)
        self.assertEqual(
            steps[restore]["run"].strip().splitlines(),
            [
                'git show "${DISPATCH_SHA}:tools/app-review/demo_preflight.py" > tools/app-review/demo_preflight.py',
                'git show "${DISPATCH_SHA}:tools/app-review/content.py" > tools/app-review/content.py',
            ],
        )


class SharedMonitorTests(WorkflowModelCase):
    """The scheduled monitor is the pinned shared GET-only tool, not the old dedicated-key poll."""

    def test_the_monitor_is_a_trusted_default_branch_schedule_or_dispatch(self):
        triggers = self.models[MONITOR]["on"]
        self.assertEqual(set(triggers), {"schedule", "workflow_dispatch"})
        crons = [entry["cron"] for entry in triggers["schedule"]]
        self.assertEqual(crons, ["41 */4 * * *"])
        minute, hour = crons[0].split()[:2]
        self.assertNotEqual(minute, "0")
        self.assertEqual(hour, "*/4")
        self.assertEqual(
            self.models[MONITOR]["permissions"],
            {"contents": "read", "issues": "write"},
        )
        concurrency = self.models[MONITOR]["concurrency"]
        self.assertEqual(concurrency["group"], MONITOR_CONCURRENCY_GROUP)
        self.assertIs(concurrency["cancel-in-progress"], False)
        guard = " ".join(str(self.jobs(MONITOR)["observe"].get("if", "")).split())
        self.assertIn(REPOSITORY_GUARD, guard)
        self.assertIn(DEFAULT_BRANCH_GUARD, guard)

    def test_the_monitor_checks_out_the_pinned_shared_tool(self):
        checkouts = [
            step
            for step in steps_of(self.jobs(MONITOR)["observe"])
            if str(step.get("uses", "")).startswith("actions/checkout@")
        ]
        self.assertEqual(len(checkouts), 2)
        for step in checkouts:
            self.assertRegex(step["uses"], PINNED_ACTION)
            self.assertIs(step["with"]["persist-credentials"], False)
        tool = next(
            step
            for step in checkouts
            if (step.get("with") or {}).get("repository") == SHARED_TOOL_REPO
        )
        self.assertEqual(tool["with"]["ref"], SHARED_TOOL_PIN)
        self.assertEqual(tool["with"]["path"], ".app-review-submit")
        self.assertEqual(
            tool["with"]["token"],
            "${{ secrets.APP_REVIEW_SUBMIT_READ_TOKEN }}",
        )
        local = next(
            step
            for step in checkouts
            if (step.get("with") or {}).get("repository") != SHARED_TOOL_REPO
        )
        self.assertNotIn("token", local.get("with") or {})
        self.assertNotIn(SHARED_TOOL_READ_TOKEN, with_secrets_of(local))

    def test_the_shared_tool_read_token_reaches_only_the_private_checkout(self):
        located = []
        for name in MODELED_WORKFLOWS:
            for job_name, job in self.jobs(name).items():
                for step in steps_of(job):
                    if SHARED_TOOL_READ_TOKEN in secrets_of(step):
                        located.append((name, job_name, step.get("name"), "env"))
                    if SHARED_TOOL_READ_TOKEN in with_secrets_of(step):
                        located.append((name, job_name, step.get("name"), "with"))
        self.assertEqual(
            located,
            [
                (
                    SUBMIT,
                    "assemble",
                    "Check out the shared review-submission CLI",
                    "with",
                ),
                (
                    SUBMIT,
                    "upload",
                    "Check out the shared review-submission CLI",
                    "with",
                ),
                (
                    SUBMIT,
                    "submit",
                    "Check out the shared review-submission CLI",
                    "with",
                ),
                (
                    MONITOR,
                    "observe",
                    "Check out the shared review-submission CLI",
                    "with",
                ),
                (
                    MONITOR_E2E,
                    "observe",
                    "Check out the shared review-submission CLI",
                    "with",
                ),
            ],
        )

    def test_the_monitor_runs_the_shared_get_only_command(self):
        polling = [
            step
            for step in steps_of(self.jobs(MONITOR)["observe"])
            if "app_review_pipeline.js" in str(step.get("run", ""))
        ]
        self.assertEqual(len(polling), 1)
        command = polling[0]["run"]
        self.assertIn("app_review_pipeline.js monitor", command)
        self.assertNotIn("app_review_pipeline.js submit", command)
        environment = polling[0]["env"]
        self.assertEqual(
            environment["APP_REVIEW_CONFIG"],
            "${{ github.workspace }}/tools/app-review/app-review.config.json",
        )
        self.assertEqual(
            environment["APP_REVIEW_MONITOR_VERSION"],
            "${{ vars.APP_REVIEW_MONITOR_VERSION }}",
        )
        self.assertEqual(
            VAR_REFERENCE.findall(json.dumps(environment)),
            ["APP_REVIEW_MONITOR_VERSION"],
        )
        self.assertEqual(
            {name: environment[name] for name in MUTATION_SECRETS},
            {
                "APP_STORE_CONNECT_KEY_ID": "${{ secrets.APP_STORE_CONNECT_KEY_ID }}",
                "APP_STORE_CONNECT_ISSUER_ID": "${{ secrets.APP_STORE_CONNECT_ISSUER_ID }}",
                "APP_STORE_CONNECT_API_KEY": "${{ secrets.APP_STORE_CONNECT_API_KEY }}",
            },
        )

    def test_the_committed_config_is_the_eddie_monitor_consumer(self):
        config = json.loads(MONITOR_CONFIG.read_text())
        self.assertEqual(config["app"]["appId"], "6795664301")
        self.assertEqual(config["app"]["bundleId"], "com.kunchenguid.eddieswallet")
        self.assertEqual(config["github"]["repository"], "kunchenguid/eddies-wallet")
        self.assertEqual(config["monitor"]["variableName"], "APP_REVIEW_MONITOR_VERSION")
        self.assertEqual(
            config["monitor"]["recordMarkerPrefix"], "eddies-app-review-monitor"
        )
        self.assertEqual(config["env"]["monitorVariableToken"], MONITOR_VARIABLE_TOKEN)
        self.assertEqual(config["credentials"]["jwtStyle"], "team")
        self.assertEqual(config["listingPolicy"], "observe")
        blob = json.dumps(config)
        self.assertIsNone(DEDICATED_MONITOR_SECRET.search(blob))
        self.assertNotIn("EDDIES_REVIEW_MONITOR_CYCLE", blob)


class AssembleEngineTests(WorkflowModelCase):
    """The mutating submit workflow is Node assemble-only plus a gated full-submit adapter."""

    def _shared_tool_checkout(self, job_name):
        checkouts = [
            step
            for step in steps_of(self.jobs(SUBMIT)[job_name])
            if str(step.get("uses", "")).startswith("actions/checkout@")
        ]
        self.assertEqual(len(checkouts), 2)
        for step in checkouts:
            self.assertRegex(step["uses"], PINNED_ACTION)
            self.assertIs(step["with"]["persist-credentials"], False)
        tool = next(
            step
            for step in checkouts
            if (step.get("with") or {}).get("repository") == SHARED_TOOL_REPO
        )
        self.assertEqual(tool["with"]["ref"], SUBMIT_ENGINE_PIN)
        self.assertEqual(tool["with"]["path"], ".app-review-submit")
        self.assertEqual(
            tool["with"]["token"],
            "${{ secrets.APP_REVIEW_SUBMIT_READ_TOKEN }}",
        )
        local = next(
            step
            for step in checkouts
            if (step.get("with") or {}).get("repository") != SHARED_TOOL_REPO
        )
        self.assertEqual(local["with"]["fetch-depth"], 0)
        self.assertNotIn("token", local.get("with") or {})

    def test_assemble_checks_out_the_pinned_shared_tool(self):
        self._shared_tool_checkout("assemble")

    def test_upload_checks_out_the_pinned_shared_tool(self):
        self._shared_tool_checkout("upload")

    def test_submit_checks_out_the_pinned_shared_tool(self):
        self._shared_tool_checkout("submit")

    def test_assemble_runs_the_node_adapter_with_assemble_only(self):
        mutating = [
            step
            for step in steps_of(self.jobs(SUBMIT)["assemble"])
            if "APP_STORE_CONNECT_API_KEY" in secrets_of(step)
        ]
        self.assertEqual(len(mutating), 1)
        command = mutating[0]["run"]
        self.assertIn("assemble_only.js --assemble-only --first-release", command)
        self.assertNotIn("full_submit.js", command)
        self.assertNotIn("app_review_pipeline.js submit", command)
        self.assertNotIn("submit.py", command)
        self.assertNotIn("python3 tools/app-review/submit.py", command)
        environment = mutating[0]["env"]
        self.assertEqual(
            environment["APP_REVIEW_CONFIG"],
            "${{ github.workspace }}/tools/app-review/app-review.config.json",
        )
        self.assertEqual(
            environment["APP_REVIEW_ENGINE_DIR"],
            "${{ github.workspace }}/.app-review-submit",
        )
        self.assertNotIn("GITHUB_TOKEN", environment)
        self.assertNotIn(VARIABLE_TOKEN, secrets_of(mutating[0]))
        self.assertNotIn(MONITOR_VARIABLE_TOKEN, secrets_of(mutating[0]))
        self.assertEqual(
            {name: environment[name] for name in MUTATION_SECRETS},
            {
                "APP_STORE_CONNECT_KEY_ID": "${{ secrets.APP_STORE_CONNECT_KEY_ID }}",
                "APP_STORE_CONNECT_ISSUER_ID": "${{ secrets.APP_STORE_CONNECT_ISSUER_ID }}",
                "APP_STORE_CONNECT_API_KEY": "${{ secrets.APP_STORE_CONNECT_API_KEY }}",
            },
        )

    def test_upload_runs_the_parameterized_adapter_and_never_submits(self):
        mutating = [
            step
            for step in steps_of(self.jobs(SUBMIT)["upload"])
            if "APP_STORE_CONNECT_API_KEY" in secrets_of(step)
        ]
        self.assertEqual(len(mutating), 1)
        command = mutating[0]["run"]
        self.assertIn("upload_screenshots.js --upload-screenshots --first-release", command)
        self.assertNotIn("--submit", command)
        self.assertNotIn("full_submit.js", command)
        self.assertNotIn("assemble_only.js --assemble-only", command)
        self.assertNotIn("app_review_pipeline.js submit", command)
        environment = mutating[0]["env"]
        self.assertEqual(
            json.loads(environment["SCREENSHOT_UPLOAD_ENGINE_ARGV"]),
            SCREENSHOT_UPLOAD_ENGINE_ARGV,
        )
        self.assertNotIn("GITHUB_TOKEN", environment)
        self.assertNotIn(VARIABLE_TOKEN, secrets_of(mutating[0]))
        self.assertNotIn(MONITOR_VARIABLE_TOKEN, secrets_of(mutating[0]))
        self.assertEqual(
            {name: environment[name] for name in MUTATION_SECRETS},
            {
                "APP_STORE_CONNECT_KEY_ID": "${{ secrets.APP_STORE_CONNECT_KEY_ID }}",
                "APP_STORE_CONNECT_ISSUER_ID": "${{ secrets.APP_STORE_CONNECT_ISSUER_ID }}",
                "APP_STORE_CONNECT_API_KEY": "${{ secrets.APP_STORE_CONNECT_API_KEY }}",
            },
        )
        preflight = [
            step
            for step in steps_of(self.jobs(SUBMIT)["upload"])
            if str(step.get("run", "")).strip().startswith("python3 tools/app-review/screenshot_preflight.py")
        ]
        self.assertEqual(len(preflight), 1)
        self.assertFalse(secrets_of(preflight[0]) & set(MUTATION_SECRETS))

    def test_submit_runs_the_gated_full_submit_adapter(self):
        mutating = [
            step
            for step in steps_of(self.jobs(SUBMIT)["submit"])
            if "APP_STORE_CONNECT_API_KEY" in secrets_of(step)
        ]
        self.assertEqual(len(mutating), 1)
        command = mutating[0]["run"]
        self.assertIn("full_submit.js --submit --first-release", command)
        self.assertNotIn("assemble_only.js --assemble-only", command)
        self.assertNotIn("app_review_pipeline.js submit", command)
        self.assertNotIn("submit.py", command)
        environment = mutating[0]["env"]
        self.assertEqual(
            environment["APP_REVIEW_CONFIG"],
            "${{ github.workspace }}/tools/app-review/app-review.config.json",
        )
        self.assertEqual(
            environment["APP_REVIEW_ENGINE_DIR"],
            "${{ github.workspace }}/.app-review-submit",
        )
        self.assertNotIn("GITHUB_TOKEN", environment)
        self.assertNotIn(VARIABLE_TOKEN, secrets_of(mutating[0]))
        self.assertEqual(
            environment["APP_REVIEW_MONITOR_VARIABLE_TOKEN"],
            "${{ secrets.APP_REVIEW_MONITOR_VARIABLE_TOKEN }}",
        )
        self.assertEqual(
            {name: environment[name] for name in MUTATION_SECRETS},
            {
                "APP_STORE_CONNECT_KEY_ID": "${{ secrets.APP_STORE_CONNECT_KEY_ID }}",
                "APP_STORE_CONNECT_ISSUER_ID": "${{ secrets.APP_STORE_CONNECT_ISSUER_ID }}",
                "APP_STORE_CONNECT_API_KEY": "${{ secrets.APP_STORE_CONNECT_API_KEY }}",
            },
        )

    def test_assemble_upload_and_submit_restore_dispatch_sha_config_after_the_manifest_pin(self):
        for job_name, required in (
            ("assemble", ("assemble_only.js", "app-review.config.json")),
            (
                "upload",
                (
                    "assemble_only.js",
                    "upload_screenshots.js",
                    "screenshot_preflight.py",
                    "app-review.config.json",
                ),
            ),
            ("submit", ("assemble_only.js", "full_submit.js", "app-review.config.json")),
        ):
            with self.subTest(job=job_name):
                runs = [step.get("run", "") for step in steps_of(self.jobs(SUBMIT)[job_name])]
                pin = next(
                    index
                    for index, command in enumerate(runs)
                    if "pin_app_review_manifest.sh" in command
                )
                restore = next(
                    index
                    for index, command in enumerate(runs)
                    if "DISPATCH_SHA" in command or "github.sha" in command
                )
                self.assertLess(pin, restore)
                blob = runs[restore]
                for name in required:
                    self.assertIn(f"tools/app-review/{name}", blob)

    def test_full_submit_is_explicit_mode_not_the_default(self):
        blob = json.dumps(self.models[SUBMIT])
        self.assertNotIn("python3 tools/app-review/submit.py submit", blob)
        self.assertNotIn("app_review_pipeline.js submit", blob)
        self.assertIn("assemble_only.js --assemble-only", blob)
        self.assertIn("upload_screenshots.js", blob)
        self.assertIn("full_submit.js --submit --first-release", blob)
        inputs = self.models[SUBMIT]["on"]["workflow_dispatch"]["inputs"]
        self.assertEqual(inputs["mode"]["default"], "verify")
        self.assertIn("submit", inputs["mode"]["options"])

    def test_the_committed_config_names_eddie_and_both_cloud_subscriptions(self):
        config = json.loads(MONITOR_CONFIG.read_text())
        self.assertEqual(config["app"]["appId"], "6795664301")
        self.assertEqual(config["listingPolicy"], "observe")
        self.assertIs(config["listing"]["screenshotWrites"], True)
        self.assertNotIn("screenshots", config["listing"]["alignmentWrites"])
        self.assertEqual(config["commerce"]["kind"], "subscriptions")
        self.assertEqual(
            config["commerce"]["productIds"],
            [
                "com.kunchenguid.eddieswallet.cloud.monthly",
                "com.kunchenguid.eddieswallet.cloud.annual",
            ],
        )
        self.assertEqual(config["protected"]["primaryCategory"], "EDUCATION")
        self.assertEqual(config["protected"]["secondaryCategory"], "FINANCE")
        self.assertEqual(config["reviewDetails"]["copyright"], "© 2026 Kun Chen")
        listing = json.loads(
            (TOOLS / "manifests" / "0.1.17.json").read_text()
        )["content"]["listing"]
        self.assertIn(
            "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/",
            listing["description"],
        )
        self.assertEqual(listing["whatsNew"], "")
        self.assertEqual(config["listing"]["alignmentWrites"], ["releaseType", "build", "reviewNotes"])
        self.assertEqual(config["evidence"]["adapter"], "demoPreflight")
        self.assertEqual(config["listing"]["approvedSubtitle"], "Virtual allowance practice")
        self.assertEqual(config["reviewDetails"]["demoAccountRequired"], False)
        self.assertNotIn("demoAccountName", config["reviewDetails"])
        self.assertNotIn("demoAccountPassword", config["reviewDetails"])
        self.assertEqual(config["reviewDetails"]["contactFirstName"], "Kun")
        self.assertEqual(config["reviewDetails"]["contactLastName"], "Chen")
        self.assertEqual(config["reviewDetails"]["contactEmail"], "kun@kunchenguid.com")
        self.assertEqual(config["reviewDetails"]["contactPhone"], "4259992724")
        self.assertIn("Sign in with Apple", config["reviewDetails"]["notes"])
        blob = json.dumps(config["reviewDetails"])
        self.assertNotIn("demoAccountName", blob)
        self.assertNotIn("demoAccountPassword", blob)


class LiveMonitorProofTests(WorkflowModelCase):
    """The live E2E gate classifies real ASC state without writing an issue."""

    def test_the_proof_is_a_trusted_default_branch_dispatch(self):
        triggers = self.models[MONITOR_E2E]["on"]
        self.assertEqual(list(triggers), ["workflow_dispatch"])
        inputs = triggers["workflow_dispatch"]["inputs"]
        self.assertEqual(inputs["engine_sha"]["default"], FIXED_MONITOR_ENGINE_SHA)
        self.assertEqual(inputs["version"]["default"], "0.1.17")
        self.assertEqual(inputs["expected_outcome"]["default"], "rejected")
        self.assertEqual(
            inputs["expected_outcome"]["options"],
            ["rejected", "approved", "pending", "resolved_other", "unavailable"],
        )
        self.assertEqual(self.models[MONITOR_E2E]["permissions"], {"contents": "read"})
        concurrency = self.models[MONITOR_E2E]["concurrency"]
        self.assertEqual(concurrency["group"], "eddies-app-review-monitor-e2e")
        self.assertIs(concurrency["cancel-in-progress"], False)
        job = self.jobs(MONITOR_E2E)["observe"]
        guard = " ".join(str(job.get("if", "")).split())
        self.assertIn(REPOSITORY_GUARD, guard)
        self.assertIn(DEFAULT_BRANCH_GUARD, guard)
        self.assertEqual(job.get("permissions"), {"contents": "read"})
        self.assertNotIn("environment", job)
        self.assertNotIn("issues", job.get("permissions", {}))
        self.assertNotIn("issues", self.models[MONITOR_E2E]["permissions"])

    def test_the_proof_checks_out_the_requested_shared_tool_sha(self):
        checkouts = [
            step
            for step in steps_of(self.jobs(MONITOR_E2E)["observe"])
            if str(step.get("uses", "")).startswith("actions/checkout@")
        ]
        self.assertEqual(len(checkouts), 2)
        for step in checkouts:
            self.assertRegex(step["uses"], PINNED_ACTION)
            self.assertIs(step["with"]["persist-credentials"], False)
        tool = next(
            step
            for step in checkouts
            if (step.get("with") or {}).get("repository") == SHARED_TOOL_REPO
        )
        self.assertEqual(tool["with"]["ref"], "${{ inputs.engine_sha }}")
        self.assertEqual(tool["with"]["path"], ".app-review-submit")
        self.assertEqual(
            tool["with"]["token"],
            "${{ secrets.APP_REVIEW_SUBMIT_READ_TOKEN }}",
        )
        local = next(
            step
            for step in checkouts
            if (step.get("with") or {}).get("repository") != SHARED_TOOL_REPO
        )
        self.assertNotIn("token", local.get("with") or {})
        self.assertNotIn(SHARED_TOOL_READ_TOKEN, with_secrets_of(local))

    def test_the_proof_calls_observe_review_status_and_never_writes_an_issue(self):
        observe_steps = [
            step
            for step in steps_of(self.jobs(MONITOR_E2E)["observe"])
            if OBSERVE_HARNESS in str(step.get("run", ""))
        ]
        self.assertEqual(len(observe_steps), 1)
        command = observe_steps[0]["run"]
        self.assertIn("observe_review_status.js", command)
        self.assertNotIn("app_review_pipeline.js", command)
        self.assertNotIn(" runMonitor", command)
        environment = observe_steps[0]["env"]
        self.assertEqual(
            environment["APP_REVIEW_CONFIG"],
            "${{ github.workspace }}/tools/app-review/app-review.config.json",
        )
        self.assertEqual(
            environment["APP_REVIEW_ENGINE_DIR"],
            "${{ github.workspace }}/.app-review-submit",
        )
        self.assertEqual(environment["APP_REVIEW_ENGINE_SHA"], "${{ inputs.engine_sha }}")
        self.assertEqual(environment["APP_REVIEW_OBSERVE_VERSION"], "${{ inputs.version }}")
        self.assertEqual(
            environment["APP_REVIEW_OBSERVE_EXPECTED"],
            "${{ inputs.expected_outcome }}",
        )
        self.assertNotIn("GITHUB_TOKEN", environment)
        self.assertNotIn("APP_REVIEW_MONITOR_VERSION", environment)
        self.assertEqual(
            {name: environment[name] for name in MUTATION_SECRETS},
            {
                "APP_STORE_CONNECT_KEY_ID": "${{ secrets.APP_STORE_CONNECT_KEY_ID }}",
                "APP_STORE_CONNECT_ISSUER_ID": "${{ secrets.APP_STORE_CONNECT_ISSUER_ID }}",
                "APP_STORE_CONNECT_API_KEY": "${{ secrets.APP_STORE_CONNECT_API_KEY }}",
            },
        )
        self.assertNotIn(VARIABLE_TOKEN, secrets_of(observe_steps[0]))
        self.assertNotIn(MONITOR_VARIABLE_TOKEN, secrets_of(observe_steps[0]))
        self.assertNotIn(SHARED_TOOL_READ_TOKEN, secrets_of(observe_steps[0]))
        for step in steps_of(self.jobs(MONITOR_E2E)["observe"]):
            blob = json.dumps(step)
            self.assertIsNone(DEDICATED_MONITOR_SECRET.search(blob))
            self.assertNotIn("app_review_pipeline.js monitor", blob)
            self.assertNotIn("app_review_pipeline.js status", blob)
            self.assertNotIn("app_review_pipeline.js submit", blob)

    def test_the_proof_rejects_a_non_sha_engine_pin_before_checkout(self):
        steps = steps_of(self.jobs(MONITOR_E2E)["observe"])
        validate = next(
            index
            for index, step in enumerate(steps)
            if "non-SHA" in str(step.get("name", ""))
        )
        tool = next(
            index
            for index, step in enumerate(steps)
            if (step.get("with") or {}).get("repository") == SHARED_TOOL_REPO
        )
        observe = next(
            index
            for index, step in enumerate(steps)
            if OBSERVE_HARNESS in str(step.get("run", ""))
        )
        self.assertLess(validate, tool)
        self.assertLess(tool, observe)
        command = steps[validate]["run"]
        self.assertIn("engine_sha must be a full 40-hex git SHA", command)
        self.assertIn(r"^[0-9a-f]{40}$", command)


class ListVersionsWorkflowTests(WorkflowModelCase):
    """GET-only iOS version listing: classify baseline uniqueness, never submit."""

    def test_the_listing_is_a_trusted_default_branch_dispatch(self):
        triggers = self.models[LIST_VERSIONS]["on"]
        self.assertEqual(list(triggers), ["workflow_dispatch"])
        dispatch = triggers["workflow_dispatch"]
        inputs = dispatch.get("inputs") if isinstance(dispatch, dict) else None
        self.assertIn(dispatch, (None, True, {}, {"inputs": None}))
        self.assertTrue(not inputs)
        self.assertEqual(self.models[LIST_VERSIONS]["permissions"], {"contents": "read"})
        concurrency = self.models[LIST_VERSIONS]["concurrency"]
        self.assertEqual(concurrency["group"], "eddies-app-review-list-versions")
        self.assertIs(concurrency["cancel-in-progress"], False)
        job = self.jobs(LIST_VERSIONS)["list"]
        guard = " ".join(str(job.get("if", "")).split())
        self.assertIn(REPOSITORY_GUARD, guard)
        self.assertIn(DEFAULT_BRANCH_GUARD, guard)
        self.assertEqual(job.get("permissions"), {"contents": "read"})
        self.assertNotIn("environment", job)
        self.assertNotIn("issues", job.get("permissions", {}))
        self.assertNotIn("issues", self.models[LIST_VERSIONS]["permissions"])

    def test_the_listing_maps_the_submit_key_into_exactly_one_get_step(self):
        steps = steps_of(self.jobs(LIST_VERSIONS)["list"])
        holding = [step for step in steps if secrets_of(step) & set(MUTATION_SECRETS)]
        self.assertEqual(len(holding), 1)
        self.assertEqual(secrets_of(holding[0]), set(MUTATION_SECRETS))
        self.assertNotIn(VARIABLE_TOKEN, secrets_of(holding[0]))
        self.assertNotIn(MONITOR_VARIABLE_TOKEN, secrets_of(holding[0]))
        self.assertNotIn(SHARED_TOOL_READ_TOKEN, secrets_of(holding[0]))
        self.assertNotIn("GITHUB_TOKEN", holding[0].get("env") or {})
        self.assertEqual(
            holding[0]["run"].strip(),
            "python3 tools/app-review/list_app_store_versions.py",
        )
        blob = json.dumps(self.models[LIST_VERSIONS])
        self.assertNotIn("submit.py", blob)
        self.assertNotIn("assemble_only.js", blob)
        self.assertNotIn("full_submit.js", blob)
        self.assertNotIn("app_review_pipeline.js", blob)
        self.assertNotIn("reviewSubmissions", blob)
        self.assertNotIn("issues: write", blob)

    def test_every_listing_action_is_pinned_and_leaves_no_git_credential(self):
        for step in steps_of(self.jobs(LIST_VERSIONS)["list"]):
            uses = step.get("uses")
            if uses:
                self.assertRegex(uses, PINNED_ACTION)
            if str(step.get("uses", "")).startswith("actions/checkout@"):
                self.assertIs(step["with"]["persist-credentials"], False)


class ListVersionsScriptTests(unittest.TestCase):
    """The listing printer reports every row a GET collection returned."""

    def test_the_printer_emits_every_version_row_including_duplicates(self):
        sys.path.insert(0, str(TOOLS))
        self.addCleanup(sys.path.remove, str(TOOLS))
        listing = importlib.import_module("list_app_store_versions")
        rows = listing.rows_from(
            [
                {
                    "type": "appStoreVersions",
                    "id": "older-016",
                    "attributes": {
                        "versionString": "0.1.16",
                        "appVersionState": "REPLACED_WITH_NEW_VERSION",
                        "appStoreState": "REPLACED_WITH_NEW_VERSION",
                        "createdDate": "2026-07-01T00:00:00Z",
                    },
                },
                {
                    "type": "appStoreVersions",
                    "id": "live-016",
                    "attributes": {
                        "versionString": "0.1.16",
                        "appVersionState": "READY_FOR_SALE",
                        "appStoreState": "READY_FOR_SALE",
                        "createdDate": "2026-07-02T00:00:00Z",
                    },
                },
                {
                    "type": "appStoreVersions",
                    "id": "rejected-017",
                    "attributes": {
                        "versionString": "0.1.17",
                        "appVersionState": "REJECTED",
                        "appStoreState": "REJECTED",
                        "createdDate": "2026-08-01T00:00:00Z",
                    },
                },
            ]
        )
        table = listing.format_table(rows)
        self.assertIn("count=3 writes=0 method=GET", table)
        self.assertIn("filter[platform]=IOS", table)
        self.assertEqual(len(rows), 3)
        self.assertEqual(
            [row["id"] for row in rows if row["versionString"] == "0.1.16"],
            ["older-016", "live-016"],
        )
        self.assertIn(
            "0.1.16\tREPLACED_WITH_NEW_VERSION\tREPLACED_WITH_NEW_VERSION\t2026-07-01T00:00:00Z\tolder-016",
            table,
        )
        self.assertIn(
            "0.1.16\tREADY_FOR_SALE\tREADY_FOR_SALE\t2026-07-02T00:00:00Z\tlive-016",
            table,
        )
        self.assertIn(
            "0.1.17\tREJECTED\tREJECTED\t2026-08-01T00:00:00Z\trejected-017",
            table,
        )


class ListAppInfoWorkflowTests(WorkflowModelCase):
    """GET-only App Info category listing: classify E_PROTECTED, never submit."""

    def test_the_listing_is_a_trusted_default_branch_dispatch(self):
        triggers = self.models[LIST_APP_INFO]["on"]
        self.assertEqual(list(triggers), ["workflow_dispatch"])
        dispatch = triggers["workflow_dispatch"]
        inputs = dispatch.get("inputs") if isinstance(dispatch, dict) else None
        self.assertIn(dispatch, (None, True, {}, {"inputs": None}))
        self.assertTrue(not inputs)
        self.assertEqual(self.models[LIST_APP_INFO]["permissions"], {"contents": "read"})
        concurrency = self.models[LIST_APP_INFO]["concurrency"]
        self.assertEqual(concurrency["group"], "eddies-app-review-list-app-info")
        self.assertIs(concurrency["cancel-in-progress"], False)
        job = self.jobs(LIST_APP_INFO)["list"]
        guard = " ".join(str(job.get("if", "")).split())
        self.assertIn(REPOSITORY_GUARD, guard)
        self.assertIn(DEFAULT_BRANCH_GUARD, guard)
        self.assertEqual(job.get("permissions"), {"contents": "read"})
        self.assertNotIn("environment", job)
        self.assertNotIn("issues", job.get("permissions", {}))
        self.assertNotIn("issues", self.models[LIST_APP_INFO]["permissions"])

    def test_the_listing_maps_the_submit_key_into_exactly_one_get_step(self):
        steps = steps_of(self.jobs(LIST_APP_INFO)["list"])
        holding = [step for step in steps if secrets_of(step) & set(MUTATION_SECRETS)]
        self.assertEqual(len(holding), 1)
        self.assertEqual(secrets_of(holding[0]), set(MUTATION_SECRETS))
        self.assertNotIn(VARIABLE_TOKEN, secrets_of(holding[0]))
        self.assertNotIn(MONITOR_VARIABLE_TOKEN, secrets_of(holding[0]))
        self.assertNotIn(SHARED_TOOL_READ_TOKEN, secrets_of(holding[0]))
        self.assertNotIn("GITHUB_TOKEN", holding[0].get("env") or {})
        self.assertEqual(
            holding[0]["run"].strip(),
            "python3 tools/app-review/list_app_info_categories.py",
        )
        blob = json.dumps(self.models[LIST_APP_INFO])
        self.assertNotIn("submit.py", blob)
        self.assertNotIn("assemble_only.js", blob)
        self.assertNotIn("full_submit.js", blob)
        self.assertNotIn("app_review_pipeline.js", blob)
        self.assertNotIn("reviewSubmissions", blob)
        self.assertNotIn("issues: write", blob)

    def test_every_listing_action_is_pinned_and_leaves_no_git_credential(self):
        for step in steps_of(self.jobs(LIST_APP_INFO)["list"]):
            uses = step.get("uses")
            if uses:
                self.assertRegex(uses, PINNED_ACTION)
            if str(step.get("uses", "")).startswith("actions/checkout@"):
                self.assertIs(step["with"]["persist-credentials"], False)


class ListAppInfoScriptTests(unittest.TestCase):
    """The printer reports every App Info row's resolved category ids."""

    def setUp(self):
        sys.path.insert(0, str(TOOLS))
        self.addCleanup(sys.path.remove, str(TOOLS))
        self.listing = importlib.import_module("list_app_info_categories")

    def test_the_printer_resolves_relationship_ids_to_category_resource_ids(self):
        class Session:
            def __init__(self):
                self.paths = []

            def collection(self, path, query):
                self.paths.append(("collection", path, dict(query)))
                return (
                    [
                        {
                            "type": "appInfos",
                            "id": "info-live",
                            "attributes": {"state": "READY_FOR_DISTRIBUTION"},
                        },
                        {
                            "type": "appInfos",
                            "id": "info-edit",
                            "attributes": {"state": "PREPARE_FOR_SUBMISSION"},
                        },
                    ],
                    [],
                )

            def optional_single(self, path, query):
                self.paths.append(("optional_single", path, dict(query)))
                mapping = {
                    "/v1/appInfos/info-live/relationships/primaryCategory": {
                        "type": "appCategories",
                        "id": "EDUCATION",
                    },
                    "/v1/appInfos/info-live/relationships/secondaryCategory": {
                        "type": "appCategories",
                        "id": "PRODUCTIVITY",
                    },
                    "/v1/appInfos/info-edit/relationships/primaryCategory": {
                        "type": "appCategories",
                        "id": "FINANCE",
                    },
                    "/v1/appInfos/info-edit/relationships/secondaryCategory": {
                        "type": "appCategories",
                        "id": "PRODUCTIVITY",
                    },
                }
                return mapping[path]

            def get(self, path, query):
                self.paths.append(("get", path, dict(query)))
                identifier = path.rsplit("/", 1)[-1]
                return {
                    "data": {
                        "type": "appCategories",
                        "id": identifier,
                        "attributes": {"platforms": ["IOS"]},
                    }
                }

        session = Session()
        rows = self.listing.collect_rows(session)
        table = self.listing.format_table(rows, ("FINANCE", "PRODUCTIVITY"))
        self.assertEqual(
            [(method, path) for method, path, _query in session.paths if method != "collection"],
            [
                ("optional_single", "/v1/appInfos/info-live/relationships/primaryCategory"),
                ("optional_single", "/v1/appInfos/info-live/relationships/secondaryCategory"),
                ("get", "/v1/appCategories/EDUCATION"),
                ("get", "/v1/appCategories/PRODUCTIVITY"),
                ("optional_single", "/v1/appInfos/info-edit/relationships/primaryCategory"),
                ("optional_single", "/v1/appInfos/info-edit/relationships/secondaryCategory"),
                ("get", "/v1/appCategories/FINANCE"),
                ("get", "/v1/appCategories/PRODUCTIVITY"),
            ],
        )
        self.assertIn("count=2 writes=0 method=GET", table)
        self.assertIn("configured.primary=FINANCE configured.secondary=PRODUCTIVITY", table)
        self.assertIn(
            "info-live\tREADY_FOR_DISTRIBUTION\tEDUCATION\tEDUCATION\tPRODUCTIVITY\tPRODUCTIVITY",
            table,
        )
        self.assertIn(
            "info-edit\tPREPARE_FOR_SUBMISSION\tFINANCE\tFINANCE\tPRODUCTIVITY\tPRODUCTIVITY",
            table,
        )
        self.assertEqual(
            self.listing.live_summary(rows),
            "live.primary=EDUCATION,FINANCE live.secondary=PRODUCTIVITY appInfos=2",
        )

    def test_a_null_category_relationship_prints_as_empty_not_a_guess(self):
        class Session:
            def collection(self, path, query):
                return (
                    [
                        {
                            "type": "appInfos",
                            "id": "info-empty",
                            "attributes": {"state": "PREPARE_FOR_SUBMISSION"},
                        }
                    ],
                    [],
                )

            def optional_single(self, path, query):
                return None

            def get(self, path, query):
                raise AssertionError(f"must not resolve a missing category: {path}")

        rows = self.listing.collect_rows(Session())
        self.assertEqual(
            rows,
            [
                {
                    "appInfoId": "info-empty",
                    "state": "PREPARE_FOR_SUBMISSION",
                    "primaryId": "",
                    "primaryName": "",
                    "secondaryId": "",
                    "secondaryName": "",
                }
            ],
        )
        self.assertEqual(
            self.listing.live_summary(rows),
            "live.primary= live.secondary= appInfos=1",
        )


class EulaAppendWorkflowTests(WorkflowModelCase):
    """The 3.1.2 EULA append is a bounded one-shot write, not listing-sync."""

    def test_the_eula_append_is_a_main_only_manual_dispatch(self):
        triggers = self.models[EULA_APPEND]["on"]
        self.assertEqual(list(triggers), ["workflow_dispatch"])
        inputs = triggers["workflow_dispatch"]["inputs"]
        self.assertEqual(list(inputs), ["confirm"])
        self.assertTrue(inputs["confirm"]["required"])
        self.assertIn("APPEND-EULA", inputs["confirm"]["description"])
        self.assertNotIn("version", inputs)
        self.assertNotIn("mode", inputs)
        self.assertNotIn("evidence", inputs)
        self.assertEqual(
            self.models[EULA_APPEND]["permissions"], {"contents": "read"}
        )
        concurrency = self.models[EULA_APPEND]["concurrency"]
        self.assertEqual(concurrency["group"], "eddies-app-review-eula-append")
        self.assertIs(concurrency["cancel-in-progress"], False)

    def test_the_eula_append_job_is_pinned_to_this_repository_and_main(self):
        job = self.jobs(EULA_APPEND)["append"]
        guard = " ".join(str(job.get("if", "")).split())
        self.assertIn(REPOSITORY_GUARD, guard)
        self.assertIn(DEFAULT_BRANCH_GUARD, guard)
        self.assertEqual(job.get("permissions"), {"contents": "read"})
        self.assertNotIn("environment", job)
        self.assertNotIn("issues", job.get("permissions", {}))

    def test_the_eula_append_maps_the_submit_key_into_exactly_one_step(self):
        steps = steps_of(self.jobs(EULA_APPEND)["append"])
        holding = [step for step in steps if secrets_of(step) & set(MUTATION_SECRETS)]
        self.assertEqual(len(holding), 1)
        self.assertEqual(secrets_of(holding[0]), set(MUTATION_SECRETS))
        self.assertNotIn(VARIABLE_TOKEN, secrets_of(holding[0]))
        self.assertNotIn(MONITOR_VARIABLE_TOKEN, secrets_of(holding[0]))
        self.assertNotIn(SHARED_TOOL_READ_TOKEN, secrets_of(holding[0]))
        self.assertEqual(
            holding[0]["env"]["EDDIES_EULA_APPEND_CONFIRM"],
            "${{ inputs.confirm }}",
        )
        self.assertEqual(
            holding[0]["run"].strip(),
            "python3 tools/app-review/append_standard_eula.py",
        )
        blob = json.dumps(self.models[EULA_APPEND])
        self.assertNotIn("submit.py", blob)
        self.assertNotIn("reviewSubmissions", blob)
        self.assertNotIn("pin_app_review_manifest.sh", blob)

    def test_every_eula_append_action_is_pinned_and_leaves_no_git_credential(self):
        for step in steps_of(self.jobs(EULA_APPEND)["append"]):
            uses = step.get("uses")
            if uses:
                self.assertRegex(uses, PINNED_ACTION)
            if str(step.get("uses", "")).startswith("actions/checkout@"):
                self.assertIs(step["with"]["persist-credentials"], False)


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
        for entrypoint in (
            "prepare",
            "demo_preflight",
            "verify",
            "screenshot_preflight",
            "list_app_store_versions",
            "list_app_info_categories",
        ):
            with self.subTest(entrypoint=entrypoint):
                loaded = self.loaded_modules(entrypoint)
                self.assertIn("core", loaded)
                self.assertNotIn("asc_write", loaded)
                self.assertNotIn("submission", loaded)

    def test_the_eula_append_script_never_loads_the_submission_write_boundary(self):
        loaded = self.loaded_modules("append_standard_eula")
        self.assertIn("asc_read", loaded)
        self.assertNotIn("asc_write", loaded)
        self.assertNotIn("submission", loaded)
        self.assertNotIn("submit", loaded)

    def test_the_python_submit_engine_is_retired(self):
        for name in ("submit.py", "submission.py", "asc_write.py"):
            with self.subTest(name=name):
                self.assertFalse((TOOLS / name).is_file())
        importers = [
            path.name
            for path in sorted(TOOLS.glob("*.py"))
            if re.search(r"^\s*import asc_write\b", path.read_text(), re.MULTILINE)
        ]
        self.assertEqual(importers, [])


class HttpBoundaryTests(unittest.TestCase):
    """Every request each boundary can actually send, captured as it is sent."""

    def setUp(self):
        sys.path.insert(0, str(TOOLS))
        self.addCleanup(sys.path.remove, str(TOOLS))
        self.asc_read = importlib.import_module("asc_read")
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

    def test_dropping_the_assemble_mode_guard_would_be_caught(self):
        model = parse_workflow(SUBMIT)
        model["jobs"]["assemble"]["if"] = REPOSITORY_GUARD
        self.assertNotIn("inputs.mode == 'assemble'", model["jobs"]["assemble"]["if"])

    def test_dropping_the_submit_mode_guard_would_be_caught(self):
        model = parse_workflow(SUBMIT)
        model["jobs"]["submit"]["if"] = REPOSITORY_GUARD
        self.assertNotIn("inputs.mode == 'submit'", model["jobs"]["submit"]["if"])

    def test_dropping_the_upload_mode_guard_would_be_caught(self):
        model = parse_workflow(SUBMIT)
        model["jobs"]["upload"]["if"] = REPOSITORY_GUARD
        self.assertNotIn("inputs.mode == 'upload'", model["jobs"]["upload"]["if"])

    def test_adding_an_environment_would_be_caught(self):
        model = parse_workflow(SUBMIT)
        model["jobs"]["assemble"]["environment"] = "app-store-submission"
        self.assertIn("environment", model["jobs"]["assemble"])

    def test_dropping_the_shared_tool_checkout_token_would_be_caught(self):
        model = parse_workflow(MONITOR)
        tool = next(
            step
            for step in steps_of(model["jobs"]["observe"])
            if (step.get("with") or {}).get("repository") == SHARED_TOOL_REPO
        )
        tool["with"].pop("token", None)
        held = [
            step
            for step in steps_of(model["jobs"]["observe"])
            if SHARED_TOOL_READ_TOKEN in secrets_of(step) | with_secrets_of(step)
        ]
        self.assertEqual(
            held,
            [],
            "the lane assertion must be able to see a missing checkout token",
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
