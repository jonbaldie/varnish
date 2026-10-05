#!/usr/bin/env python3
"""Checks that the campaign starts Varnish through the image's /start.sh.

Runs inside the campaign image against the real start script, render-vcl and
varnishd. Exits non-zero on the first failed check.
"""

import os
import subprocess
import sys

from backend import start_backend
from varnish_runtime import start_varnish, wait_until_ready

READY_URL = "http://127.0.0.1:80/ready"


def fail(message):
    print(f"FAIL: {message}")
    sys.exit(1)


def param_value(name):
    out = subprocess.run(
        ["varnishadm", "param.show", name],
        capture_output=True, text=True, check=True,
    ).stdout
    # Looks like: "        Value is: 50 [threads]"
    for line in out.splitlines():
        if line.strip().startswith("Value is:"):
            return line.split(":", 1)[1].split()[0]
    fail(f"no value in param.show {name}: {out}")


def stop(proc):
    if proc.poll() is None:
        proc.terminate()
        proc.wait(timeout=10)


def check_starts_with_campaign_parameters():
    # An inherited VARNISH_START would make start.sh refuse the other variables.
    os.environ["VARNISH_START"] = "false"
    proc = start_varnish()
    try:
        error = wait_until_ready(proc, READY_URL, timeout=20)
        if error:
            fail(f"campaign Varnish did not start: {error}")

        cmdline = open(f"/proc/{proc.pid}/cmdline").read().split("\0")
        if not cmdline[0].endswith("varnishd"):
            fail(f"start.sh did not exec varnishd; pid {proc.pid} runs {cmdline}")
        for flag, value in (("-a", "127.0.0.1:80"), ("-s", "malloc,256m")):
            if cmdline[cmdline.index(flag) + 1] != value:
                fail(f"varnishd {flag} is {cmdline[cmdline.index(flag) + 1]}, expected {value}")

        expected = {
            "thread_pools": "1",
            "thread_pool_min": "10",
            "thread_pool_max": "50",
            "default_grace": "3600.000",
        }
        for name, value in expected.items():
            actual = param_value(name)
            if actual != value:
                fail(f"{name} is {actual}, expected {value}")
        # The default mask contains -Hash; +Hash removes it.
        vsl_mask = param_value("vsl_mask").split(",")
        if "-Hash" in vsl_mask:
            fail(f"vsl_mask still masks Hash records: {vsl_mask}")
        print("OK: start.sh ran varnishd with the campaign listen, storage and parameters")
    finally:
        stop(proc)
        del os.environ["VARNISH_START"]


def check_reports_start_script_errors():
    proc = start_varnish({"VARNISH_STORAGE": "malloc"})
    try:
        error = wait_until_ready(proc, READY_URL, timeout=20)
        if error is None:
            fail("Varnish became ready despite an invalid VARNISH_STORAGE")
        if "Invalid VARNISH_STORAGE 'malloc'" not in error:
            fail(f"start.sh error missing from report: {error}")
        print(f"OK: invalid VARNISH_STORAGE reported: {error.strip()}")
    finally:
        stop(proc)


def main():
    start_backend(8080)
    check_starts_with_campaign_parameters()
    check_reports_start_script_errors()
    print("=== Campaign Varnish runtime check PASSED ===")


if __name__ == "__main__":
    main()
