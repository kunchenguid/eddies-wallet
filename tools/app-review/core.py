#!/usr/bin/env python3
"""Deterministic, credential-free core for Eddie's Wallet App Review preparation.

This module deliberately has no environment-variable, credential, network, or App
Store Connect mutation path. Future workflows must provide authenticated GET and
GitHub issue boundaries explicitly. The core verifies their results before a
future mutation lane can make a decision.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
from typing import Any, Mapping, Optional, Protocol, Sequence

APP_ID = "6795664301"
BUNDLE_ID = "com.kunchenguid.eddieswallet"
PLATFORM = "IOS"
REPOSITORY = "kunchenguid/eddies-wallet"
DEFAULT_BRANCH_REF = "refs/heads/main"
CAPTAIN_GITHUB_LOGIN = "kunchenguid"

MANIFEST_SCHEMA_VERSION = 1
MANIFEST_BINDING_ALGORITHM = "eddies-wallet-app-review-manifest-v1"
JOURNAL_SCHEMA_VERSION = 1

LISTING_FIELDS = (
    "appName",
    "subtitle",
    "promotionalText",
    "description",
    "keywords",
    "privacyPolicyUrl",
    "supportUrl",
    "whatsNew",
)
CLOUD_PRODUCT_IDS = (
    "com.kunchenguid.eddieswallet.cloud.monthly",
    "com.kunchenguid.eddieswallet.cloud.annual",
)
RELEASE_TYPES = frozenset(("MANUAL", "AFTER_APPROVAL"))
REVIEWER_IDENTITY = "REVIEWER_OWNED_SIGN_IN_WITH_APPLE"
REVIEWER_PARENT_PIN = "REVIEWER_CREATED_ON_DEVICE"
REVIEWER_CLOUD_PURCHASE = "APPLE_REVIEW_OR_SANDBOX"

VERSION_RE = re.compile(r"^[0-9]+(?:\.[0-9]+){1,2}$")
BUILD_RE = re.compile(r"^[0-9]+(?:\.[0-9]+){0,2}$")
COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
HEX_256_RE = re.compile(r"^[0-9a-f]{64}$")
SAFE_SLOT_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$")
SAFE_ACTOR_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9-]{0,38}$")

DRAFT_STATES = frozenset(("PREPARE_FOR_SUBMISSION", "READY_FOR_REVIEW"))
SUBMITTED_STATES = frozenset(("WAITING_FOR_REVIEW", "IN_REVIEW"))
JOURNAL_PHASES = frozenset(("prepared", "reconciled"))
JOURNAL_RECONCILIATIONS = frozenset(
    ("not_read", "absent", "matching_draft", "already_submitted")
)


class BoundedError(RuntimeError):
    """Base for every bounded, nonsecret failure this pipeline is allowed to print.

    Anything not derived from this is treated as an unexpected fault whose text
    may carry an Apple payload, a header, or a credential, and is never printed.
    """


class AppReviewError(BoundedError):
    """A bounded, nonsecret deterministic-core failure."""

    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code


def refuse(code: str, message: str) -> None:
    raise AppReviewError(code, message)


def require(condition: bool, code: str, message: str) -> None:
    if not condition:
        refuse(code, message)


def _is_mapping(value: object) -> bool:
    return isinstance(value, Mapping)


def _exact_keys(
    value: object, expected: Sequence[str], name: str, code: str
) -> Mapping[str, Any]:
    require(_is_mapping(value), code, f"{name} must be an object")
    actual = set(value.keys())
    require(actual == set(expected), code, f"{name} has unsupported or missing fields")
    return value  # type: ignore[return-value]


def _review_text(
    value: object, name: str, *, empty: bool = True, limit: int = 10_000
) -> str:
    require(isinstance(value, str), "E_MANIFEST", f"{name} must be text")
    require(
        (empty or len(value) > 0) and len(value) <= limit,
        "E_MANIFEST",
        f"{name} length is invalid",
    )
    require("\x00" not in value, "E_MANIFEST", f"{name} contains a NUL byte")
    return value


def canonical_bytes(value: object) -> bytes:
    """Return one unambiguous UTF-8 representation while retaining array order."""
    try:
        return json.dumps(
            value,
            sort_keys=True,
            separators=(",", ":"),
            ensure_ascii=False,
            allow_nan=False,
        ).encode("utf-8")
    except (TypeError, ValueError):
        refuse("E_CANONICAL", "review content is not canonical JSON data")
    raise AssertionError("unreachable")


def stable_hash(value: object) -> str:
    return hashlib.sha256(canonical_bytes(value)).hexdigest()


def _validate_relative_path(value: object, name: str) -> str:
    require(
        isinstance(value, str) and value != "", "E_MANIFEST", f"{name} path is invalid"
    )
    require("\\" not in value, "E_MANIFEST", f"{name} path is invalid")
    path = PurePosixPath(value)
    require(
        not path.is_absolute() and ".." not in path.parts and "." not in path.parts,
        "E_MANIFEST",
        f"{name} path is invalid",
    )
    require(
        len(path.parts) > 0 and all(part not in ("", ".", "..") for part in path.parts),
        "E_MANIFEST",
        f"{name} path is invalid",
    )
    return value


def _validate_file_descriptor(value: object, name: str) -> Mapping[str, Any]:
    descriptor = _exact_keys(value, ("path", "bytes", "sha256"), name, "E_MANIFEST")
    _validate_relative_path(descriptor["path"], name)
    require(
        isinstance(descriptor["bytes"], int)
        and not isinstance(descriptor["bytes"], bool),
        "E_MANIFEST",
        f"{name} byte count is invalid",
    )
    require(
        0 < descriptor["bytes"] <= 32 * 1024 * 1024,
        "E_MANIFEST",
        f"{name} byte count is invalid",
    )
    require(
        isinstance(descriptor["sha256"], str)
        and HEX_256_RE.fullmatch(descriptor["sha256"]) is not None,
        "E_MANIFEST",
        f"{name} hash is invalid",
    )
    return descriptor


def validate_source_content(value: object) -> Mapping[str, Any]:
    """Validate all reviewed content that must stay bit-for-bit bound to a manifest."""
    content = _exact_keys(
        value,
        ("listing", "screenshots", "inAppPurchases", "appReview"),
        "content",
        "E_MANIFEST",
    )

    listing = _exact_keys(content["listing"], LISTING_FIELDS, "listing", "E_MANIFEST")
    for field in LISTING_FIELDS:
        _review_text(listing[field], f"listing.{field}", limit=10_000)

    screenshots = content["screenshots"]
    require(
        isinstance(screenshots, list) and len(screenshots) > 0,
        "E_MANIFEST",
        "screenshots are invalid",
    )
    seen_slots = set()
    for index, screenshot in enumerate(screenshots):
        item = _exact_keys(
            screenshot, ("slot", "files"), f"screenshot {index}", "E_MANIFEST"
        )
        slot = item["slot"]
        require(
            isinstance(slot, str)
            and SAFE_SLOT_RE.fullmatch(slot) is not None
            and slot not in seen_slots,
            "E_MANIFEST",
            "screenshot slots are invalid",
        )
        seen_slots.add(slot)
        files = item["files"]
        require(
            isinstance(files, list) and len(files) > 0,
            "E_MANIFEST",
            "screenshot files are invalid",
        )
        seen_paths = set()
        for file_index, file in enumerate(files):
            descriptor = _validate_file_descriptor(
                file, f"screenshot {slot} file {file_index}"
            )
            require(
                descriptor["path"] not in seen_paths,
                "E_MANIFEST",
                "screenshot files are duplicated",
            )
            seen_paths.add(descriptor["path"])

    reviews = content["inAppPurchases"]
    require(
        isinstance(reviews, list) and len(reviews) == len(CLOUD_PRODUCT_IDS),
        "E_MANIFEST",
        "in-app purchase review data is invalid",
    )
    for index, product_id in enumerate(CLOUD_PRODUCT_IDS):
        review = _exact_keys(
            reviews[index],
            ("productId", "reviewNotes", "reviewScreenshot"),
            f"in-app purchase {index}",
            "E_MANIFEST",
        )
        require(
            review["productId"] == product_id,
            "E_MANIFEST",
            "in-app purchase identities are invalid",
        )
        _review_text(
            review["reviewNotes"],
            f"in-app purchase {product_id} review notes",
            limit=4_000,
        )
        _validate_file_descriptor(
            review["reviewScreenshot"],
            f"in-app purchase {product_id} review screenshot",
        )

    review = _exact_keys(
        content["appReview"],
        ("notes", "demoAccountRequired", "identity", "parentPin", "cloudPurchase"),
        "app review details",
        "E_MANIFEST",
    )
    _review_text(review["notes"], "app review notes", limit=4_000)
    require(
        review["demoAccountRequired"] is False,
        "E_MANIFEST",
        "reviewer access must not require a demo account",
    )
    require(
        review["identity"] == REVIEWER_IDENTITY,
        "E_MANIFEST",
        "reviewer identity must remain reviewer-owned Sign in with Apple",
    )
    require(
        review["parentPin"] == REVIEWER_PARENT_PIN,
        "E_MANIFEST",
        "reviewer parent PIN policy is invalid",
    )
    require(
        review["cloudPurchase"] == REVIEWER_CLOUD_PURCHASE,
        "E_MANIFEST",
        "reviewer Cloud purchase policy is invalid",
    )
    return content


def source_content_hash(content: object) -> str:
    validate_source_content(content)
    return stable_hash(content)


def _safe_file_descriptor(source_root: Path, relative_path: str) -> Mapping[str, Any]:
    _validate_relative_path(relative_path, "reviewed file")
    root = source_root.resolve()
    require(root.is_dir(), "E_SOURCE", "review source root is not a directory")
    current = root
    for part in PurePosixPath(relative_path).parts:
        current = current / part
        require(
            not current.is_symlink(),
            "E_SOURCE",
            "reviewed file must not traverse a symbolic link",
        )
    require(current.is_file(), "E_SOURCE", "reviewed file is missing or not regular")
    data = current.read_bytes()
    require(len(data) > 0, "E_SOURCE", "reviewed file is empty")
    return {
        "path": relative_path,
        "bytes": len(data),
        "sha256": hashlib.sha256(data).hexdigest(),
    }


def materialize_source_content(
    source_root: Path,
    listing: Mapping[str, str],
    screenshot_slots: Sequence[Mapping[str, Any]],
    in_app_purchases: Sequence[Mapping[str, str]],
    app_review_notes: str,
) -> Mapping[str, Any]:
    """Snapshot reviewed files by exact bytes before their descriptors enter a manifest."""
    require(
        len(screenshot_slots) > 0,
        "E_SOURCE",
        "at least one screenshot slot is required",
    )
    screenshots = []
    for slot in screenshot_slots:
        item = _exact_keys(slot, ("slot", "files"), "screenshot source", "E_SOURCE")
        require(
            isinstance(item["slot"], str) and isinstance(item["files"], list),
            "E_SOURCE",
            "screenshot source is invalid",
        )
        screenshots.append(
            {
                "slot": item["slot"],
                "files": [
                    _safe_file_descriptor(source_root, path) for path in item["files"]
                ],
            }
        )

    require(
        len(in_app_purchases) == len(CLOUD_PRODUCT_IDS),
        "E_SOURCE",
        "in-app purchase source is invalid",
    )
    purchases = []
    for product_id, source in zip(CLOUD_PRODUCT_IDS, in_app_purchases):
        item = _exact_keys(
            source,
            ("productId", "reviewNotes", "screenshotPath"),
            "in-app purchase source",
            "E_SOURCE",
        )
        require(
            item["productId"] == product_id
            and isinstance(item["reviewNotes"], str)
            and isinstance(item["screenshotPath"], str),
            "E_SOURCE",
            "in-app purchase source is invalid",
        )
        purchases.append(
            {
                "productId": product_id,
                "reviewNotes": item["reviewNotes"],
                "reviewScreenshot": _safe_file_descriptor(
                    source_root, item["screenshotPath"]
                ),
            }
        )

    content = {
        "listing": dict(listing),
        "screenshots": screenshots,
        "inAppPurchases": purchases,
        "appReview": {
            "notes": app_review_notes,
            "demoAccountRequired": False,
            "identity": REVIEWER_IDENTITY,
            "parentPin": REVIEWER_PARENT_PIN,
            "cloudPurchase": REVIEWER_CLOUD_PURCHASE,
        },
    }
    validate_source_content(content)
    return content


def _validate_candidate(value: object) -> Mapping[str, Any]:
    candidate = _exact_keys(
        value,
        ("version", "build", "baselineVersion", "sourceCommit", "releaseType"),
        "candidate",
        "E_MANIFEST",
    )
    require(
        isinstance(candidate["version"], str)
        and VERSION_RE.fullmatch(candidate["version"]) is not None,
        "E_MANIFEST",
        "candidate version is invalid",
    )
    require(
        isinstance(candidate["build"], str)
        and BUILD_RE.fullmatch(candidate["build"]) is not None,
        "E_MANIFEST",
        "candidate build is invalid",
    )
    require(
        isinstance(candidate["baselineVersion"], str)
        and VERSION_RE.fullmatch(candidate["baselineVersion"]) is not None
        and candidate["baselineVersion"] != candidate["version"],
        "E_MANIFEST",
        "candidate baseline version is invalid",
    )
    require(
        isinstance(candidate["sourceCommit"], str)
        and COMMIT_RE.fullmatch(candidate["sourceCommit"]) is not None,
        "E_MANIFEST",
        "candidate source commit is invalid",
    )
    require(
        candidate["releaseType"] in RELEASE_TYPES,
        "E_MANIFEST",
        "candidate release type must be MANUAL or AFTER_APPROVAL",
    )
    return candidate


def _validate_timestamp(value: object, name: str) -> str:
    require(isinstance(value, str), "E_MANIFEST", f"{name} is invalid")
    try:
        datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ")
    except ValueError:
        refuse("E_MANIFEST", f"{name} is invalid")
    return value


def manifest_binding_hash(manifest: Mapping[str, Any]) -> str:
    binding_input = dict(manifest)
    binding_input.pop("binding", None)
    return stable_hash(binding_input)


def build_manifest(
    candidate: Mapping[str, Any],
    content: Mapping[str, Any],
    *,
    approved_utc: str,
    approval_statement: str,
) -> Mapping[str, Any]:
    """Create a captain-approved artifact. It does not read GitHub or App Store Connect."""
    _validate_candidate(candidate)
    validate_source_content(content)
    approval = {
        "approved": True,
        "approvedBy": CAPTAIN_GITHUB_LOGIN,
        "approvedUtc": approved_utc,
        "statement": approval_statement,
    }
    manifest: dict[str, Any] = {
        "schemaVersion": MANIFEST_SCHEMA_VERSION,
        "app": {"appId": APP_ID, "bundleId": BUNDLE_ID, "platform": PLATFORM},
        "candidate": dict(candidate),
        "content": content,
        "contentHash": source_content_hash(content),
        "approval": approval,
        "binding": {"algorithm": MANIFEST_BINDING_ALGORITHM, "manifestHash": ""},
    }
    manifest["binding"]["manifestHash"] = manifest_binding_hash(manifest)
    validate_manifest(manifest)
    return manifest


def validate_manifest(value: object) -> Mapping[str, Any]:
    manifest = _exact_keys(
        value,
        (
            "schemaVersion",
            "app",
            "candidate",
            "content",
            "contentHash",
            "approval",
            "binding",
        ),
        "manifest",
        "E_MANIFEST",
    )
    require(
        manifest["schemaVersion"] == MANIFEST_SCHEMA_VERSION,
        "E_MANIFEST",
        "manifest schema version is unsupported",
    )
    app = _exact_keys(
        manifest["app"], ("appId", "bundleId", "platform"), "manifest app", "E_MANIFEST"
    )
    require(
        app == {"appId": APP_ID, "bundleId": BUNDLE_ID, "platform": PLATFORM},
        "E_MANIFEST",
        "manifest app identity is not Eddie's Wallet iOS",
    )
    _validate_candidate(manifest["candidate"])
    validate_source_content(manifest["content"])
    require(
        isinstance(manifest["contentHash"], str)
        and HEX_256_RE.fullmatch(manifest["contentHash"]) is not None,
        "E_MANIFEST",
        "manifest content hash is invalid",
    )
    require(
        manifest["contentHash"] == source_content_hash(manifest["content"]),
        "E_MANIFEST",
        "manifest content hash does not bind reviewed content",
    )

    approval = _exact_keys(
        manifest["approval"],
        ("approved", "approvedBy", "approvedUtc", "statement"),
        "manifest approval",
        "E_MANIFEST",
    )
    require(
        approval["approved"] is True, "E_MANIFEST", "manifest is not captain-approved"
    )
    require(
        approval["approvedBy"] == CAPTAIN_GITHUB_LOGIN,
        "E_MANIFEST",
        "manifest approval is not from the captain",
    )
    _validate_timestamp(approval["approvedUtc"], "manifest approval timestamp")
    _review_text(
        approval["statement"], "manifest approval statement", empty=False, limit=500
    )

    binding = _exact_keys(
        manifest["binding"],
        ("algorithm", "manifestHash"),
        "manifest binding",
        "E_MANIFEST",
    )
    require(
        binding["algorithm"] == MANIFEST_BINDING_ALGORITHM,
        "E_MANIFEST",
        "manifest binding algorithm is unsupported",
    )
    require(
        isinstance(binding["manifestHash"], str)
        and HEX_256_RE.fullmatch(binding["manifestHash"]) is not None,
        "E_MANIFEST",
        "manifest binding hash is invalid",
    )
    require(
        binding["manifestHash"] == manifest_binding_hash(manifest),
        "E_MANIFEST",
        "manifest binding hash does not match manifest content",
    )
    return manifest


def verify_manifest_content(
    manifest: Mapping[str, Any], source_content: Mapping[str, Any]
) -> None:
    """Fail closed unless the current reviewed source exactly matches the approved snapshot."""
    valid_manifest = validate_manifest(manifest)
    validate_source_content(source_content)
    require(
        canonical_bytes(valid_manifest["content"]) == canonical_bytes(source_content),
        "E_MANIFEST_BINDING",
        "reviewed source content differs from the captain-approved manifest",
    )
    require(
        valid_manifest["contentHash"] == source_content_hash(source_content),
        "E_MANIFEST_BINDING",
        "reviewed source content hash differs from the captain-approved manifest",
    )


@dataclass(frozen=True)
class TrustedContext:
    repository: str
    ref: str
    event_name: str
    actor: str


def assert_trusted_context(context: TrustedContext) -> TrustedContext:
    require(
        context.repository == REPOSITORY,
        "E_CONTEXT",
        "execution is not in the trusted Eddie's Wallet repository",
    )
    require(
        context.ref == DEFAULT_BRANCH_REF,
        "E_CONTEXT",
        "execution is not on the trusted default branch",
    )
    require(
        context.event_name == "workflow_dispatch",
        "E_CONTEXT",
        "execution is not a trusted manual dispatch",
    )
    require(
        SAFE_ACTOR_RE.fullmatch(context.actor) is not None,
        "E_CONTEXT",
        "dispatch actor is invalid",
    )
    return context


def assert_captain_actor(context: TrustedContext) -> TrustedContext:
    assert_trusted_context(context)
    require(
        context.actor == CAPTAIN_GITHUB_LOGIN,
        "E_CONTEXT",
        "the dispatch actor is not the captain",
    )
    return context


class ASCUnauthorized(Exception):
    """Raised by an injected read transport when ASC did not authorize its GET."""


class ASCReadTransport(Protocol):
    def get(self, path: str, query: Mapping[str, str]) -> Mapping[str, Any]: ...


@dataclass(frozen=True)
class LiveReadState:
    app_id: str
    bundle_id: str
    platform: str
    version: str
    build: str
    state: str
    release_type: Optional[str]
    content: Optional[Mapping[str, Any]]

    @classmethod
    def from_document(cls, value: object) -> "LiveReadState":
        document = _exact_keys(
            value,
            (
                "appId",
                "bundleId",
                "platform",
                "version",
                "build",
                "state",
                "releaseType",
                "content",
            ),
            "ASC read state",
            "E_ASC_READ",
        )
        for field in ("appId", "bundleId", "platform", "version", "build", "state"):
            require(
                isinstance(document[field], str),
                "E_ASC_READ",
                "ASC read state is malformed",
            )
        require(
            document["releaseType"] is None or isinstance(document["releaseType"], str),
            "E_ASC_READ",
            "ASC read state is malformed",
        )
        require(
            document["content"] is None or _is_mapping(document["content"]),
            "E_ASC_READ",
            "ASC read state is malformed",
        )
        return cls(
            app_id=document["appId"],
            bundle_id=document["bundleId"],
            platform=document["platform"],
            version=document["version"],
            build=document["build"],
            state=document["state"],
            release_type=document["releaseType"],
            content=document["content"],
        )


class ReadOnlyASCClient:
    """GET-only App Store Connect boundary. No generic request or write API exists."""

    __slots__ = ("__get",)

    def __init__(self, transport: ASCReadTransport):
        get = getattr(transport, "get", None)
        require(
            callable(get),
            "E_ASC_CAPABILITY",
            "a GET-only App Store Connect client is unavailable",
        )
        # Retain only the GET capability, never the wider transport object.
        self.__get = get

    def read_candidate(self, candidate: Mapping[str, Any]) -> LiveReadState:
        _validate_candidate(candidate)
        query = {
            "filter[versionString]": candidate["version"],
            "filter[platform]": PLATFORM,
            "fields[appStoreVersions]": "versionString,appVersionState,build",
            "include": "build",
        }
        try:
            document = self.__get(f"/v1/apps/{APP_ID}/appStoreVersions", query)
        except ASCUnauthorized:
            refuse(
                "E_ASC_CAPABILITY",
                "App Store Connect read capability is absent or unauthorized",
            )
        except AppReviewError:
            raise
        except Exception:
            refuse("E_ASC_READ", "App Store Connect GET request failed")
        return LiveReadState.from_document(document)


@dataclass(frozen=True)
class Reconciliation:
    outcome: str
    state: str


def reconcile_manifest_with_live_state(
    manifest: Mapping[str, Any], live: LiveReadState
) -> Reconciliation:
    """Compare one exact approved candidate with the authoritative GET readback."""
    valid_manifest = validate_manifest(manifest)
    candidate = valid_manifest["candidate"]
    require(
        live.app_id == APP_ID
        and live.bundle_id == BUNDLE_ID
        and live.platform == PLATFORM,
        "E_RECONCILIATION",
        "ASC read state belongs to a different app",
    )
    require(
        live.version == candidate["version"] and live.build == candidate["build"],
        "E_RECONCILIATION",
        "ASC read state does not match the exact approved version and build",
    )

    if live.state == "ABSENT":
        require(
            live.release_type is None and live.content is None,
            "E_RECONCILIATION",
            "absent ASC candidate carries unexpected review data",
        )
        return Reconciliation("absent", live.state)

    require(
        live.state in DRAFT_STATES | SUBMITTED_STATES,
        "E_RECONCILIATION",
        "ASC candidate is in an unsupported or ambiguous state",
    )
    require(
        live.release_type == candidate["releaseType"],
        "E_RECONCILIATION",
        "ASC release behavior differs from the approved manifest",
    )
    require(
        live.content is not None,
        "E_RECONCILIATION",
        "ASC candidate has no readable reviewed content",
    )
    validate_source_content(live.content)
    require(
        canonical_bytes(live.content) == canonical_bytes(valid_manifest["content"]),
        "E_RECONCILIATION",
        "ASC reviewed content differs from the approved manifest",
    )
    require(
        source_content_hash(live.content) == valid_manifest["contentHash"],
        "E_RECONCILIATION",
        "ASC reviewed content hash differs from the approved manifest",
    )
    return Reconciliation(
        "matching_draft" if live.state in DRAFT_STATES else "already_submitted",
        live.state,
    )


def reconcile_authoritatively(
    manifest: Mapping[str, Any], client: Optional[ReadOnlyASCClient]
) -> Reconciliation:
    """Require actual read capability. There is intentionally no best-effort local fallback."""
    require(
        client is not None and isinstance(client, ReadOnlyASCClient),
        "E_ASC_CAPABILITY",
        "a GET-only App Store Connect client is required",
    )
    valid_manifest = validate_manifest(manifest)
    return reconcile_manifest_with_live_state(
        valid_manifest, client.read_candidate(valid_manifest["candidate"])
    )


@dataclass(frozen=True)
class Issue:
    number: int
    title: str
    body: str
    actor: str


@dataclass(frozen=True)
class Comment:
    identifier: int
    body: str
    actor: str


class GitHubIssueBoundary(Protocol):
    def list_issues(self) -> Sequence[Issue]: ...

    def create_issue(self, title: str, body: str) -> Issue: ...

    def list_comments(self, issue_number: int) -> Sequence[Comment]: ...

    def create_comment(self, issue_number: int, body: str) -> Comment: ...

    def update_comment(self, comment_identifier: int, body: str) -> Comment: ...


@dataclass(frozen=True)
class JournalIdentity:
    version: str
    build: str
    manifest_hash: str
    approved_commit: str
    key: str

    @classmethod
    def from_manifest(
        cls, manifest: Mapping[str, Any], approved_commit: str
    ) -> "JournalIdentity":
        valid_manifest = validate_manifest(manifest)
        require(
            isinstance(approved_commit, str)
            and COMMIT_RE.fullmatch(approved_commit) is not None,
            "E_RECORD",
            "manifest-approved commit is invalid",
        )
        candidate = valid_manifest["candidate"]
        manifest_hash = valid_manifest["binding"]["manifestHash"]
        key = hashlib.sha256(
            f"v{JOURNAL_SCHEMA_VERSION}\0{APP_ID}\0{candidate['version']}\0{manifest_hash}\0{approved_commit}".encode(
                "utf-8"
            )
        ).hexdigest()
        return cls(
            candidate["version"],
            candidate["build"],
            manifest_hash,
            approved_commit,
            key,
        )


@dataclass(frozen=True)
class DurableJournalState:
    phase: str
    reconciliation: str
    updated_utc: str

    def document(self) -> Mapping[str, Any]:
        return {
            "schemaVersion": JOURNAL_SCHEMA_VERSION,
            "phase": self.phase,
            "reconciliation": self.reconciliation,
            "updatedUtc": self.updated_utc,
        }

    @classmethod
    def from_document(cls, value: object) -> "DurableJournalState":
        document = _exact_keys(
            value,
            ("schemaVersion", "phase", "reconciliation", "updatedUtc"),
            "journal state",
            "E_RECORD",
        )
        require(
            document["schemaVersion"] == JOURNAL_SCHEMA_VERSION,
            "E_RECORD",
            "journal schema version is unsupported",
        )
        require(
            document["phase"] in JOURNAL_PHASES, "E_RECORD", "journal phase is invalid"
        )
        require(
            document["reconciliation"] in JOURNAL_RECONCILIATIONS,
            "E_RECORD",
            "journal reconciliation is invalid",
        )
        timestamp = document["updatedUtc"]
        require(isinstance(timestamp, str), "E_RECORD", "journal timestamp is invalid")
        try:
            datetime.strptime(timestamp, "%Y-%m-%dT%H:%M:%SZ")
        except ValueError:
            refuse("E_RECORD", "journal timestamp is invalid")
        return cls(document["phase"], document["reconciliation"], timestamp)


@dataclass(frozen=True)
class JournalOpen:
    created: bool
    resumable: bool
    state: Optional[DurableJournalState]


def _trusted_automation_actor(actor: str) -> bool:
    return actor == "github-actions[bot]"


class GitHubIssueJournal:
    """A deduplicated issue record with one mutable, nonsecret journal comment."""

    def __init__(self, boundary: GitHubIssueBoundary, identity: JournalIdentity):
        self._boundary = boundary
        self._identity = identity
        self._issue_number: Optional[int] = None
        self._journal_comment_identifier: Optional[int] = None

    def _marker(self, kind: str) -> str:
        return f"<!-- eddies-wallet-app-review:v{JOURNAL_SCHEMA_VERSION}:{self._identity.key}:{kind} -->"

    def _record_body(self) -> str:
        return "\n".join(
            (
                "Durable nonsecret recovery record for one captain-approved Eddie's Wallet App Review candidate.",
                "",
                f"- Candidate: `{self._identity.version}` build `{self._identity.build}`",
                f"- App: `{APP_ID}` (`{BUNDLE_ID}`)",
                f"- Manifest binding hash: `{self._identity.manifest_hash}`",
                f"- Manifest-approved commit: `{self._identity.approved_commit}`",
                "",
                "The mutable journal stores only phase, reconciliation outcome, and timestamp.",
                self._marker("record"),
            )
        )

    def _journal_body(self, state: DurableJournalState) -> str:
        return "\n".join(
            (
                self._marker("journal"),
                "",
                "```json",
                json.dumps(state.document(), sort_keys=True, separators=(",", ":")),
                "```",
            )
        )

    def _parse_journal(self, body: str) -> DurableJournalState:
        prefix = "```json\n"
        start = body.find(prefix)
        end = body.rfind("\n```")
        require(
            start >= 0 and end > start, "E_RECORD", "durable journal state is corrupt"
        )
        encoded = body[start + len(prefix) : end]
        require(
            0 < len(encoded.encode("utf-8")) <= 8 * 1024,
            "E_RECORD",
            "durable journal state is corrupt",
        )
        try:
            document = json.loads(encoded)
        except json.JSONDecodeError:
            refuse("E_RECORD", "durable journal state is corrupt")
        return DurableJournalState.from_document(document)

    def open(self, *, create: bool) -> JournalOpen:
        marker = self._marker("record")
        records = [
            issue
            for issue in self._boundary.list_issues()
            if _trusted_automation_actor(issue.actor) and marker in issue.body
        ]
        require(
            len(records) <= 1,
            "E_RECORD",
            "more than one durable journal record matches this manifest",
        )
        if not records:
            require(
                create,
                "E_RECORD",
                "no durable journal record exists; preparation must run first",
            )
            created = self._boundary.create_issue(
                f"Eddie's Wallet App Review {self._identity.version}",
                self._record_body(),
            )
            require(
                _trusted_automation_actor(created.actor) and created.number >= 1,
                "E_RECORD",
                "GitHub did not create a trusted durable journal record",
            )
            self._issue_number = created.number
            return JournalOpen(created=True, resumable=False, state=None)

        record = records[0]
        require(record.number >= 1, "E_RECORD", "durable journal record is malformed")
        self._issue_number = record.number
        journal_marker = self._marker("journal")
        comments = [
            comment
            for comment in self._boundary.list_comments(record.number)
            if _trusted_automation_actor(comment.actor)
            and journal_marker in comment.body
        ]
        require(
            len(comments) <= 1,
            "E_RECORD",
            "durable journal has more than one mutable state",
        )
        if not comments:
            return JournalOpen(created=False, resumable=False, state=None)
        comment = comments[0]
        require(
            comment.identifier >= 1, "E_RECORD", "durable journal comment is malformed"
        )
        self._journal_comment_identifier = comment.identifier
        return JournalOpen(
            created=False, resumable=True, state=self._parse_journal(comment.body)
        )

    def save(self, state: DurableJournalState) -> None:
        require(
            self._issue_number is not None,
            "E_RECORD",
            "durable journal must be opened before it is saved",
        )
        DurableJournalState.from_document(state.document())
        body = self._journal_body(state)
        if self._journal_comment_identifier is None:
            comment = self._boundary.create_comment(self._issue_number, body)
            require(
                _trusted_automation_actor(comment.actor) and comment.identifier >= 1,
                "E_RECORD",
                "GitHub did not create a trusted journal state",
            )
            self._journal_comment_identifier = comment.identifier
            return
        comment = self._boundary.update_comment(self._journal_comment_identifier, body)
        require(
            _trusted_automation_actor(comment.actor)
            and comment.identifier == self._journal_comment_identifier,
            "E_RECORD",
            "GitHub did not update the durable journal state",
        )
