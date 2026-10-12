#!/usr/bin/env python3
"""Checked runtime health for the campaign's Varnish instance.

The orchestrator starts Varnish once through /start.sh. Startup readiness and
the stress phase both inspect that same VarnishRuntime, so "Varnish is live and
measurable" has one meaning across the campaign.

A HealthSnapshot is either available, with every required counter read as an
integer from this instance and its manager and child processes identified, or
unavailable, with diagnostics explaining why. Missing data is never replaced by
a numeric default.
"""

import os
import subprocess
import tempfile
import time
import urllib.request

REQUIRED_COUNTERS = (
    "MAIN.uptime",
    "MAIN.n_object",
    "MGT.child_panic",
    "MGT.child_start",
    "MAIN.sess_conn",
)

VARNISHSTAT_TIMEOUT = 10


class HealthSnapshot:
    def __init__(self, counters, manager_pid, children, diagnostics):
        self.counters = counters
        self.manager_pid = manager_pid
        self.children = children
        self.diagnostics = diagnostics

    @property
    def available(self):
        return not self.diagnostics

    def to_dict(self):
        return {
            "available": self.available,
            "counters": self.counters,
            "manager_pid": self.manager_pid,
            "children": self.children,
            "diagnostics": self.diagnostics,
        }


class VarnishRuntime:
    """The campaign's Varnish, started by /start.sh, which execs varnishd -F."""

    def __init__(self, host, port, process, output):
        self.host = host
        self.port = port
        self.process = process
        self.output = output

    @classmethod
    def start(cls, host, port, varnish_env):
        """Run /start.sh listening on host:port unless varnish_env overrides VARNISH_LISTEN."""
        env = os.environ.copy()
        # start.sh refuses VARNISH_START alongside the other VARNISH_* variables.
        env.pop("VARNISH_START", None)
        env["VARNISH_LISTEN"] = f"{host}:{port}"
        env.update(varnish_env)
        # A file rather than a pipe: nobody drains varnishd -F while it runs.
        output = tempfile.TemporaryFile()
        process = subprocess.Popen(["/start.sh"], env=env, stdout=output, stderr=subprocess.STDOUT)
        return cls(host, port, process, output)

    @property
    def pid(self):
        return self.process.pid

    def exit_status(self):
        """None while start.sh/varnishd runs, otherwise its exit code."""
        return self.process.poll()

    def wait_ready(self, path="/ready", timeout=20):
        url = f"http://{self.host}:{self.port}{path}"
        deadline = time.time() + timeout
        while time.time() < deadline:
            if self.exit_status() is not None:
                return False
            try:
                with urllib.request.urlopen(url, timeout=2) as resp:
                    if resp.status == 200:
                        return True
            except Exception:
                pass
            time.sleep(0.5)
        return False

    def start_output(self, limit=4096):
        """The tail of start.sh/varnishd's combined stdout and stderr."""
        self.output.seek(0)
        return self.output.read().decode(errors="replace")[-limit:].strip()

    def snapshot(self):
        diagnostics = []
        exit_status = self.exit_status()
        if exit_status is not None:
            diagnostics.append({
                "collector": "process",
                "error": f"start.sh exited with code {exit_status}",
                "returncode": exit_status,
                "stderr": self.start_output(),
            })

        counters = _read_counters(diagnostics)
        children = []
        if exit_status is None:
            children = _read_children(self.pid, diagnostics)

        if diagnostics:
            # Partial counters are not evidence of health. Children stay as
            # process diagnostics; they feed no finding unless available.
            counters = {}
        return HealthSnapshot(counters, self.pid, children, diagnostics)

    def stop(self):
        if self.exit_status() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)


def _read_counters(diagnostics):
    # -f takes one glob per flag; a comma-joined list matches nothing.
    argv = ["varnishstat", "-1", "-t", "2"]
    for name in REQUIRED_COUNTERS:
        argv += ["-f", name]
    try:
        res = subprocess.run(argv, capture_output=True, text=True, timeout=VARNISHSTAT_TIMEOUT)
    except subprocess.TimeoutExpired as exc:
        diagnostics.append({
            "collector": "varnishstat",
            "argv": argv,
            "error": f"timeout after {VARNISHSTAT_TIMEOUT}s",
            "stderr": _text(exc.stderr),
        })
        return {}
    except OSError as exc:
        diagnostics.append({"collector": "varnishstat", "argv": argv, "error": str(exc)})
        return {}

    if res.returncode != 0:
        diagnostics.append({
            "collector": "varnishstat",
            "argv": argv,
            "returncode": res.returncode,
            "stderr": res.stderr.strip(),
            "error": "varnishstat exited non-zero",
        })
        return {}

    counters = {}
    problems = []
    seen = set()
    for line in res.stdout.splitlines():
        parts = line.split()
        if len(parts) < 2 or parts[0] not in REQUIRED_COUNTERS:
            continue
        seen.add(parts[0])
        if parts[1].isdigit():
            counters[parts[0]] = int(parts[1])
        else:
            problems.append(f"{parts[0]} is not an integer: {parts[1]!r}")
    missing = [name for name in REQUIRED_COUNTERS if name not in seen]
    if missing:
        problems.append(f"missing counters: {', '.join(missing)}")
    if problems:
        diagnostics.append({
            "collector": "varnishstat",
            "argv": argv,
            "returncode": res.returncode,
            "stderr": res.stderr.strip(),
            "error": "; ".join(problems),
        })
        return {}
    return counters


def _read_children(manager_pid, diagnostics):
    """Processes whose parent is this runtime's varnishd manager."""
    children = []
    try:
        pids = [entry for entry in os.listdir("/proc") if entry.isdigit()]
    except OSError as exc:
        diagnostics.append({"collector": "proc", "error": str(exc)})
        return []
    for pid in pids:
        status = _proc_status(pid)
        if status is None or status.get("PPid") != str(manager_pid):
            continue
        rss = status.get("VmRSS", "").split()
        if not rss or not rss[0].isdigit():
            continue
        children.append({"pid": int(pid), "name": status.get("Name", ""), "rss_kb": int(rss[0])})
    if len(children) != 1:
        diagnostics.append({
            "collector": "proc",
            "error": f"expected one varnishd child of manager {manager_pid}, found {len(children)}",
            "children": children,
        })
    return children


def _proc_status(pid):
    try:
        with open(f"/proc/{pid}/status") as fh:
            fields = {}
            for line in fh:
                key, _, value = line.partition(":")
                fields[key] = value.strip()
            return fields
    except OSError:
        # The process exited between listing and reading.
        return None


def _text(value):
    if value is None:
        return ""
    if isinstance(value, bytes):
        return value.decode(errors="replace").strip()
    return value.strip()
