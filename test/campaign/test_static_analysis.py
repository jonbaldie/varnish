#!/usr/bin/env python3
"""Phase 1: Static Analysis & Boundary/Mutation Fuzzing for Varnish container scripts."""

import os
import re
import socket
import subprocess
import tempfile
from dataclasses import dataclass

from phase_result import run_phase

RESOLUTION_ERROR = r"failed to resolve|could not resolve|could not be resolved|name or service not known|no address associated"

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


@dataclass(frozen=True)
class CommandResult:
    command: tuple
    status: str
    returncode: int | None
    stdout: str
    stderr: str

    def require_execution(self):
        if (self.status != "exited" or self.returncode < 0
                or self.returncode in (126, 127)):
            raise RuntimeError(f"Command execution failed: {self}")
        return self


def _text(value):
    if isinstance(value, bytes):
        return value.decode(errors="replace")
    return value or ""


def run_cmd(cmd, env=None, timeout=10):
    command = tuple(cmd)
    try:
        res = subprocess.run(
            command, capture_output=True, text=True, env=env, timeout=timeout,
        )
        return CommandResult(command, "exited", res.returncode, res.stdout, res.stderr)
    except subprocess.TimeoutExpired as exc:
        return CommandResult(command, "timeout", None, _text(exc.stdout), _text(exc.stderr))
    except OSError as exc:
        return CommandResult(command, "launch-error", None, "", str(exc))

def test_shellcheck(findings):
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
            result = run_cmd(["shellcheck", "-s", "bash", s]).require_execution()
            if result.returncode not in (0, 1):
                raise RuntimeError(f"ShellCheck could not analyze {s}: {result}")
            if result.returncode == 1:
                print(f"[!] Shellcheck issues in {s}:\n{result.stdout}")
                findings.append(Finding(
                    category="Static Analysis",
                    name=f"ShellCheck warning in {s}",
                    description=result.stdout.strip(),
                    reproducer=f"shellcheck -s bash {s}",
                    severity="LOW"
                ))
            else:
                print(f"[+] Shellcheck clean: {s}")

def probe_env():
    return {key: value for key, value in os.environ.items() if not key.startswith("VARNISH_")}

def check_runtime_config(env):
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
    check_env = {**env, "VARNISH_LISTEN": f"127.0.0.1:{port}"}
    return run_cmd(["/start.sh", "--check"], env=check_env).require_execution()

def test_render_vcl_ports(findings):
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
            env = probe_env()
            env["VARNISH_BACKEND_HOST"] = "127.0.0.1"
            env["VARNISH_BACKEND_PORT"] = port
            result = run_cmd(["/usr/local/bin/render-vcl", tmp.name], env=env).require_execution()
            rc, err = result.returncode, result.stderr
            if rc != 0 and expect_error and "Invalid VARNISH_BACKEND_PORT" not in err:
                raise RuntimeError(f"Port rejection could not be measured: {result}")

            if rc == 0:
                check = check_runtime_config(env)
                check_rc = check.returncode
                compiler_output = (check.stdout + check.stderr).strip()
                if check_rc != 0 and not (port and port in compiler_output and re.search(r"VCC|VCL compilation", compiler_output, re.IGNORECASE)):
                    raise RuntimeError(f"Port configuration could not be measured: {check}")
                if expect_error and check_rc != 0:
                    print(f"[BUG] render-vcl allowed invalid port '{port}' ({label}); config check failed: {compiler_output}")
                    findings.append(Finding(
                        category="Input Validation / Boundary",
                        name=f"render-vcl allows invalid port: {port}",
                        description=f"render-vcl permitted VARNISH_BACKEND_PORT='{port}' ({label}), but the full runtime configuration failed its compile check: {compiler_output}",
                        reproducer=f"VARNISH_BACKEND_PORT='{port}' /usr/local/bin/render-vcl /tmp/test.vcl && /start.sh --check",
                        severity="HIGH" if "injection" in label or (port.isdigit() and (int(port) > 65535 or int(port) == 0)) else "MEDIUM"
                    ))
                elif expect_error and port in ("0", "65536", "99999999999999"):
                    findings.append(Finding(
                        category="Input Validation / Boundary",
                        name=f"render-vcl allows out-of-range TCP port: {port}",
                        description=f"VARNISH_BACKEND_PORT='{port}' is out of valid TCP port range (1-65535), but /start.sh --check compiled the full VCL successfully",
                        reproducer=f"VARNISH_BACKEND_PORT='{port}' /start.sh --check",
                        severity="MEDIUM"
                    ))
                elif not expect_error and check_rc != 0:
                    print(f"[BUG] Valid port '{port}' ({label}) failed the full runtime config check: {compiler_output}")
                    findings.append(Finding(
                        category="VCL Compilation",
                        name=f"valid backend port fails config check: {port or 'default'}",
                        description=f"The backend port was accepted by render-vcl but /start.sh --check failed: {compiler_output}",
                        reproducer=f"VARNISH_BACKEND_PORT='{port}' /start.sh --check",
                        severity="HIGH"
                    ))
            elif not expect_error:
                raise RuntimeError(f"Valid port could not be measured: {result}")
        finally:
            if os.path.exists(tmp.name):
                os.unlink(tmp.name)

def test_render_vcl_host_injections(findings):
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
            env = probe_env()
            env["VARNISH_BACKEND_HOST"] = host
            result = run_cmd(["/usr/local/bin/render-vcl", tmp.name], env=env).require_execution()
            rc = result.returncode
            if rc != 0 and "Invalid VARNISH_BACKEND_HOST" not in result.stderr:
                raise RuntimeError(f"Host rejection could not be measured: {result}")

            # Check what was rendered
            if os.path.exists(tmp.name):
                with open(tmp.name, "r") as f:
                    content = f.read()

                # Compile the complete runtime VCL using the backend values under test.
                check = check_runtime_config(env)
                if check.returncode != 0:
                    output = check.stdout + check.stderr
                    rejected = rc != 0 and "Invalid VARNISH_BACKEND_HOST" in output
                    unresolved = rc == 0 and host in output and re.search(RESOLUTION_ERROR, output, re.IGNORECASE)
                    if not (rejected or unresolved):
                        raise RuntimeError(f"Host configuration could not be measured: {check}")
                    print(f"[+] /start.sh --check rejected backend host '{host}' ({label}): {output.strip()}")
                elif rc != 0:
                    raise RuntimeError(f"Host rejection was not reproduced by the configuration check: {check}")

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

def test_config_check_rejects_unresolvable_backend(findings):
    print("--- Checking runtime VCL compilation with an unresolvable backend ---")
    env = probe_env()
    env["VARNISH_BACKEND_HOST"] = "nosuchhost"
    result = check_runtime_config(env)
    rc = result.returncode
    output = result.stdout + result.stderr

    if rc == 0:
        findings.append(Finding(
            category="VCL Compilation",
            name="config check accepts an unresolvable backend",
            description="/start.sh --check returned success for VARNISH_BACKEND_HOST=nosuchhost",
            reproducer="VARNISH_BACKEND_HOST=nosuchhost /start.sh --check",
            severity="HIGH"
        ))
    elif "nosuchhost" in output and re.search(RESOLUTION_ERROR, output, re.IGNORECASE):
        print(f"[+] /start.sh --check reported the expected resolution failure: {output.strip()}")
    else:
        raise RuntimeError(f"Backend resolution could not be measured: {result}")

def test_start_script_boundaries(findings):
    print("--- Fuzzing start.sh validation logic ---")
    start_sh = "/start.sh" if os.path.isfile("/start.sh") else os.path.abspath(os.path.join(os.path.dirname(__file__), "../../start.sh"))
    cases = [
        ({"VARNISH_LISTEN": ":80"}, "Listen missing host (:80)"),
        ({"VARNISH_LISTEN": "localhost:"}, "Listen missing port (localhost:)"),
        ({"VARNISH_LISTEN": "0.0.0.0:abc"}, "Listen non-numeric port"),
        ({"VARNISH_LISTEN": "0.0.0.0:0"}, "Listen out-of-range port low (0)"),
        ({"VARNISH_LISTEN": "0.0.0.0:70000"}, "Listen out-of-range port high (70000)"),
        ({"VARNISH_STORAGE": "malloc"}, "Storage missing comma (malloc)"),
        ({"VARNISH_STORAGE": "malloc,"}, "Storage missing size (malloc,)"),
        ({"VARNISH_STORAGE": ",1g"}, "Storage missing type (,1g)"),
        ({"VARNISH_STORAGE": "unknown_backend,1g"}, "Storage invalid backend"),
        ({"VARNISH_START": "echo 1", "VARNISH_LISTEN": "0.0.0.0:80"}, "VARNISH_START conflict with LISTEN"),
        ({"VARNISH_START": "echo 1", "VARNISH_EXTRA_ARGS": "-p foo=bar"}, "VARNISH_START conflict with EXTRA_ARGS"),
        ({"VARNISH_VCL": "/nonexistent.vcl"}, "Nonexistent VARNISH_VCL"),
    ]

    for env_override, label in cases:
        env = probe_env()
        env.update(env_override)
        # Run start.sh with timeout
        result = run_cmd([start_sh], env=env, timeout=3).require_execution()
        rc, out, err = result.returncode, result.stdout, result.stderr

        # We expect validation failures to exit non-zero quickly with an ERROR message
        if "conflict" in label or "Nonexistent" in label:
            expected = "VARNISH_START cannot be combined" if "conflict" in label else "Invalid VARNISH_VCL"
            if rc != 0 and expected not in out + err:
                raise RuntimeError(f"Startup rejection could not be measured: {result}")
            if rc == 0:
                findings.append(Finding(
                    category="Input Validation",
                    name=f"start.sh failed to reject: {label}",
                    description=f"Expected startup rejection for {env_override}, but exit code was 0",
                    reproducer=f"{' '.join(f'{k}={v}' for k, v in env_override.items())} /start.sh",
                    severity="HIGH"
                ))
        elif "missing" in label or "non-numeric" in label or "out-of-range" in label:
            # Check if start.sh caught it or passed it down to varnishd
            combined = out + err
            expected = "Invalid VARNISH_LISTEN" if "VARNISH_LISTEN" in env_override else "Invalid VARNISH_STORAGE"
            if expected not in combined:
                if rc != 0:
                    raise RuntimeError(f"Startup rejection could not be measured: {result}")
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

    def body(findings):
        test_shellcheck(findings)
        test_render_vcl_ports(findings)
        test_render_vcl_host_injections(findings)
        test_config_check_rejects_unresolvable_backend(findings)
        test_start_script_boundaries(findings)

    result = run_phase(body)
    print(f"\nPhase 1 {result.status}. Findings: {len(result.findings)}")
    return result

if __name__ == "__main__":
    import json
    res = run_all()
    print(json.dumps(res.to_dict(), indent=2))
