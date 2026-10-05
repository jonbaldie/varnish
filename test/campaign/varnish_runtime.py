#!/usr/bin/env python3
"""Starts campaign Varnish through the image's runtime start interface (/start.sh)."""

import os
import subprocess
import tempfile
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


class CampaignVarnish:
    """A /start.sh process, which execs varnishd -F in place."""

    def __init__(self, overrides=None):
        env = os.environ.copy()
        # start.sh refuses VARNISH_START combined with the variables set here.
        env.pop("VARNISH_START", None)
        env.update(CAMPAIGN_ENV)
        env.update(overrides or {})
        # A file rather than a pipe, so a long run can't block varnishd on a full
        # pipe; stdout passes through to the campaign log.
        self._stderr = tempfile.TemporaryFile()
        self._proc = subprocess.Popen(["/start.sh"], env=env, stderr=self._stderr)

    @property
    def pid(self):
        return self._proc.pid

    def wait_until_ready(self, url, timeout=20):
        """Return None once url serves 200, else a message describing the failure."""
        deadline = time.time() + timeout
        while time.time() < deadline and self._proc.poll() is None:
            try:
                with urllib.request.urlopen(url, timeout=2) as resp:
                    if resp.status == 200:
                        return None
            except Exception:
                pass
            time.sleep(0.5)
        if self._proc.poll() is None:
            return f"no HTTP 200 from {url} within {timeout}s"
        self._stderr.seek(0)
        err = self._stderr.read().decode(errors="replace")
        return f"/start.sh exited with code {self._proc.returncode}: {err}"

    def stop(self):
        if self._proc.poll() is None:
            self._proc.terminate()
            try:
                self._proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self._proc.kill()
                self._proc.wait()
        self._stderr.close()
