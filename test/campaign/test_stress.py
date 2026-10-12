#!/usr/bin/env python3
"""Phase 4: Runtime-Instrumented Concurrency Stress & Memory/Crash Monitoring."""

import concurrent.futures
import http.client
import random
import time

def worker_request(host, port, req_idx):
    methods = ["GET", "GET", "GET", "HEAD", "POST", "PURGE"]
    method = random.choice(methods)
    path_choice = req_idx % 30
    path = f"/stress/resource-{path_choice}.html"
    
    headers = {
        "User-Agent": f"StressWorker/1.0",
        "Accept-Encoding": random.choice(["gzip", "deflate", "gzip, deflate", "identity", ""]),
    }
    if random.random() < 0.3:
        headers["Cookie"] = f"session=user_{random.randint(1, 100)}"
    if random.random() < 0.1:
        # Large header test
        headers["X-Large-Header"] = "A" * 2048

    try:
        conn = http.client.HTTPConnection(host, port, timeout=5)
        conn.request(method, path, headers=headers)
        resp = conn.getresponse()
        resp.read()
        conn.close()
        return resp.status
    except Exception as e:
        return -1

class Workload:
    def __init__(self, requests, statuses, duration):
        self.requests = requests
        self.statuses = statuses
        self.duration = duration

    @property
    def failed_connections(self):
        return self.statuses.get(-1, 0)


class StressResult:
    """Phase 4 outcome: execution status kept apart from Varnish findings.

    "completed" means both health snapshots were available and at least one
    request reached Varnish. Otherwise the phase is "incomplete" and `reasons`
    says why; incomplete runs carry no findings because nothing was measured.
    Partial connection failures are recorded but do not by themselves make a
    run incomplete.
    """

    def __init__(self, workload, initial, final, findings, reasons):
        self.workload = workload
        self.initial = initial
        self.final = final
        self.findings = findings
        self.reasons = reasons

    @property
    def status(self):
        return "incomplete" if self.reasons else "completed"

    def to_dict(self):
        return {
            "status": self.status,
            "reasons": self.reasons,
            "requests": self.workload.requests,
            "failed_connections": self.workload.failed_connections,
            "status_distribution": {str(k): v for k, v in sorted(self.workload.statuses.items())},
            "duration_s": round(self.workload.duration, 3),
            "findings": self.findings,
            "initial_snapshot": self.initial.to_dict(),
            "final_snapshot": self.final.to_dict(),
        }


def run_workload(host, port, num_requests, concurrency):
    start_time = time.time()
    statuses = {}

    print(f"Launching {num_requests} requests across {concurrency} workers...")
    with concurrent.futures.ThreadPoolExecutor(max_workers=concurrency) as executor:
        futures = [
            executor.submit(worker_request, host, port, i)
            for i in range(num_requests)
        ]

        for i, future in enumerate(concurrent.futures.as_completed(futures)):
            status = future.result()
            statuses[status] = statuses.get(status, 0) + 1
            if (i + 1) % 1000 == 0:
                elapsed = time.time() - start_time
                rps = (i + 1) / elapsed
                print(f"Progress: {i + 1}/{num_requests} ({rps:.1f} req/s)")

    return Workload(num_requests, statuses, time.time() - start_time)


def _unavailable_reason(label, snapshot):
    errors = "; ".join(d["error"] for d in snapshot.diagnostics)
    return f"{label} snapshot unavailable: {errors}"


def evaluate(initial, final, workload):
    reasons = []
    if not initial.available:
        reasons.append(_unavailable_reason("initial", initial))
    if not final.available:
        reasons.append(_unavailable_reason("final", final))
    if workload.requests == 0 or workload.failed_connections == workload.requests:
        reasons.append(f"all {workload.requests} requests failed to reach Varnish")
    if reasons:
        return StressResult(workload, initial, final, [], reasons)

    stress_findings = []

    # Check for child panics
    child_panics = final.counters["MGT.child_panic"] - initial.counters["MGT.child_panic"]
    if child_panics > 0:
        print(f"[FATAL BUG] Varnish child panicked {child_panics} times during stress test!")
        stress_findings.append({
            "category": "Crash / Panic",
            "name": f"Varnish child panic detected ({child_panics} panics)",
            "description": f"Varnish experienced {child_panics} internal panics under concurrency stress",
            "severity": "CRITICAL"
        })

    # Check for child process restarts
    child_starts = final.counters["MGT.child_start"] - initial.counters["MGT.child_start"]
    if child_starts > 0:
        print(f"[FATAL BUG] Varnish child restarted {child_starts} times during stress test!")
        stress_findings.append({
            "category": "Crash / Child Restart",
            "name": f"Varnish child process crashed and restarted ({child_starts} restarts)",
            "description": f"Varnish child died and was restarted by the manager process",
            "severity": "CRITICAL"
        })

    # Check memory growth
    init_rss = sum(p["rss_kb"] for p in initial.children)
    fin_rss = sum(p["rss_kb"] for p in final.children)
    mem_growth_mb = (fin_rss - init_rss) / 1024
    print(f"Varnish child RSS growth: {mem_growth_mb:.2f} MB")
    if mem_growth_mb > 500:
        print(f"[BUG] Excessive memory growth during stress test: {mem_growth_mb:.2f} MB")
        stress_findings.append({
            "category": "Memory Leak",
            "name": f"Excessive memory growth under load (+{mem_growth_mb:.1f}MB)",
            "description": f"Varnish RSS memory grew by {mem_growth_mb:.1f}MB over {workload.requests} requests",
            "severity": "MEDIUM"
        })

    return StressResult(workload, initial, final, stress_findings, [])


def run_all(runtime, num_requests=5000, concurrency=20):
    print("==================================================================")
    print(f"PHASE 4: Runtime-Instrumented Concurrency Stress ({num_requests} reqs, c={concurrency})")
    print("==================================================================")

    initial = runtime.snapshot()
    print(f"Initial Varnish health: {initial.to_dict()}")

    workload = run_workload(runtime.host, runtime.port, num_requests, concurrency)

    final = runtime.snapshot()
    duration = max(workload.duration, 1e-9)
    print(f"\nCompleted in {workload.duration:.2f}s ({num_requests/duration:.1f} req/s)")
    print(f"Status distribution: {workload.statuses}")
    print(f"Final Varnish health: {final.to_dict()}")
    if workload.failed_connections:
        print(f"[!] {workload.failed_connections} connection errors occurred out of {num_requests}")

    result = evaluate(initial, final, workload)
    for reason in result.reasons:
        print(f"[INCOMPLETE] {reason}")
    print(f"\nPhase 4 {result.status}. Stress findings: {len(result.findings)}")
    return result
