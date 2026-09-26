#!/usr/bin/env python3
"""Exercise the documented Compose image rebuild against a legacy VOLUME."""

from __future__ import annotations

import hashlib
import json
import pathlib
import re
import secrets
import shutil
import socket
import subprocess
import sys
import tempfile
import time


ROOT = pathlib.Path(__file__).resolve().parents[2]
CONTEXT_FILES = (
    "Dockerfile",
    "embedded-default.vcl",
    "cache-policy.vcl",
    "install.sh",
    "render-vcl.sh",
    "start.sh",
    "docker-compose.yml",
)


def fail(message: str) -> None:
    raise AssertionError(message)


def main() -> None:
    project = "varnish102" + secrets.token_hex(4)
    image = f"varnish-102-{project}:latest"

    with tempfile.TemporaryDirectory(prefix="varnish-compose-image-rebuild-") as temp_name:
        context = pathlib.Path(temp_name)
        for name in CONTEXT_FILES:
            shutil.copy2(ROOT / name, context / name)

        compose_file = context / "docker-compose.yml"
        compose_text = compose_file.read_text()
        if compose_text.count('image: jonbaldie/varnish') != 1:
            fail("sample Compose file no longer has one varnish image entry")
        if compose_text.count('"80:80"') != 1:
            fail("sample Compose file no longer has one published port entry")
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            host_port = listener.getsockname()[1]
        compose_file.write_text(
            compose_text.replace("image: jonbaldie/varnish", f"image: {image}")
            .replace('"80:80"', f'"127.0.0.1:{host_port}:80"')
        )

        dockerfile = context / "Dockerfile"
        release_dockerfile = (ROOT / "Dockerfile").read_text()
        volume_match = re.search(r"(?m)^VOLUME\s+(\[.*\])\s*$", release_dockerfile)
        if not volume_match:
            fail("Dockerfile must declare the persistent /var/lib/varnish volume")
        legacy_volumes = json.loads(volume_match.group(1))
        if "/var/lib/varnish" not in legacy_volumes:
            fail("Dockerfile must keep /var/lib/varnish as a volume")
        if "/etc/varnish" not in legacy_volumes:
            legacy_volumes.append("/etc/varnish")
        legacy_dockerfile = release_dockerfile[: volume_match.start(1)]
        legacy_dockerfile += json.dumps(legacy_volumes)
        legacy_dockerfile += release_dockerfile[volume_match.end(1) :]
        dockerfile.write_text(legacy_dockerfile)

        def command(*args: str, check: bool = True) -> str:
            result = subprocess.run(
                args,
                cwd=context,
                check=False,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
            )
            if check and result.returncode:
                excerpt = "\n".join(result.stdout.splitlines()[-40:])
                fail(f"command failed ({result.returncode}): {' '.join(args)}\n{excerpt}")
            return result.stdout.strip()

        def compose(*args: str, check: bool = True) -> str:
            return command(
                "docker",
                "compose",
                "--progress",
                "quiet",
                "-p",
                project,
                *args,
                check=check,
            )

        def container_id() -> str:
            return compose("ps", "-q", "varnish")

        def mounts(cid: str) -> list[dict[str, object]]:
            raw = command("docker", "inspect", "--format", "{{json .Mounts}}", cid)
            return json.loads(raw)

        def file_hash(*, cid: str | None = None, in_image: bool = False, path: str) -> str:
            if cid:
                output = command("docker", "compose", "-p", project, "exec", "-T", "varnish", "sha256sum", path)
            elif in_image:
                output = command("docker", "run", "--rm", "--entrypoint", "sha256sum", image, path)
            else:
                fail("file_hash requires a container or image")
            return output.split()[0]

        def request_headers() -> tuple[str, str]:
            url = f"http://127.0.0.1:{host_port}/?compose-smoke={secrets.token_hex(6)}"
            last_headers = ""
            for _ in range(60):
                result = subprocess.run(
                    ["curl", "-sS", "--max-time", "3", "-D", "-", "-o", "/dev/null", url],
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.DEVNULL,
                )
                if result.returncode == 0:
                    last_headers = result.stdout
                    if re.search(r"(?mi)^HTTP/[^ ]+ 200\b", last_headers):
                        return last_headers, url
                time.sleep(0.5)
            return last_headers, url

        def has_header(headers: str, name: str, value: str) -> bool:
            expected = f"{name}: {value}".casefold()
            return any(line.casefold() == expected for line in headers.splitlines())

        try:
            compose("up", "-d", "--build")
            old_cid = container_id()
            initial_headers, _ = request_headers()
            if not old_cid or not re.search(r"(?mi)^HTTP/[^ ]+ 200\b", initial_headers):
                fail("legacy sample Compose stack did not serve HTTP 200\n" + initial_headers)
            old_mounts = mounts(old_cid)
            if not any(mount.get("Destination") == "/etc/varnish" and mount.get("Type") == "volume" for mount in old_mounts):
                fail("legacy Compose fixture did not create the old anonymous /etc/varnish volume")
            if has_header(initial_headers, "X-Image-Build", "v2"):
                fail("X-Image-Build marker unexpectedly appeared before rebuilding")

            dockerfile.write_text(release_dockerfile)
            embedded_vcl = context / "embedded-default.vcl"
            with embedded_vcl.open("a") as source:
                source.write('\nsub vcl_deliver {\n    set resp.http.X-Image-Build = "v2";\n}\n')
            compose("up", "-d", "--build")
            rebuilt_cid = container_id()
            if not rebuilt_cid or rebuilt_cid == old_cid:
                fail("docker compose up -d --build did not recreate the Varnish container")

            rebuilt_headers, _ = request_headers()
            if not re.search(r"(?mi)^HTTP/[^ ]+ 200\b", rebuilt_headers):
                fail("rebuilt sample Compose stack did not serve HTTP 200\n" + rebuilt_headers)
            expected_default_hash = hashlib.sha256(embedded_vcl.read_bytes()).hexdigest()
            container_default_hash = file_hash(cid=rebuilt_cid, path="/etc/varnish/default.vcl")
            image_default_hash = file_hash(in_image=True, path="/etc/varnish/default.vcl")
            if not has_header(rebuilt_headers, "X-Image-Build", "v2"):
                fail(
                    "rebuilt Compose response is missing X-Image-Build: v2; "
                    f"container default.vcl sha256={container_default_hash}, "
                    f"image default.vcl sha256={image_default_hash}"
                )
            if container_default_hash != image_default_hash or image_default_hash != expected_default_hash:
                fail(
                    "effective /etc/varnish/default.vcl differs from the rebuilt image/source; "
                    f"container={container_default_hash}, image={image_default_hash}, source={expected_default_hash}"
                )
            rebuilt_mounts = mounts(rebuilt_cid)
            if any(mount.get("Destination") == "/etc/varnish" for mount in rebuilt_mounts):
                fail("rebuilt container still mounts all of /etc/varnish")
            print("OK: old anonymous /etc/varnish volume was discarded; rebuilt VCL served X-Image-Build: v2")

            image_policy_hash = file_hash(in_image=True, path="/etc/varnish/cache-policy.vcl")
            policy_file = context / "cache-policy.vcl"
            policy_text = policy_file.read_text()
            hook = "sub vcl_backend_response {"
            if policy_text.count(hook) != 1:
                fail("cache-policy.vcl must define one vcl_backend_response subroutine")
            policy_text = policy_text.replace(
                hook,
                hook + '\n    set beresp.http.X-Policy-Build = "mounted-v2";',
                1,
            )
            policy_file.write_text(policy_text)
            expected_policy_hash = hashlib.sha256(policy_file.read_bytes()).hexdigest()
            if expected_policy_hash == image_policy_hash:
                fail("mounted cache-policy fixture did not differ from the image copy")

            compose("up", "-d", "--force-recreate")
            policy_cid = container_id()
            if not policy_cid or policy_cid == rebuilt_cid:
                fail("Compose did not recreate Varnish after the mount fixture changed")
            policy_mounts = mounts(policy_cid)
            if not any(
                mount.get("Type") == "bind" and mount.get("Destination") == "/etc/varnish/cache-policy.vcl"
                for mount in policy_mounts
            ):
                fail("sample Compose no longer bind-mounts cache-policy.vcl")
            container_policy_hash = file_hash(cid=policy_cid, path="/etc/varnish/cache-policy.vcl")
            if container_policy_hash != expected_policy_hash:
                fail(
                    "recreated container did not use the changed cache-policy bind mount; "
                    f"container={container_policy_hash}, mount-source={expected_policy_hash}, image={image_policy_hash}"
                )
            policy_headers, _ = request_headers()
            if not re.search(r"(?mi)^HTTP/[^ ]+ 200\b", policy_headers):
                fail("recreated sample Compose stack did not serve HTTP 200\n" + policy_headers)
            if not has_header(policy_headers, "X-Policy-Build", "mounted-v2"):
                fail("recreated Compose service did not apply the changed mounted cache policy")
            compose("restart", "varnish")
            restarted_headers, _ = request_headers()
            if not re.search(r"(?mi)^HTTP/[^ ]+ 200\b", restarted_headers):
                fail("restarted sample Compose stack did not serve HTTP 200\n" + restarted_headers)
            if not has_header(restarted_headers, "X-Policy-Build", "mounted-v2"):
                fail("restarted Compose service did not apply the changed mounted cache policy")
            print("OK: changed cache-policy.vcl bind mount remained active after recreation and restart")
        finally:
            compose("down", "-v", "--remove-orphans", check=False)
            command("docker", "image", "rm", image, check=False)


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, subprocess.SubprocessError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
