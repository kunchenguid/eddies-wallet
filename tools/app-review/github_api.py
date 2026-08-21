#!/usr/bin/env python3
"""Concrete GitHub boundaries for the App Review pipeline.

Two boundaries live here, and they deliberately use different credentials.

`IssueBoundary` implements `core.GitHubIssueBoundary` with the run's ephemeral
`GITHUB_TOKEN`. It writes only the durable, nonsecret recovery record and its one
mutable journal comment.

`MonitorCycleVariable` can write the post-acceptance handoff that arms the
review monitor. Assemble-only does not call it; the captain arms
`APP_REVIEW_MONITOR_VERSION` after Submit.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import re
import sys
from typing import Any, Mapping, Optional, Sequence
import urllib.error
import urllib.request

_HERE = str(Path(__file__).resolve().parent)
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import core  # noqa: E402

GITHUB_API = "https://api.github.com"
REQUEST_TIMEOUT_SECONDS = 30
MAX_ISSUE_PAGES = 20
MONITOR_CYCLE_VARIABLE = "EDDIES_REVIEW_MONITOR_CYCLE"
MONITOR_CYCLE_SCHEMA_VERSION = 1
REPOSITORY_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")


class GitHubError(core.BoundedError):
    """A bounded, nonsecret GitHub boundary failure."""

    def __init__(self, message: str, status: Optional[int] = None):
        super().__init__(message)
        self.status = status


def repository() -> str:
    found = os.environ.get("GITHUB_REPOSITORY", "")
    if not REPOSITORY_RE.fullmatch(found):
        raise GitHubError("GitHub repository identity is invalid")
    return found


def _request(
    token: str, method: str, path: str, payload: Optional[Mapping[str, Any]] = None
) -> Any:
    if not token:
        raise GitHubError("a required GitHub token is not configured for this job")
    if not path.startswith("/"):
        raise GitHubError("GitHub request path is invalid")
    request = urllib.request.Request(
        GITHUB_API + path,
        data=json.dumps(payload).encode("utf-8") if payload is not None else None,
        method=method,
        headers={
            "Authorization": "Bearer " + token,
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=REQUEST_TIMEOUT_SECONDS) as response:
            body = response.read()
            return json.loads(body) if body else None
    except urllib.error.HTTPError as error:
        raise GitHubError(
            f"GitHub {method} request failed with status {error.code}", error.code
        )
    except GitHubError:
        raise
    except Exception:
        raise GitHubError(f"GitHub {method} request failed")


class IssueBoundary:
    """The durable recovery record boundary. It writes issues and nothing else."""

    def __init__(self, token: Optional[str] = None, repo: Optional[str] = None):
        self._token = token if token is not None else os.environ.get("GITHUB_TOKEN", "")
        self._repository = repo or repository()

    def list_issues(self) -> Sequence[core.Issue]:
        issues: list[core.Issue] = []
        page = 1
        while page <= MAX_ISSUE_PAGES:
            batch = _request(
                self._token,
                "GET",
                f"/repos/{self._repository}/issues?state=all&per_page=100&page={page}",
            )
            if not isinstance(batch, list):
                raise GitHubError("GitHub returned a malformed issue collection")
            issues.extend(
                _issue(entry) for entry in batch if "pull_request" not in entry
            )
            if len(batch) < 100:
                return tuple(issues)
            page += 1
        raise GitHubError("GitHub issue enumeration did not settle")

    def create_issue(self, title: str, body: str) -> core.Issue:
        return _issue(
            _request(
                self._token,
                "POST",
                f"/repos/{self._repository}/issues",
                {"title": title, "body": body},
            )
        )

    def list_comments(self, issue_number: int) -> Sequence[core.Comment]:
        comments: list[core.Comment] = []
        page = 1
        while page <= MAX_ISSUE_PAGES:
            batch = _request(
                self._token,
                "GET",
                f"/repos/{self._repository}/issues/{int(issue_number)}/comments?per_page=100&page={page}",
            )
            if not isinstance(batch, list):
                raise GitHubError("GitHub returned a malformed comment collection")
            comments.extend(_comment(entry) for entry in batch)
            if len(batch) < 100:
                return tuple(comments)
            page += 1
        raise GitHubError("GitHub comment enumeration did not settle")

    def create_comment(self, issue_number: int, body: str) -> core.Comment:
        return _comment(
            _request(
                self._token,
                "POST",
                f"/repos/{self._repository}/issues/{int(issue_number)}/comments",
                {"body": body},
            )
        )

    def update_comment(self, comment_identifier: int, body: str) -> core.Comment:
        return _comment(
            _request(
                self._token,
                "PATCH",
                f"/repos/{self._repository}/issues/comments/{int(comment_identifier)}",
                {"body": body},
            )
        )


def _issue(value: object) -> core.Issue:
    if not isinstance(value, dict):
        raise GitHubError("GitHub returned a malformed issue")
    number, title, body = value.get("number"), value.get("title"), value.get("body")
    user = value.get("user")
    actor = user.get("login") if isinstance(user, dict) else None
    if (
        not isinstance(number, int)
        or not isinstance(title, str)
        or not isinstance(actor, str)
    ):
        raise GitHubError("GitHub returned a malformed issue")
    return core.Issue(number, title, body if isinstance(body, str) else "", actor)


def _comment(value: object) -> core.Comment:
    if not isinstance(value, dict):
        raise GitHubError("GitHub returned a malformed comment")
    identifier, body = value.get("id"), value.get("body")
    user = value.get("user")
    actor = user.get("login") if isinstance(user, dict) else None
    if not isinstance(identifier, int) or not isinstance(actor, str):
        raise GitHubError("GitHub returned a malformed comment")
    return core.Comment(identifier, body if isinstance(body, str) else "", actor)


def monitor_cycle_value(version: str, build: str) -> str:
    """One atomic logical cycle. Half a cycle can only ever watch the wrong build."""
    if core.VERSION_RE.fullmatch(version or "") is None:
        raise GitHubError("monitor cycle version is invalid")
    if core.BUILD_RE.fullmatch(build or "") is None:
        raise GitHubError("monitor cycle build is invalid")
    return json.dumps(
        {"v": MONITOR_CYCLE_SCHEMA_VERSION, "version": version, "build": build},
        separators=(",", ":"),
        sort_keys=True,
    )


class MonitorCycleVariable:
    """Idempotent `GET -> write -> GET` handoff for the exact review cycle."""

    def __init__(self, token: Optional[str] = None, repo: Optional[str] = None):
        self._token = (
            token
            if token is not None
            else os.environ.get("EDDIES_REVIEW_MONITOR_VARIABLE_TOKEN", "")
        )
        self._repository = repo or repository()

    @property
    def configured(self) -> bool:
        return bool(self._token)

    def _path(self, name: str = MONITOR_CYCLE_VARIABLE) -> str:
        return f"/repos/{self._repository}/actions/variables/{name}"

    def read(self) -> Optional[str]:
        try:
            found = _request(self._token, "GET", self._path())
        except GitHubError as error:
            if error.status == 404:
                return None
            raise
        if not isinstance(found, dict) or not isinstance(found.get("value"), str):
            raise GitHubError("GitHub returned a malformed Actions variable")
        return found["value"]

    def hand_off(self, version: str, build: str) -> str:
        """Arm the monitor for exactly one cycle and prove it by reading it back."""
        value = monitor_cycle_value(version, build)
        current = self.read()
        if current != value:
            if current is None:
                _request(
                    self._token,
                    "POST",
                    f"/repos/{self._repository}/actions/variables",
                    {"name": MONITOR_CYCLE_VARIABLE, "value": value},
                )
            else:
                _request(
                    self._token,
                    "PATCH",
                    self._path(),
                    {"name": MONITOR_CYCLE_VARIABLE, "value": value},
                )
        if self.read() != value:
            raise GitHubError(
                "the review monitor cycle variable did not read back as the submitted cycle"
            )
        return value
