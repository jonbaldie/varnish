#!/usr/bin/env python3
"""Master Campaign Orchestrator for Varnish Bug-Finding."""

import json
import os
import shutil
import signal
import subprocess
import sys
import time

from backend import start_backend
import test_static_analysis
import test_properties
import test_stateful
import test_stress

def wait_for_http(url, timeout=15):
    import urllib.request
    start = time.time()
    while time.time() - start < timeout:
        try:
            with urllib.request.urlopen(url, timeout=2) as resp:
                if resp.status == 200:
                    return True
        except Exception:
            pass
        time.sleep(0.5)
    return False

def main():
    print("******************************************************************")
    print("*    STARTING COMPREHENSIVE VARNISH BUG-FINDING CAMPAIGN         *")
    print("*    (RESOURCE-CAPPED CONTAINER EXECUTION)                       *")
    print("******************************************************************\n")

    # Step 1: Start python backend on 127.0.0.1:8080
    print("[1/5] Initializing Campaign Origin Backend on 127.0.0.1:8080...")
    backend = start_backend(8080)
    time.sleep(1)

    # Step 2: Render backend VCL
    print("[2/5] Rendering backend VCL pointing to 127.0.0.1:8080...")
    env = os.environ.copy()
    env["VARNISH_BACKEND_HOST"] = "127.0.0.1"
    env["VARNISH_BACKEND_PORT"] = "8080"
    env["VARNISH_BACKEND_PROBE_PATH"] = "/ready"
    res = subprocess.run(
        ["/usr/local/bin/render-vcl", "/etc/varnish/backend.vcl"],
        env=env,
        capture_output=True,
        text=True
    )
    if res.returncode != 0:
        print(f"Failed to render VCL: {res.stderr}")
        sys.exit(1)

    # Step 3: Start varnishd with bounded thread pool to respect resource caps
    print("[3/5] Starting varnishd daemon on 127.0.0.1:80...")
    varnish_proc = subprocess.Popen([
        "/usr/sbin/varnishd",
        "-F",
        "-a", "127.0.0.1:80",
        "-f", "/etc/varnish/default.vcl",
        "-s", "malloc,256m",
        "-p", "thread_pools=1",
        "-p", "thread_pool_min=10",
        "-p", "thread_pool_max=50",
        "-p", "default_grace=3600",
        "-p", "vsl_mask=+Hash",
    ], stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    try:
        print("Waiting for Varnish HTTP readiness...")
        if not wait_for_http("http://127.0.0.1:80/ready", timeout=20):
            print("Varnish did not become ready!")
            if varnish_proc.poll() is not None:
                _, err = varnish_proc.communicate()
                print(f"Varnish exited with code {varnish_proc.returncode}: {err.decode()}")
            sys.exit(1)
        print("Varnish is UP and healthy!\n")

        all_reports = {
            "phase1_static_and_boundary": [],
            "phase2_cgpt_properties": [],
            "phase3_stateful_sequences": [],
            "phase4_concurrency_stress": [],
        }

        # Run Phase 1
        all_reports["phase1_static_and_boundary"] = test_static_analysis.run_all()

        # Run Phase 2
        all_reports["phase2_cgpt_properties"] = test_properties.run_all("127.0.0.1", 80, backend)

        # Run Phase 3
        all_reports["phase3_stateful_sequences"] = test_stateful.run_all("127.0.0.1", 80, backend)

        # Run Phase 4 (concurrency stress with 5000 requests across 20 workers)
        all_reports["phase4_concurrency_stress"] = test_stress.run_all("127.0.0.1", 80, num_requests=5000, concurrency=20)

        # Write final report
        with open("/campaign/report.json", "w") as f:
            json.dump(all_reports, f, indent=2)

        print("\n" + "="*70)
        print("                 CAMPAIGN EXECUTION SUMMARY")
        print("="*70)
        total_findings = (
            len(all_reports["phase1_static_and_boundary"]) +
            len(all_reports["phase2_cgpt_properties"]) +
            len(all_reports["phase3_stateful_sequences"]) +
            len(all_reports["phase4_concurrency_stress"])
        )
        print(f"Total Unique Findings / Vulnerabilities Discovered: {total_findings}")
        print(f"  - Phase 1 (Static Analysis & Boundaries):  {len(all_reports['phase1_static_and_boundary'])}")
        print(f"  - Phase 2 (Property-based & Metamorphic):  {len(all_reports['phase2_cgpt_properties'])}")
        print(f"  - Phase 3 (Stateful Sequence Minimizer):   {len(all_reports['phase3_stateful_sequences'])}")
        print(f"  - Phase 4 (Concurrency Stress & Health):   {len(all_reports['phase4_concurrency_stress'])}")
        print("="*70)

    finally:
        print("\nTearing down test processes...")
        if varnish_proc.poll() is None:
            varnish_proc.terminate()
            varnish_proc.wait(timeout=5)

if __name__ == "__main__":
    main()
