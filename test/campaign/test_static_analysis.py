#!/usr/bin/env python3
"""Phase 1: Static Analysis & Boundary/Mutation Fuzzing for Varnish container scripts."""

import os
import re
import shutil
import subprocess
import sys
import tempfile

class Finding:
    def __init__(self, category, name, description, reproducer, severity="MEDIUM"):
        self.category = category
        self.name = name
        self.description = description
        self.reproducer = reproducer
        self.severity = severity

    def to_dict(self):
        return {
            "category": self.category,
            "name": self.name,
            "description": self.description,
            "reproducer": self.reproducer,
            "severity": self.severity,
        }

findings = []

def run_cmd(cmd, env=None, timeout=10):
    try:
        res = subprocess.run(
            cmd,
            shell=True,
            capture_output=True,
            text=True,
            env=env or os.environ,
            timeout=timeout,
        )
        return res.returncode, res.stdout, res.stderr
    except subprocess.TimeoutExpired:
        return 124, "", "Timed out"

def test_shellcheck():
    print("--- Running ShellCheck on repository scripts ---")
    scripts = [
        "/usr/local/bin/render-vcl",
        "/start.sh",
        "render-vcl.sh",
        "start.sh",
        "install.sh",
    ]
    for s in scripts:
        if os.path.isfile(s):
            rc, out, err = run_cmd(f"shellcheck -s bash {s}")
            if rc != 0:
                print(f"[!] Shellcheck issues in {s}:\n{out}")
                findings.append(Finding(
                    category="Static Analysis",
                    name=f"ShellCheck warning in {s}",
                    description=out.strip(),
                    reproducer=f"shellcheck -s bash {s}",
                    severity="LOW"
                ))
            else:
                print(f"[+] Shellcheck clean: {s}")

def test_render_vcl_ports():
    print("--- Fuzzing render-vcl VARNISH_BACKEND_PORT boundaries ---")
    test_cases = [
        ("0", "Port 0 (reserved / invalid port)", True),
        ("65535", "Port 65535 (max valid port)", False),
        ("65536", "Port 65536 (out of range)", True),
        ("-1", "Negative port", True),
        ("8080a", "Alphanumeric port suffix", True),
        ("abc", "Non-numeric port", True),
        ("", "Empty port (should default or reject)", False),
        ("80 80", "Port with space", True),
        ("8080\nprobe injected {", "Port with newline injection", True),
        ("99999999999999", "Huge port number", True),
    ]

    for port, label, expect_error in test_cases:
        tmp = tempfile.NamedTemporaryFile(delete=False, suffix=".vcl")
        tmp.close()
        try:
            env = os.environ.copy()
            env["VARNISH_BACKEND_PORT"] = port
            rc, out, err = run_cmd(f"/usr/local/bin/render-vcl {tmp.name}", env=env)
            
            if expect_error and rc == 0:
                # Script succeeded, but does VCL compile?
                vcl_rc, vcl_out, vcl_err = run_cmd(f"varnishd -C -f {tmp.name}")
                if vcl_rc != 0:
                    print(f"[BUG] render-vcl allowed invalid port '{port}' ({label}) producing invalid VCL: {vcl_err.strip()}")
                    findings.append(Finding(
                        category="Input Validation / Boundary",
                        name=f"render-vcl allows invalid port: {port}",
                        description=f"render-vcl permitted VARNISH_BACKEND_PORT='{port}' ({label}), which leads to VCL compilation failure or runtime error: {vcl_err.strip()}",
                        reproducer=f"VARNISH_BACKEND_PORT='{port}' /usr/local/bin/render-vcl /tmp/test.vcl && varnishd -C -f /tmp/test.vcl",
                        severity="HIGH" if "injection" in label or int(port) > 65535 or int(port) == 0 else "MEDIUM"
                    ))
                else:
                    # If port 0 or 65536 actually compiled, that's also unexpected for valid TCP
                    if port in ("0", "65536", "99999999999999"):
                        findings.append(Finding(
                            category="Input Validation / Boundary",
                            name=f"render-vcl allows out-of-range TCP port: {port}",
                            description=f"VARNISH_BACKEND_PORT='{port}' is out of valid TCP port range (1-65535) but was rendered into VCL without validation",
                            reproducer=f"VARNISH_BACKEND_PORT='{port}' /usr/local/bin/render-vcl /tmp/test.vcl",
                            severity="MEDIUM"
                        ))
            elif not expect_error and rc != 0:
                print(f"[!] Valid port '{port}' ({label}) was unexpectedly rejected: {err.strip()}")
        finally:
            if os.path.exists(tmp.name):
                os.unlink(tmp.name)

def test_render_vcl_host_injections():
    print("--- Fuzzing render-vcl VARNISH_BACKEND_HOST injections & special chars ---")
    payloads = [
        ("127.0.0.1", "Standard IPv4", False),
        ("localhost", "Standard hostname", False),
        ("web-service.internal", "Domain name", False),
        ("127.0.0.1\";\n} sub vcl_recv {\n#", "VCL block injection via newline and quote", True),
        ("127.0.0.1\n.probe = none;", "VCL newline property injection", True),
        ('host"with"quotes', "Host containing quotes", True),
        ('host\\with\\backslashes', "Host containing backslashes", False),
        ('host with spaces', "Host with spaces", True),
        ('127.0.0.1; }; sub vcl_init {', "Semicolon injection", True),
        ('::1', "IPv6 loopback", False),
        ('[::1]', "IPv6 loopback bracketed", False),
    ]

    for host, label, is_hostile in payloads:
        tmp = tempfile.NamedTemporaryFile(delete=False, suffix=".vcl")
        tmp.close()
        try:
            env = os.environ.copy()
            env["VARNISH_BACKEND_HOST"] = host
            rc, out, err = run_cmd(f"/usr/local/bin/render-vcl {tmp.name}", env=env)
            
            # Check what was rendered
            if os.path.exists(tmp.name):
                with open(tmp.name, "r") as f:
                    content = f.read()

                # Test compilation
                vcl_rc, vcl_out, vcl_err = run_cmd(f"varnishd -C -f {tmp.name}")
                
                # Check for newline injection: does render-vcl prevent multi-line injection?
                if "\n" in host and rc == 0:
                    print(f"[BUG] render-vcl does not escape or reject newlines in VARNISH_BACKEND_HOST: '{host}'")
                    findings.append(Finding(
                        category="VCL Injection / Sanitization",
                        name="VARNISH_BACKEND_HOST newline injection vulnerability",
                        description=f"render-vcl.sh allows unescaped newlines in VARNISH_BACKEND_HOST, enabling VCL syntax corruption or arbitrary VCL directive injection. Rendered content:\n{content}",
                        reproducer=f"VARNISH_BACKEND_HOST=$'127.0.0.1\\n.probe = none;' /usr/local/bin/render-vcl /tmp/backend.vcl",
                        severity="HIGH"
                    ))
        finally:
            if os.path.exists(tmp.name):
                os.unlink(tmp.name)

def test_start_script_boundaries():
    print("--- Fuzzing start.sh validation logic ---")
    cases = [
        ({"VARNISH_LISTEN": ":80"}, "Listen missing host (:80)"),
        ({"VARNISH_LISTEN": "localhost:"}, "Listen missing port (localhost:)"),
        ({"VARNISH_LISTEN": "0.0.0.0:abc"}, "Listen non-numeric port"),
        ({"VARNISH_STORAGE": "malloc,"}, "Storage missing size (malloc,)"),
        ({"VARNISH_STORAGE": ",1g"}, "Storage missing type (,1g)"),
        ({"VARNISH_STORAGE": "unknown_backend,1g"}, "Storage invalid backend"),
        ({"VARNISH_START": "echo 1", "VARNISH_LISTEN": "0.0.0.0:80"}, "VARNISH_START conflict with LISTEN"),
        ({"VARNISH_START": "echo 1", "VARNISH_EXTRA_ARGS": "-p foo=bar"}, "VARNISH_START conflict with EXTRA_ARGS"),
        ({"VARNISH_VCL": "/nonexistent.vcl"}, "Nonexistent VARNISH_VCL"),
    ]

    for env_override, label in cases:
        env = os.environ.copy()
        env.update(env_override)
        # Run start.sh with timeout
        rc, out, err = run_cmd("/start.sh", env=env, timeout=3)
        
        # We expect validation failures to exit non-zero quickly with an ERROR message
        if "conflict" in label or "Nonexistent" in label:
            if rc == 0:
                findings.append(Finding(
                    category="Input Validation",
                    name=f"start.sh failed to reject: {label}",
                    description=f"Expected startup rejection for {env_override}, but exit code was 0",
                    reproducer=f"{' '.join(f'{k}={v}' for k, v in env_override.items())} /start.sh",
                    severity="HIGH"
                ))
        elif "missing" in label or "non-numeric" in label:
            # Check if start.sh caught it or passed it down to varnishd
            combined = out + err
            if "Invalid VARNISH_LISTEN" not in combined and "Invalid VARNISH_STORAGE" not in combined:
                # start.sh regex missed it
                print(f"[FINDING] start.sh validation does not catch {label}: {env_override}")
                findings.append(Finding(
                    category="Input Validation",
                    name=f"start.sh weak validation on {label}",
                    description=f"start.sh accepted malformed configuration {env_override} instead of failing fast before invoking varnishd",
                    reproducer=f"{' '.join(f'{k}={v}' for k, v in env_override.items())} /start.sh",
                    severity="LOW"
                ))

def run_all():
    print("==================================================")
    print("PHASE 1: Static Analysis & Input Boundary Fuzzing")
    print("==================================================")
    test_shellcheck()
    test_render_vcl_ports()
    test_render_vcl_host_injections()
    test_start_script_boundaries()
    print(f"\nPhase 1 Complete. Findings: {len(findings)}")
    return [f.to_dict() for f in findings]

if __name__ == "__main__":
    import json
    res = run_all()
    print(json.dumps(res, indent=2))
