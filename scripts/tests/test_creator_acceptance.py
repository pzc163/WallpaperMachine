#!/usr/bin/env python3
"""No external requests: opt-in policy, time allowance and report export contracts."""
from pathlib import Path
from types import SimpleNamespace
import sys
import unittest
from unittest.mock import Mock
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from lib.creator_acceptance import allowance, export_reports
from lib.creator_live_smoke import ConfigurationError, LiveSmoke


class CreatorAcceptanceTests(unittest.TestCase):
    def benchmark(self):
        return {"TEST_RUNNER_CREATOR_BENCHMARK": "1", "CREATOR_LIVE_API_KEY": "synthetic-only-key",
                "TEST_RUNNER_CREATOR_LIVE_PROTOCOL": "openaiCompatible", "TEST_RUNNER_CREATOR_LIVE_ENDPOINT": "https://fixture.invalid",
                "TEST_RUNNER_CREATOR_LIVE_MODEL": "fixture"}

    def test_default_cannot_open_network_or_extend_gate_timeout(self):
        env = {"CREATOR_LIVE_API_KEY": "synthetic"}
        broker = LiveSmoke(env)
        self.assertFalse(broker.enabled)
        self.assertEqual(env, {})
        self.assertIsNone(allowance(env))

    def test_benchmark_requires_its_own_suite_and_strips_key_first(self):
        for selected in [None, ["CreatorBenchmarkTests"], ["CreatorLiveSmokeTests"], ["CreatorBenchmarkLiveTests", "Other"]]:
            env = self.benchmark()
            with self.assertRaises(ConfigurationError): LiveSmoke(env, only=selected)
            self.assertNotIn("CREATOR_LIVE_API_KEY", env)
        env = self.benchmark()
        broker = LiveSmoke(env, only=["CreatorBenchmarkLiveTests"])
        self.assertTrue(broker.enabled); self.assertNotIn("synthetic-only-key", repr(broker.environment))
        self.assertEqual(allowance(env, ["CreatorBenchmarkLiveTests"]), 6000)
        broker.__exit__()

    def test_benchmark_allowance_rounds_up_and_accepts_both_environment_spellings(self):
        for prefix in ["", "TEST_RUNNER_"]:
            env = {"TEST_RUNNER_CREATOR_BENCHMARK": "1", prefix + "CREATOR_BENCHMARK_ALLOWANCE": "7200.5",
                   prefix + "CREATOR_LIVE_TIMEOUT": "600"}
            self.assertEqual(allowance(env, ["CreatorBenchmarkLiveTests"]), 7260)
            env[prefix + "CREATOR_BENCHMARK_ALLOWANCE"] = "86400"
            self.assertEqual(allowance(env, ["CreatorBenchmarkLiveTests"]), 86400)

    def test_benchmark_rejects_invalid_or_conflicting_timing_without_echoing_values(self):
        for field, limits in [("CREATOR_BENCHMARK_ALLOWANCE", ["599", "86401"]), ("CREATOR_LIVE_TIMEOUT", ["4.9", "601"])]:
            for prefix in ["", "TEST_RUNNER_"]:
                for value in ["nan", "inf", "-1", "", "secret-value"] + limits:
                    env = {"TEST_RUNNER_CREATOR_BENCHMARK": "1", prefix + field: value}
                    with self.assertRaises(ConfigurationError) as error: allowance(env, ["CreatorBenchmarkLiveTests"])
                    self.assertNotIn("secret-value", str(error.exception))
            env = {"TEST_RUNNER_CREATOR_BENCHMARK": "1", field: "90", "TEST_RUNNER_" + field: "120"}
            with self.assertRaises(ConfigurationError): allowance(env, ["CreatorBenchmarkLiveTests"])

    def test_modes_and_ui_cannot_be_combined(self):
        for extra in ["TEST_RUNNER_CREATOR_LIVE_LLM", "TEST_RUNNER_CREATOR_SOAK"]:
            env = self.benchmark(); env[extra] = "1"
            with self.assertRaises(ConfigurationError): LiveSmoke(env, only=["CreatorBenchmarkLiveTests"])
        with self.assertRaises(ConfigurationError): LiveSmoke(self.benchmark(), only=["CreatorBenchmarkLiveTests"], ui=True)

    def test_soak_duration_is_bounded_and_has_setup_teardown_allowance(self):
        env = {"TEST_RUNNER_CREATOR_SOAK": "1"}
        self.assertEqual(allowance(env, ["CreatorSoakLiveTests"]), 6000)
        env.update(TEST_RUNNER_CREATOR_SOAK_SECONDS="30", TEST_RUNNER_CREATOR_SOAK_INTERVAL="1")
        self.assertEqual(allowance(env, ["CreatorSoakLiveTests/testThirtyMinuteSoak"]), 6000)
        for seconds, expected in [("5400.5", 6060), ("86400", 87000)]:
            env.update(TEST_RUNNER_CREATOR_SOAK_SECONDS=seconds, TEST_RUNNER_CREATOR_SOAK_INTERVAL="10")
            self.assertEqual(allowance(env, ["CreatorSoakLiveTests"]), expected)
        for seconds, interval in [("nan", "1"), ("inf", "1"), ("0", "1"), ("86401", "10"), ("1800", "0.1"), ("1", "10"), ("secret", "1")]:
            env.update(TEST_RUNNER_CREATOR_SOAK_SECONDS=seconds, TEST_RUNNER_CREATOR_SOAK_INTERVAL=interval)
            with self.assertRaises(ConfigurationError) as failure: allowance(env, ["CreatorSoakLiveTests"])
            self.assertNotIn("secret", str(failure.exception))

    def test_soak_cannot_silently_expand_full_python_or_ui_gate(self):
        env = {"TEST_RUNNER_CREATOR_SOAK": "1"}
        for only, ui, python in [(None, False, False), (["Other"], False, False), (["CreatorSoakLiveTests"], True, False), (["CreatorSoakLiveTests"], False, True)]:
            with self.assertRaises(ConfigurationError): allowance(env, only, ui=ui, python_only=python)

    def test_reports_use_result_attachments_and_export_failure_is_visible(self):
        run = Mock(return_value=SimpleNamespace(returncode=0))
        result = Path("/tmp/example.xcresult")
        self.assertEqual(export_reports(result, cwd="/tmp", run=run), 0)
        command = run.call_args.args[0]
        self.assertEqual(command[-1], "/tmp/example.reports")
        self.assertNotIn("--only-failures", command)
        run.return_value.returncode = 1
        self.assertEqual(export_reports(result, cwd="/tmp", run=run), 1)


if __name__ == "__main__": unittest.main()
