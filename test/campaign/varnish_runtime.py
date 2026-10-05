#!/usr/bin/env python3
"""Starts campaign Varnish through the image's runtime start interface (/start.sh)."""

import os
import subprocess
import time
import urllib.request

# Bounded thread pool to respect the campaign container's resource caps.
CAMPAIGN_ENV = {
    "VARNISH_LISTEN": "127.0.0.1:80",
    "VARNISH_STORAGE": "malloc,256m",
    "VARNISH_BACKEND_HOST": "127.0.0.1",
    "VARNISH_BACKEND_PORT": "8080",
    "VARNISH_BACKEND_PROBE_PATH": "/ready",
    "VARNISH_EXTRA_ARGS": " ".join([
        "-p thread_pools=1",
        "-p thread_pool_min=10",
        "-p thread_pool_max=50",
        "-p default_grace=3600",
        "-p vsl_mask=+Hash",
    ]),
}


def start_varnish(overrides=None):
    """Run /start.sh with the campaign environment; it execs varnishd -F."""
    env = os.environ.copy()
    # start.sh refuses VARNISH_START combined with the variables set here.
    env.pop("VARNISH_START", None)
    env.update(CAMPAIGN_ENV)
    env.update(overrides or {})
    return subprocess.Popen(
        ["/start.sh"], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE
    )


def wait_until_ready(proc, url, timeout=20):
    """Return None once url serves 200, else a message describing the failure."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        if proc.poll() is not None:
            break
        try:
            with urllib.request.urlopen(url, timeout=2) as resp:
                if resp.status == 200:
                    return None
        except Exception:
            pass
        time.sleep(0.5)
    if proc.poll() is None:
        return f"no HTTP 200 from {url} within {timeout}s"
    _, err = proc.communicate()
    return f"/start.sh exited with code {proc.returncode}: {err.decode()}"
