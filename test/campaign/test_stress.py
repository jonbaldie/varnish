#!/usr/bin/env python3
"""Phase 4: Runtime-Instrumented Concurrency Stress & Memory/Crash Monitoring."""

import concurrent.futures
import http.client
import json
import os
import random
import subprocess
import time

def get_varnish_stats():
    try:
        res = subprocess.run(
            ["varnishstat", "-1", "-f", "MAIN.uptime,MAIN.n_object,MAIN.child_panic,MAIN.child_start,MAIN.sess_conn"],
            capture_output=True,
            text=True,
            timeout=5
        )
        stats = {}
        for line in res.stdout.strip().splitlines():
            parts = line.split()
            if len(parts) >= 2:
                stats[parts[0]] = int(parts[1]) if parts[1].isdigit() else parts[1]
        return stats
    except Exception as e:
        return {"error": str(e)}

def get_process_memory():
    try:
        res = subprocess.run(
            ["ps", "-eo", "pid,comm,rss,%cpu"],
            capture_output=True,
            text=True,
            timeout=5
        )
        procs = []
        for line in res.stdout.strip().splitlines()[1:]:
            parts = line.split()
            if len(parts) >= 4 and "varnish" in parts[1]:
                procs.append({
                    "pid": parts[0],
                    "name": parts[1],
                    "rss_kb": int(parts[2]),
                    "cpu_pct": parts[3]
                })
        return procs
    except Exception as e:
        return []

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

def run_all(varnish_host="127.0.0.1", varnish_port=80, num_requests=5000, concurrency=20):
    print("==================================================================")
    print(f"PHASE 4: Runtime-Instrumented Concurrency Stress ({num_requests} reqs, c={concurrency})")
    print("==================================================================")

    initial_stats = get_varnish_stats()
    initial_mem = get_process_memory()
    print(f"Initial Varnish Stats: {initial_stats}")
    print(f"Initial Varnish Memory: {initial_mem}")

    start_time = time.time()
    statuses = {}
    failed_conns = 0

    print(f"Launching {num_requests} requests across {concurrency} workers...")
    with concurrent.futures.ThreadPoolExecutor(max_workers=concurrency) as executor:
        futures = [
            executor.submit(worker_request, varnish_host, varnish_port, i)
            for i in range(num_requests)
        ]
        
        for i, future in enumerate(concurrent.futures.as_completed(futures)):
            status = future.result()
            statuses[status] = statuses.get(status, 0) + 1
            if status == -1:
                failed_conns += 1
            if (i + 1) % 1000 == 0:
                elapsed = time.time() - start_time
                rps = (i + 1) / elapsed
                print(f"Progress: {i + 1}/{num_requests} ({rps:.1f} req/s)")

    duration = time.time() - start_time
    final_stats = get_varnish_stats()
    final_mem = get_process_memory()

    print(f"\nCompleted in {duration:.2f}s ({num_requests/duration:.1f} req/s)")
    print(f"Status distribution: {statuses}")
    print(f"Final Varnish Stats: {final_stats}")
    print(f"Final Varnish Memory: {final_mem}")

    stress_findings = []
    
    # Check for child panics
    child_panics = final_stats.get("MAIN.child_panic", 0) - initial_stats.get("MAIN.child_panic", 0)
    if child_panics > 0:
        print(f"[FATAL BUG] Varnish child panicked {child_panics} times during stress test!")
        stress_findings.append({
            "category": "Crash / Panic",
            "name": f"Varnish child panic detected ({child_panics} panics)",
            "description": f"Varnish experienced {child_panics} internal panics under concurrency stress",
            "severity": "CRITICAL"
        })

    # Check for child process restarts
    child_starts = final_stats.get("MAIN.child_start", 1) - initial_stats.get("MAIN.child_start", 1)
    if child_starts > 0:
        print(f"[FATAL BUG] Varnish child restarted {child_starts} times during stress test!")
        stress_findings.append({
            "category": "Crash / Child Restart",
            "name": f"Varnish child process crashed and restarted ({child_starts} restarts)",
            "description": f"Varnish child died and was restarted by the manager process",
            "severity": "CRITICAL"
        })

    # Check memory growth
    if initial_mem and final_mem:
        init_rss = sum(p["rss_kb"] for p in initial_mem)
        fin_rss = sum(p["rss_kb"] for p in final_mem)
        mem_growth_mb = (fin_rss - init_rss) / 1024
        print(f"Total Varnish RSS growth: {mem_growth_mb:.2f} MB")
        if mem_growth_mb > 500:
            print(f"[BUG] Excessive memory growth during stress test: {mem_growth_mb:.2f} MB")
            stress_findings.append({
                "category": "Memory Leak",
                "name": f"Excessive memory growth under load (+{mem_growth_mb:.1f}MB)",
                "description": f"Varnish RSS memory grew by {mem_growth_mb:.1f}MB over {num_requests} requests",
                "severity": "MEDIUM"
            })

    if failed_conns > 0:
        print(f"[!] {failed_conns} connection errors occurred out of {num_requests}")

    print(f"\nPhase 4 Complete. Stress findings: {len(stress_findings)}")
    return stress_findings

if __name__ == "__main__":
    res = run_all("127.0.0.1", 80, num_requests=2000, concurrency=10)
    print(json.dumps(res, indent=2))
