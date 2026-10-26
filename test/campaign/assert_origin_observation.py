#!/usr/bin/env python3
"""Exercise origin observations through real sockets (no substituted collaborators)."""
from backend import start_backend
from http_client import CampaignHttpClient


def assert_origin_observation():
    backend = start_backend(0)
    client = CampaignHttpClient("127.0.0.1", backend.server_port)
    try:
        first = client.request("GET", "/same.css")
        second = client.request("GET", "/same.css", {"Cookie": "session=current"})
        first_record = backend.get_request(first.backend_request_id)
        second_record = backend.get_request(second.backend_request_id)
        assert first_record["request_id"] != second_record["request_id"]
        assert first_record["headers"].get("Cookie") is None
        assert second_record["headers"]["Cookie"] == "session=current"
        assert backend.request_for_response(second) == second_record
        assert backend.get_request(second_record["request_id"]) == second_record
        try:
            backend.get_request("missing")
        except KeyError as exc:
            assert "missing" in str(exc)
        else:
            raise AssertionError("unknown origin IDs must raise KeyError")
        print("OK: same-path responses identify their own origin request")

        checkpoint = backend.checkpoint()
        third = client.request("POST", "/same.css", {"Cookie": "session=new"}, "payload")
        records = backend.requests_since(checkpoint)
        assert len(records) == 1
        assert records[0]["body"] == "payload"
        assert backend.request_for_response(first, since=checkpoint) is None
        assert backend.request_for_response(third, since=checkpoint) == records[0]
        backend.clear_routes()
        fourth = client.request("GET", "/same.css")
        assert len(backend.requests_since(checkpoint)) == 1
        assert backend.request_for_response(fourth, since=checkpoint)["method"] == "GET"
        try:
            backend.get_request(third.backend_request_id)
        except KeyError:
            pass
        else:
            raise AssertionError("reset must discard the request index too")
        print("OK: checkpoints isolate observations and remain valid across resets")
        for path in ("/ready", "/echo-headers/check"):
            response = client.request("GET", path, {"X-Observation": "real"})
            assert backend.request_for_response(response)["headers"]["X-Observation"] == "real"
        print("OK: every successful origin response has a recorded interaction")
    finally:
        backend.shutdown()
        backend.server_close()


def assert_varnish_observation():
    from phase_result import run_phase
    from runtime_health import VarnishRuntime
    from test_properties import (
        test_static_asset_properties, test_accept_encoding_properties,
        test_http_methods_properties,
    )

    backend = start_backend(8080)
    origin = CampaignHttpClient("127.0.0.1", 8080)
    client = CampaignHttpClient("127.0.0.1", 80)
    runtime = VarnishRuntime.start("127.0.0.1", 80, {
        "VARNISH_STORAGE": "malloc,64m",
        "VARNISH_BACKEND_HOST": "127.0.0.1",
        "VARNISH_BACKEND_PORT": "8080",
        "VARNISH_BACKEND_PROBE_PATH": "/ready",
    })
    try:
        assert runtime.wait_ready(timeout=20)
        first = client.request("GET", "/correlate.css")
        hit = client.request("GET", "/correlate.css")
        assert "HIT" in hit.x_cache
        assert hit.backend_request_id == first.backend_request_id
        assert backend.request_for_response(hit) is None
        assert backend.request_for_response(first)["path"] == "/correlate.css"
        synthetic = client.request("PURGE", "/correlate.css")
        assert backend.request_for_response(synthetic) is None
        print("OK: real cache HIT and synthetic responses do not claim new origin requests")

        # Deliberately pollute identical paths with old, leaking interactions.
        # Each property run must inspect only its newly forwarded requests.
        for _ in range(2):
            origin.request("GET", "/test-base-css.css", {"Cookie": "stale=secret"})
            origin.request("GET", "/static-query-css.css?v=1", {"Cookie": "stale=secret"})
            origin.request("GET", "/test-upper.CSS", {"Cookie": "stale=secret"})
            result = run_phase(lambda findings: test_static_asset_properties(
                findings, "127.0.0.1", 80, backend))
            assert result.status == "completed", result.diagnostics
            assert not result.findings, result.findings
        print("OK: repeated static property checks ignore earlier leaking requests")
        for _ in range(2):
            result = run_phase(lambda findings: test_http_methods_properties(
                findings, "127.0.0.1", 80, backend))
            assert result.status == "completed", result.diagnostics
            assert not result.findings, result.findings
        print("OK: repeated mutation checks correlate method and cookie observations")

        # Header assertions must not parse the response body, even for errors.
        backend.set_route("/observe-headers/test-ae-q0", status=503, body="not JSON")
        result = run_phase(lambda findings: test_accept_encoding_properties(
            findings, "127.0.0.1", 80, backend))
        assert result.status == "completed", result.diagnostics
        assert not result.findings, result.findings
        print("OK: header observations survive non-JSON origin errors")
    finally:
        runtime.stop()
        backend.shutdown()
        backend.server_close()


if __name__ == "__main__":
    import sys
    assert_origin_observation()
    if "--varnish" in sys.argv:
        assert_varnish_observation()
