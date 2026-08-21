#!/usr/bin/env python3
"""GET-only App Store Connect boundary for Eddie's Wallet App Review automation.

This module is structurally read-only. Every request it can build is created
with `method="GET"` and no body, so a credential handed to this module cannot
change App Store Connect state even if the caller asks it to. Assemble-only
mutation lives in the pinned shared Node engine, not in this Python tree.

The credential is read from the environment, written to a mode-600 runner-temp
file only for the lifetime of one signature, and never printed. Diagnostics are
bounded ASCII so an Apple response body, header, or key can never reach a log.
"""

from __future__ import annotations

import base64
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
from typing import Any, Iterator, Mapping, Optional
import urllib.error
import urllib.parse
import urllib.request

_HERE = str(Path(__file__).resolve().parent)
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import core  # noqa: E402

ASC_HOST = "api.appstoreconnect.apple.com"
ASC_AUDIENCE = "appstoreconnect-v1"
TOKEN_LIFETIME_SECONDS = 600
REQUEST_TIMEOUT_SECONDS = 30
MAX_PAGES = 40


class AppStoreConnectError(core.BoundedError):
    """A bounded, nonsecret App Store Connect boundary failure."""


class AppStoreConnectUnauthorized(AppStoreConnectError):
    """App Store Connect refused the credential rather than the request."""


def redact(text: object) -> str:
    """Bounded ASCII diagnostics cannot carry a payload, header, or credential."""
    return re.sub(r"[^A-Za-z0-9 .,:()/\[\]-]", "?", str(text))[:180]


def mask(value: str) -> None:
    """Ask the runner to redact a value from every subsequent log line."""
    if value and os.environ.get("GITHUB_ACTIONS") == "true":
        for line in value.splitlines():
            if line.strip():
                print(f"::add-mask::{line}", flush=True)


class Credential:
    """One App Store Connect API key. The private key never leaves this object."""

    __slots__ = ("key_id", "issuer_id", "_private_key")

    def __init__(self, key_id: str, issuer_id: str, private_key: bytes):
        if not re.fullmatch(r"[A-Za-z0-9]{6,32}", key_id or ""):
            raise AppStoreConnectError("App Store Connect key identifier is invalid")
        if not re.fullmatch(
            r"[0-9a-fA-F-]{16,64}", issuer_id or ""
        ):  # Apple issues a UUID.
            raise AppStoreConnectError("App Store Connect issuer identifier is invalid")
        if not private_key.startswith(b"-----BEGIN"):
            raise AppStoreConnectError("App Store Connect private key is not a PEM key")
        self.key_id = key_id
        self.issuer_id = issuer_id
        self._private_key = private_key

    @classmethod
    def from_environment(cls) -> "Credential":
        key_id = os.environ.get("APP_STORE_CONNECT_KEY_ID", "")
        issuer_id = os.environ.get("APP_STORE_CONNECT_ISSUER_ID", "")
        encoded = os.environ.get("APP_STORE_CONNECT_API_KEY", "")
        if not (key_id and issuer_id and encoded):
            raise AppStoreConnectUnauthorized(
                "App Store Connect credential is not configured for this job"
            )
        mask(key_id)
        mask(issuer_id)
        try:
            private_key = base64.b64decode(encoded, validate=True)
        except Exception:
            raise AppStoreConnectError(
                "App Store Connect private key is not valid base64"
            )
        mask(private_key.decode("utf-8", "replace"))
        return cls(key_id, issuer_id, private_key)

    @classmethod
    def absent_from_environment(cls) -> bool:
        return not any(
            os.environ.get(name)
            for name in (
                "APP_STORE_CONNECT_KEY_ID",
                "APP_STORE_CONNECT_ISSUER_ID",
                "APP_STORE_CONNECT_API_KEY",
            )
        )

    def bearer_token(self, *, issued_at: Optional[int] = None) -> str:
        now = int(time.time()) if issued_at is None else issued_at
        header = {"alg": "ES256", "kid": self.key_id, "typ": "JWT"}
        payload = {
            "iss": self.issuer_id,
            "iat": now,
            "exp": now + TOKEN_LIFETIME_SECONDS,
            "aud": ASC_AUDIENCE,
        }
        signing_input = ".".join(
            _base64url(json.dumps(part, separators=(",", ":")).encode("utf-8"))
            for part in (header, payload)
        )
        return f"{signing_input}.{_base64url(self._sign(signing_input.encode('ascii')))}"

    def _sign(self, signing_input: bytes) -> bytes:
        directory = os.environ.get("RUNNER_TEMP") or tempfile.gettempdir()
        key_path = Path(directory) / f"asc-app-review-key-{os.getpid()}.p8"
        signature_path = Path(directory) / f"asc-app-review-sig-{os.getpid()}.der"
        previous_umask = os.umask(0o077)
        try:
            key_path.write_bytes(self._private_key)
            os.chmod(key_path, 0o600)
            subprocess.run(
                ["openssl", "dgst", "-sha256", "-sign", str(key_path), "-out", str(signature_path)],
                input=signing_input,
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            return _der_signature_to_raw(signature_path.read_bytes())
        except AppStoreConnectError:
            raise
        except Exception:
            raise AppStoreConnectError(
                "App Store Connect credential could not sign a request"
            )
        finally:
            os.umask(previous_umask)
            key_path.unlink(missing_ok=True)
            signature_path.unlink(missing_ok=True)


def _base64url(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).rstrip(b"=").decode("ascii")


def _der_signature_to_raw(der: bytes) -> bytes:
    """Convert OpenSSL's DER ECDSA signature into the fixed-width JWS form."""
    offset = 2
    if len(der) < 8 or der[0] != 0x30:
        raise AppStoreConnectError("App Store Connect signature is malformed")

    def integer() -> bytes:
        nonlocal offset
        if der[offset] != 0x02:
            raise AppStoreConnectError("App Store Connect signature is malformed")
        length = der[offset + 1]
        start = offset + 2
        offset = start + length
        if length == 0 or offset > len(der):
            raise AppStoreConnectError("App Store Connect signature is malformed")
        raw = der[start:offset].lstrip(b"\0") or b"\0"
        if len(raw) > 32:
            raise AppStoreConnectError("App Store Connect signature is malformed")
        return raw.rjust(32, b"\0")

    return integer() + integer()


def validate_asc_url(url: object) -> str:
    if not isinstance(url, str):
        raise AppStoreConnectError("App Store Connect returned an unsafe URL")
    try:
        parsed = urllib.parse.urlsplit(url)
        port = parsed.port
    except ValueError:
        raise AppStoreConnectError("App Store Connect returned an unsafe URL")
    if (
        parsed.scheme != "https"
        or parsed.hostname != ASC_HOST
        or port not in (None, 443)
        or parsed.username
        or parsed.password
    ):
        raise AppStoreConnectError("App Store Connect returned an unsafe URL")
    return url


def build_url(path: str, query: Mapping[str, str]) -> str:
    if not path.startswith("/v1/") or "//" in path[1:] or ".." in path:
        raise AppStoreConnectError("App Store Connect request path is invalid")
    encoded = urllib.parse.urlencode(dict(query), doseq=False)
    return validate_asc_url(
        f"https://{ASC_HOST}{path}" + (f"?{encoded}" if encoded else "")
    )


class SameOriginRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        validate_asc_url(newurl)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


class ReadSession:
    """A GET-only App Store Connect session. It can construct no other method."""

    def __init__(self, credential: Credential):
        self._credential = credential
        self._opener = urllib.request.build_opener(SameOriginRedirectHandler)
        self._token = ""
        self._token_expiry = 0.0

    def _bearer(self) -> str:
        now = time.time()
        if not self._token or now >= self._token_expiry:
            self._token = self._credential.bearer_token()
            self._token_expiry = now + TOKEN_LIFETIME_SECONDS - 60
        return self._token

    def get_url(self, url: str) -> Mapping[str, Any]:
        validate_asc_url(url)
        request = urllib.request.Request(
            url,
            method="GET",
            headers={
                "Authorization": "Bearer " + self._bearer(),
                "Accept": "application/json",
            },
        )
        try:
            with self._opener.open(request, timeout=REQUEST_TIMEOUT_SECONDS) as response:
                payload = json.loads(response.read())
        except urllib.error.HTTPError as error:
            if error.code in (401, 403):
                raise AppStoreConnectUnauthorized(
                    "App Store Connect refused the read credential"
                )
            raise AppStoreConnectError(
                f"App Store Connect read request failed with status {error.code}"
            )
        except AppStoreConnectError:
            raise
        except Exception:
            raise AppStoreConnectError("App Store Connect read request failed")
        if not isinstance(payload, dict):
            raise AppStoreConnectError("App Store Connect returned a malformed document")
        return payload

    def get(self, path: str, query: Mapping[str, str]) -> Mapping[str, Any]:
        return self.get_url(build_url(path, query))

    def pages(self, path: str, query: Mapping[str, str]) -> Iterator[Mapping[str, Any]]:
        url: Optional[str] = build_url(path, query)
        seen: set[str] = set()
        while url:
            if url in seen or len(seen) >= MAX_PAGES:
                raise AppStoreConnectError("App Store Connect pagination did not settle")
            seen.add(url)
            payload = self.get_url(url)
            yield payload
            links = payload.get("links")
            nxt = links.get("next") if isinstance(links, dict) else None
            url = validate_asc_url(nxt) if nxt is not None else None

    def collection(
        self, path: str, query: Mapping[str, str]
    ) -> tuple[list[Mapping[str, Any]], list[Mapping[str, Any]]]:
        """Return every page's primary resources and its included resources."""
        items: list[Mapping[str, Any]] = []
        included: list[Mapping[str, Any]] = []
        for payload in self.pages(path, query):
            data = payload.get("data")
            if not isinstance(data, list):
                raise AppStoreConnectError(
                    "App Store Connect returned a malformed collection"
                )
            items.extend(resource(entry) for entry in data)
            extra = payload.get("included", [])
            if extra:
                if not isinstance(extra, list):
                    raise AppStoreConnectError(
                        "App Store Connect returned malformed included resources"
                    )
                included.extend(resource(entry) for entry in extra)
        return items, included

    def optional_single(
        self, path: str, query: Mapping[str, str]
    ) -> Optional[Mapping[str, Any]]:
        """Read a to-one relationship that App Store Connect may report as null."""
        payload = self.get(path, query)
        data = payload.get("data")
        return None if data is None else resource(data)


def resource(value: object) -> Mapping[str, Any]:
    if (
        not isinstance(value, dict)
        or not isinstance(value.get("id"), str)
        or not isinstance(value.get("type"), str)
        or not isinstance(value.get("attributes", {}), dict)
    ):
        raise AppStoreConnectError("App Store Connect returned a malformed resource")
    return value


def attributes(value: Mapping[str, Any]) -> Mapping[str, Any]:
    found = value.get("attributes")
    if not isinstance(found, dict):
        raise AppStoreConnectError("App Store Connect resource has no attributes")
    return found


def linkage_id(value: Mapping[str, Any], name: str, expected_type: str) -> Optional[str]:
    relationships = value.get("relationships")
    if not isinstance(relationships, dict):
        return None
    entry = relationships.get(name)
    data = entry.get("data") if isinstance(entry, dict) else None
    if data is None:
        return None
    if not isinstance(data, dict) or data.get("type") != expected_type:
        raise AppStoreConnectError("App Store Connect returned a malformed relationship")
    identifier = data.get("id")
    if not isinstance(identifier, str):
        raise AppStoreConnectError("App Store Connect returned a malformed relationship")
    return identifier


def text(value: Mapping[str, Any], name: str) -> str:
    found = value.get(name)
    if found is None:
        return ""
    if not isinstance(found, str):
        raise AppStoreConnectError(f"App Store Connect returned a malformed {name}")
    return found
