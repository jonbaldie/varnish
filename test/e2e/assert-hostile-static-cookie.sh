#!/usr/bin/env bash

set -euo pipefail

tmpdir="${TEST_TMPDIR:?TEST_TMPDIR must be set}"
url="http://localhost:8081/static/app.css"

echo "Purging any existing cached asset..."
status="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -X PURGE "$url")"
if [ "$status" != "200" ]; then
	echo "FAIL: Expected PURGE HTTP 200, got $status"
	exit 1
fi

resp1_headers="$tmpdir/resp1.headers"
resp1_body="$tmpdir/resp1.body"
resp2_headers="$tmpdir/resp2.headers"
resp2_body="$tmpdir/resp2.body"

echo "Requesting static asset with Cookie (first request)..."
curl -sS --max-time 10 -D "$resp1_headers" -o "$resp1_body" -H 'Cookie: client=alice' "$url"

if ! grep -q '^asset=app.css$' "$resp1_body"; then
	echo "FAIL: Expected first response body contain asset=app.css"
	cat "$resp1_body"
	exit 1
fi

if ! grep -q '^cookie=none$' "$resp1_body"; then
	echo "FAIL: Expected first response body to contain cookie=none"
	cat "$resp1_body"
	exit 1
fi

if ! grep -qi '^X-Cache: MISS' "$resp1_headers"; then
	echo "FAIL: Expected first response X-Cache: MISS"
	cat "$resp1_headers"
	exit 1
fi

echo "OK: First request reached origin without Cookie and was a MISS"
echo "Requesting static asset with Cookie (second request)..."
curl -sS --max-time 10 -D "$resp2_headers" -o "$resp2_body" -H 'Cookie: client=alice' "$url"

if ! grep -q '^asset=app.css$' "$resp2_body"; then
	echo "FAIL: Expected second response body contain asset=app.css"
	cat "$resp2_body"
	exit 1
fi

if ! grep -q '^cookie=none$' "$resp2_body"; then
	echo "FAIL: Expected second response body contain cookie=none"
	cat "$resp2_body"
	exit 1
fi

if ! grep -qi '^X-Cache: HIT' "$resp2_headers"; then
	echo "FAIL: Expected second response X-Cache: HIT"
	cat "$resp2_headers"
	exit 1
fi

echo "OK: Second request stayed cacheable and was a HIT"
echo "=== Test: Hostile static asset strips cookies and stays cacheable PASSED ==="
