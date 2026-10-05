#!/usr/bin/env python3
"""Master Campaign Orchestrator for Varnish Bug-Finding."""

import json
import sys
import time

from backend import start_backend
from varnish_runtime import start_varnish, wait_until_ready
import test_static_analysis
import test_properties
import test_stateful
import test_stress

def main():
    print("******************************************************************")
    print("*    STARTING COMPREHENSIVE VARNISH BUG-FINDING CAMPAIGN         *")
    print("*    (RESOURCE-CAPPED CONTAINER EXECUTION)                       *")
    print("******************************************************************\n")

    # Step 1: Start python backend on 127.0.0.1:8080
    print("[1/2] Initializing Campaign Origin Backend on 127.0.0.1:8080...")
    backend = start_backend(8080)
    time.sleep(1)

    # Step 2: Start Varnish through the image's runtime start interface
    print("[2/2] Starting Varnish via /start.sh on 127.0.0.1:80 (origin 127.0.0.1:8080)...")
    varnish_proc = start_varnish()

    try:
        print("Waiting for Varnish HTTP readiness...")
        error = wait_until_ready(varnish_proc, "http://127.0.0.1:80/ready", timeout=20)
        if error:
            print(f"Varnish did not become ready: {error}")
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
