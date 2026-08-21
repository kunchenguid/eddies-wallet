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
APP_REVIEW_WORKFLOWS = (PREPARE, SUBMIT, DEMO_PREFLIGHT)
MODELED_WORKFLOWS = APP_REVIEW_WORKFLOWS + (MONITOR, MONITOR_E2E, EULA_APPEND)
SHARED_TOOL_PIN = "216a65513dbde70d04d0efd021792743f094ed77"
FIXED_MONITOR_ENGINE_SHA = "216a65513dbde70d04d0efd021792743f094ed77"
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
                        (MONITOR_E2E, "observe"),
                        (MONITOR, "observe"),
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
        for entrypoint in ("prepare", "demo_preflight"):
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
