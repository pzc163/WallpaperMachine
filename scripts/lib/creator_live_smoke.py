#!/usr/bin/env python3
"""Opt-in, one-shot in-memory credential handoff; never forward an API key to Xcode."""
from __future__ import annotations

from http.server import BaseHTTPRequestHandler, HTTPServer
import hmac
import secrets
import threading


class ConfigurationError(ValueError):
    """Only fixed, nonsecret configuration messages are exposed."""


class LiveSmoke:
    def __init__(self, environ, *, only=None, ui=False, python_only=False):
        # Remove keys from the runner's environment before it launches *any* child,
        # including XcodeGen and Python tests. Xcode may persist TEST_RUNNER values.
        raw = environ.pop("CREATOR_LIVE_API_KEY", None)
        prefixed = environ.pop("TEST_RUNNER_CREATOR_LIVE_API_KEY", None)
        self.environment = dict(environ)
        self.enabled = self.environment.get("TEST_RUNNER_CREATOR_LIVE_LLM") == "1"
        self._secret = None
        self._server = self._thread = None
        self._lock = threading.Lock()
        self._token = secrets.token_urlsafe(32) if self.enabled else ""
        if not self.enabled:
            return
        selected = [value.removeprefix("WallpaperMachineTests/") for value in (only or [])]
        if ui or python_only or selected not in [["CreatorLiveSmokeTests"], ["CreatorLiveSmokeTests/testSingleLiveCreationAndSave"]]:
            raise ConfigurationError("Live creator smoke requires --only CreatorLiveSmokeTests; a full/UI gate cannot opt in.")
        if raw is not None and prefixed is not None and raw != prefixed:
            raise ConfigurationError("Conflicting creator smoke credentials.")
        value = raw if raw is not None else prefixed
        if value is None:
            raise ConfigurationError("Set CREATOR_LIVE_API_KEY explicitly; use an empty value only for an explicit local profile.")
        if len(value.encode("utf-8")) > 4096 or any(ord(c) < 32 or ord(c) == 127 for c in value):
            raise ConfigurationError("Invalid creator smoke credential format.")
        for field in ["PROTOCOL", "ENDPOINT", "MODEL"]:
            if not self.environment.get("TEST_RUNNER_CREATOR_LIVE_" + field):
                raise ConfigurationError("Creator smoke protocol, endpoint and model must be explicit.")
        self._secret = bytearray(value.encode("utf-8"))

    def __enter__(self):
        if not self.enabled:
            return self.environment
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def setup(self):
                super().setup()
                self.connection.settimeout(2)

            def do_POST(self):
                if (self.path != "/credential" or self.headers.get("Content-Length", "0") != "0"
                        or not hmac.compare_digest(self.headers.get("X-Creator-Smoke-Token", ""), owner._token)):
                    self.send_error(403)
                    return
                with owner._lock:
                    if owner._secret is None:
                        self.send_error(410)
                        return
                    body = bytes(owner._secret)
                    owner._erase()
                self.send_response(200)
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Cache-Control", "no-store")
                self.send_header("Connection", "close")
                self.end_headers()
                try:
                    self.wfile.write(body)
                except (BrokenPipeError, ConnectionResetError):
                    pass  # Consumed even if delivery fails; never replay a credential.

        self._server = HTTPServer(("127.0.0.1", 0), Handler)
        self._thread = threading.Thread(target=self._server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True)
        self._thread.start()
        result = dict(self.environment)
        result["TEST_RUNNER_CREATOR_LIVE_BROKER_PORT"] = str(self._server.server_port)
        result["TEST_RUNNER_CREATOR_LIVE_BROKER_TOKEN"] = self._token
        return result

    def _erase(self):
        if self._secret is not None:
            self._secret[:] = b"\0" * len(self._secret)
            self._secret = None

    def __exit__(self, *_):
        if self._server:
            self._server.shutdown()
            self._server.server_close()
            self._thread.join(timeout=3)
        with self._lock:
            self._erase()
