#!/usr/bin/env python3
"""Only loopback IPC with a synthetic credential; never a model/API request."""
import http.client
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from lib.creator_live_smoke import ConfigurationError, LiveSmoke


class LiveSmokeTests(unittest.TestCase):
    def environment(self, key="synthetic-smoke-secret"):
        return {"TEST_RUNNER_CREATOR_LIVE_LLM": "1", "CREATOR_LIVE_API_KEY": key,
                "TEST_RUNNER_CREATOR_LIVE_PROTOCOL": "openaiCompatible",
                "TEST_RUNNER_CREATOR_LIVE_ENDPOINT": "https://fixture.invalid",
                "TEST_RUNNER_CREATOR_LIVE_MODEL": "fixture"}

    def request(self, env, token=None):
        connection = http.client.HTTPConnection("127.0.0.1", int(env["TEST_RUNNER_CREATOR_LIVE_BROKER_PORT"]), timeout=2)
        try:
            connection.request("POST", "/credential", headers={"X-Creator-Smoke-Token": token or env["TEST_RUNNER_CREATOR_LIVE_BROKER_TOKEN"]})
            result = connection.getresponse()
            return result.status, result.read(), result.getheader("Cache-Control")
        finally:
            connection.close()

    def test_disabled_gate_has_no_broker_and_removes_inherited_keys(self):
        env = {"CREATOR_LIVE_API_KEY": "synthetic", "TEST_RUNNER_CREATOR_LIVE_API_KEY": "synthetic"}
        with LiveSmoke(env) as result:
            self.assertEqual(result, {})
        self.assertEqual(env, {})

    def test_full_other_and_ui_runs_cannot_enable_live_requests(self):
        for only, ui, python in [(None, False, False), (["Other"], False, False), (["CreatorLiveSmokeTests"], True, False), (["CreatorLiveSmokeTests"], False, True)]:
            with self.assertRaises(ConfigurationError):
                LiveSmoke(self.environment(), only=only, ui=ui, python_only=python)

    def test_key_is_delivered_once_without_entering_child_environment(self):
        env = self.environment()
        with LiveSmoke(env, only=["CreatorLiveSmokeTests"]) as child:
            self.assertNotIn("CREATOR_LIVE_API_KEY", env)
            self.assertNotIn("synthetic-smoke-secret", repr(child))
            self.assertEqual(self.request(child), (200, b"synthetic-smoke-secret", "no-store"))
            self.assertEqual(self.request(child)[0], 410)

    def test_wrong_token_cannot_consume_key(self):
        with LiveSmoke(self.environment(), only=["CreatorLiveSmokeTests"]) as child:
            self.assertEqual(self.request(child, "wrong")[0], 403)
            self.assertEqual(self.request(child)[0], 200)

    def test_empty_key_is_explicit_and_still_one_shot(self):
        with LiveSmoke(self.environment(""), only=["CreatorLiveSmokeTests"]) as child:
            self.assertEqual(self.request(child)[1], b"")
            self.assertEqual(self.request(child)[0], 410)

    def test_missing_malformed_and_conflicting_credentials_fail_without_echo(self):
        cases = [self.environment("secret\nvalue"), self.environment("secret" * 1000), self.environment()]
        cases[-1]["TEST_RUNNER_CREATOR_LIVE_API_KEY"] = "conflicting-secret"
        missing = self.environment(); missing.pop("CREATOR_LIVE_API_KEY"); cases.append(missing)
        for env in cases:
            with self.assertRaises(ConfigurationError) as failure:
                LiveSmoke(env, only=["CreatorLiveSmokeTests"])
            self.assertNotIn("secret", str(failure.exception))
            self.assertNotIn("CREATOR_LIVE_API_KEY", env)

    def test_shutdown_closes_port_and_erases_unconsumed_key(self):
        broker = LiveSmoke(self.environment(), only=["CreatorLiveSmokeTests"])
        with broker as child:
            pass
        self.assertIsNone(broker._secret)
        with self.assertRaises(OSError):
            self.request(child)

    def test_profile_metadata_must_be_explicit(self):
        for name in ["PROTOCOL", "ENDPOINT", "MODEL"]:
            env = self.environment(); env.pop("TEST_RUNNER_CREATOR_LIVE_" + name)
            with self.assertRaises(ConfigurationError):
                LiveSmoke(env, only=["CreatorLiveSmokeTests"])


if __name__ == "__main__":
    unittest.main()
