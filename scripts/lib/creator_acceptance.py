"""Bound expensive creator runs to explicit test suites and export structured evidence."""
import math
import subprocess
from .creator_live_smoke import ConfigurationError


def benchmark_number(environ, name, default, minimum, maximum):
    bare, prefixed = environ.get(name), environ.get("TEST_RUNNER_" + name)
    if bare is not None and prefixed is not None and bare != prefixed:
        raise ConfigurationError("Conflicting creator benchmark timing settings.")
    try:
        value = float(prefixed if prefixed is not None else bare if bare is not None else default)
    except ValueError:
        raise ConfigurationError("Invalid creator benchmark timing settings.") from None
    if not math.isfinite(value) or not minimum <= value <= maximum:
        raise ConfigurationError("Creator benchmark allowance needs 600..86400 seconds and request timeout needs 5..600 seconds.")
    return value


def rounded_allowance(seconds):
    # XCTest rounds the case's preferred allowance up to the next whole minute.
    return max(6000, math.ceil(seconds / 60) * 60)


def allowance(environ, only=None, *, ui=False, python_only=False):
    if environ.get("TEST_RUNNER_CREATOR_BENCHMARK") == "1":
        # LiveSmoke validates suite and credentials before any child is launched.
        seconds = benchmark_number(environ, "CREATOR_BENCHMARK_ALLOWANCE", 3600, 600, 86400)
        benchmark_number(environ, "CREATOR_LIVE_TIMEOUT", 90, 5, 600)
        return rounded_allowance(seconds)
    if environ.get("TEST_RUNNER_CREATOR_SOAK") != "1":
        return None
    selected = [value.removeprefix("WallpaperMachineTests/") for value in (only or [])]
    if ui or python_only or selected not in [["CreatorSoakLiveTests"], ["CreatorSoakLiveTests/testThirtyMinuteSoak"]]:
        raise ConfigurationError("Creator soak requires --only CreatorSoakLiveTests; a full/UI gate cannot opt in.")
    try:
        seconds = float(environ.get("TEST_RUNNER_CREATOR_SOAK_SECONDS", "1800"))
        interval = float(environ.get("TEST_RUNNER_CREATOR_SOAK_INTERVAL", "10"))
    except ValueError:
        raise ConfigurationError("Invalid creator soak duration or sampling interval.") from None
    if not (math.isfinite(seconds) and math.isfinite(interval) and 1 <= seconds <= 86400
            and 0.1 <= interval <= min(60, seconds) and seconds / interval <= 10000):
        raise ConfigurationError("Creator soak needs 1..86400 seconds, a 0.1..60 second interval, and at most 10000 samples per template.")
    return rounded_allowance(max(seconds + 600, 2400))


def export_reports(result, *, cwd, run=subprocess.run):
    destination = result.with_suffix(".reports")
    completed = run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(result),
                     "--output-path", str(destination)], cwd=cwd, capture_output=True, text=True)
    if completed.returncode:
        # Never echo Xcode's environment or raw tool error text.
        print("Creator evidence export failed; attachments remain in the xcresult bundle.", flush=True)
    else:
        print(f"Creator structured reports: {destination}", flush=True)
    return completed.returncode
