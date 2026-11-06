#!/usr/bin/env python3
"""Real subprocess checks for campaign command evidence."""

import json
import os
import socket
import sys
import tempfile

from orchestrator import CampaignReport
from phase_result import run_phase
from test_static_analysis import (
    check_runtime_config, run_cmd, test_config_check_rejects_unresolvable_backend,
    test_render_vcl_ports, test_shellcheck, test_start_script_boundaries,
)


def main():
    with tempfile.TemporaryDirectory() as directory:
        old_path = os.environ.get("PATH", "")
        os.environ["PATH"] = directory
        try:
            missing = run_phase(test_shellcheck)
        finally:
            os.environ["PATH"] = old_path
        assert missing.status != "completed", missing.to_dict()
        assert not missing.findings, missing.to_dict()
        diagnostic = json.dumps(missing.diagnostics)
        assert "shellcheck" in diagnostic.lower(), diagnostic
        assert "No such file" in diagnostic, diagnostic

    timeout = run_cmd([sys.executable, "-c", "import sys,time; print('out-marker',flush=True); print('err-marker',file=sys.stderr,flush=True); time.sleep(5)"], timeout=0.3)
    assert timeout.status == "timeout", timeout
    assert timeout.stdout == "out-marker\n", timeout
    assert timeout.stderr == "err-marker\n", timeout
    assert timeout.returncode is None, timeout
    terminated = run_cmd([sys.executable, "-c", "import os,signal; os.kill(os.getpid(), signal.SIGTERM)"])
    killed_phase = run_phase(lambda findings: terminated.require_execution())
    assert killed_phase.status == "error", killed_phase.to_dict()
    assert terminated.returncode == -15, terminated
    ordinary = run_cmd([sys.executable, "-c", "import sys; print('No such file or directory', file=sys.stderr)"])
    assert ordinary.require_execution().returncode == 0, ordinary

    with tempfile.TemporaryDirectory() as directory:
        original_dir = os.getcwd()
        original_path = os.environ.get("PATH", "")
        with open(os.path.join(directory, "render-vcl.sh"), "w") as script:
            script.write('#!/bin/bash\necho $value\n')
        with open(os.path.join(directory, "start.sh"), "w") as script:
            script.write('#!/bin/bash\nprintf "hello\\n"\n')
        os.chdir(directory)
        try:
            def collect_then_fail(findings):
                test_shellcheck(findings)
                os.environ["PATH"] = directory
                test_shellcheck(findings)

            result = run_phase(collect_then_fail)
        finally:
            os.environ["PATH"] = original_path
            os.chdir(original_dir)
        assert result.status == "error", result.to_dict()
        assert any("SC2086" in finding["description"] for finding in result.findings), result.to_dict()
        assert not any(finding["name"] == "ShellCheck warning in start.sh" for finding in result.findings), result.to_dict()
        report_path = os.path.join(directory, "report.json")
        report = CampaignReport(report_path)
        report.record("phase1_static_and_boundary", result.to_dict())
        with open(report_path) as report_file:
            persisted = json.load(report_file)
        assert any("SC2086" in finding["description"] for finding in persisted["phase1_static_and_boundary"]["findings"])
        assert persisted["phase2_cgpt_properties"]["status"] == "not-run"

    if os.environ.get("CAMPAIGN_DISPOSABLE_CONTAINER") == "1":
        renderer = "/usr/local/bin/render-vcl"
        hidden = renderer + ".issue166-test"
        os.rename(renderer, hidden)
        try:
            result = run_phase(test_render_vcl_ports)
            assert result.status == "error", result.to_dict()
            assert not result.findings, result.to_dict()
            assert "render-vcl" in json.dumps(result.diagnostics), result.to_dict()
        finally:
            os.rename(hidden, renderer)

        startup = "/start.sh"
        hidden = startup + ".issue166-test"
        os.rename(startup, hidden)
        try:
            result = run_phase(lambda findings: check_runtime_config(os.environ.copy()))
            assert result.status == "error", result.to_dict()
            assert not result.findings, result.to_dict()
            assert "/start.sh" in json.dumps(result.diagnostics), result.to_dict()
        finally:
            os.rename(hidden, startup)

        compiler = "/usr/sbin/varnishd"
        hidden = compiler + ".issue166-test"
        os.rename(compiler, hidden)
        try:
            result = run_phase(lambda findings: check_runtime_config(os.environ.copy()))
            assert result.status == "error", result.to_dict()
            assert not result.findings, result.to_dict()
            assert "127" in json.dumps(result.diagnostics), result.to_dict()
        finally:
            os.rename(hidden, compiler)

        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            listener.listen()
            env = {**os.environ, "VARNISH_LISTEN": f"127.0.0.1:{listener.getsockname()[1]}",
                   "VARNISH_BACKEND_HOST": "127.0.0.1"}
            result = check_runtime_config(env)
            assert result.returncode == 0, result

        old_start = os.environ.get("VARNISH_START")
        os.environ["VARNISH_START"] = "true"
        try:
            result = run_phase(test_start_script_boundaries)
        finally:
            if old_start is None:
                del os.environ["VARNISH_START"]
            else:
                os.environ["VARNISH_START"] = old_start
        assert result.status == "completed", result.to_dict()
        assert not result.findings, result.to_dict()

        vcl = "/etc/varnish/default.vcl"
        hidden = vcl + ".issue166-test"
        os.rename(vcl, hidden)
        try:
            for test in (test_start_script_boundaries, test_config_check_rejects_unresolvable_backend):
                result = run_phase(test)
                assert result.status == "error", result.to_dict()
                assert not result.findings, result.to_dict()
                assert "VARNISH_VCL" in json.dumps(result.diagnostics), result.to_dict()
        finally:
            os.rename(hidden, vcl)

        result = run_cmd([renderer, os.path.join(tempfile.gettempdir(), "unused.vcl")],
                         env={**os.environ, "VARNISH_BACKEND_PORT": "0"})
        assert result.status == "exited" and result.returncode != 0, result
        assert "Invalid VARNISH_BACKEND_PORT" in result.stderr, result

    print("Command result checks passed")


if __name__ == "__main__":
    main()
