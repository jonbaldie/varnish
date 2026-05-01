.PHONY: build test test-existence test-vcl-compile test-smoke test-integration test-security test-purge test-grace test-hostile-static-cookie test-hostile-account-cookie-isolation

IMAGE := jonbaldie/varnish:latest
CONTAINER_PREFIX := varnish-test

build:
	set -euo pipefail; \
	docker build -t $(IMAGE) .

test: build test-existence test-vcl-compile test-smoke test-integration test-security test-purge test-grace

test-existence:
	@echo "=== Test: File existence ==="
	@set -euo pipefail; \
	cid=$$(docker create $(IMAGE)); \
	tmpdir=$$(mktemp -d); \
	trap "docker rm -f $$cid >/dev/null 2>&1; rm -rf $$tmpdir" EXIT; \
	for f in /usr/sbin/varnishd /etc/varnish/default.vcl /start.sh; do \
		if ! docker cp $$cid:$$f $$tmpdir/ >/dev/null 2>&1; then \
			echo "FAIL: $$f not found"; \
			exit 1; \
		fi; \
		echo "OK: $$f exists"; \
	done; \
	echo "=== Test: File existence PASSED ==="

test-vcl-compile:
	@echo "=== Test: VCL compilation ==="
	@set -euo pipefail; \
	name="$(CONTAINER_PREFIX)-emb-$$(openssl rand -hex 4)"; \
	docker run --rm --name $$name $(IMAGE) varnishd -C -f /etc/varnish/default.vcl >/dev/null; \
	echo "OK: Embedded VCL compiles"; \
	name="$(CONTAINER_PREFIX)-repo-$$(openssl rand -hex 4)"; \
	docker run --rm --name $$name --add-host web:127.0.0.1 -v $$(pwd)/default.vcl:/etc/varnish/default.vcl:ro $(IMAGE) varnishd -C -f /etc/varnish/default.vcl >/dev/null; \
	echo "OK: Repo VCL compiles"; \
	echo "=== Test: VCL compilation PASSED ==="

test-smoke:
	@echo "=== Test: Smoke test ==="
	@set -euo pipefail; \
	name="$(CONTAINER_PREFIX)-smoke-$$(openssl rand -hex 4)"; \
	docker run -d --name $$name $(IMAGE) >/dev/null; \
	trap "docker rm -f $$name >/dev/null 2>&1" EXIT; \
	echo "Waiting for varnishd to start..."; \
	timeout=30; \
	while [ $$timeout -gt 0 ]; do \
		if docker exec $$name pidof varnishd >/dev/null 2>&1; then \
			echo "OK: varnishd is running"; \
			break; \
		fi; \
		sleep 1; \
		timeout=$$((timeout - 1)); \
	done; \
	if [ $$timeout -eq 0 ]; then \
		echo "FAIL: varnishd did not start within 30s"; \
		docker logs $$name; \
		exit 1; \
	fi; \
	docker exec $$name varnishadm status; \
	echo "=== Test: Smoke test PASSED ==="

test-integration:
	@echo "=== Test: Integration test ==="
	@set -euo pipefail; \
	trap "docker compose down --remove-orphans >/dev/null 2>&1" EXIT; \
	docker compose up -d --build; \
	echo "Waiting for services to be ready..."; \
	timeout=60; \
	while [ $$timeout -gt 0 ]; do \
		if curl -sf --max-time 10 http://localhost >/dev/null 2>&1; then \
			echo "OK: Services are ready"; \
			break; \
		fi; \
		sleep 2; \
		timeout=$$((timeout - 2)); \
	done; \
	if [ $$timeout -eq 0 ]; then \
		echo "FAIL: Services did not become ready within 60s"; \
		docker compose logs; \
		exit 1; \
	fi; \
	echo "Checking HTTP 200..."; \
	status=$$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://localhost); \
	if [ "$$status" != "200" ]; then \
		echo "FAIL: Expected HTTP 200, got $$status"; \
		exit 1; \
	fi; \
	echo "OK: HTTP 200"; \
	test_url="http://localhost/?cachebust=$$(openssl rand -hex 8)"; \
	echo "Checking X-Cache MISS on first request..."; \
	cache=$$(curl -sI --max-time 10 "$$test_url" | grep -i x-cache); \
	if ! echo "$$cache" | grep -qi MISS; then \
		echo "FAIL: Expected X-Cache MISS, got: $$cache"; \
		exit 1; \
	fi; \
	echo "OK: X-Cache MISS"; \
	echo "Checking X-Cache HIT on second request..."; \
	cache=$$(curl -sI --max-time 10 "$$test_url" | grep -i x-cache); \
	if ! echo "$$cache" | grep -qi HIT; then \
		echo "FAIL: Expected X-Cache HIT, got: $$cache"; \
		exit 1; \
	fi; \
	echo "OK: X-Cache HIT"; \
	echo "=== Test: Integration test PASSED ==="

test-security:
	@echo "=== Test: Security (non-root user) ==="
	@set -euo pipefail; \
	user=$$(docker run --rm $(IMAGE) whoami); \
	if [ "$$user" != "varnish" ]; then \
		echo "FAIL: Expected user 'varnish', got '$$user'"; \
		exit 1; \
	fi; \
	echo "OK: Container runs as varnish user"; \
	echo "=== Test: Security PASSED ==="

test-purge:
	@echo "=== Test: PURGE ==="
	@set -euo pipefail; \
	trap "docker compose down --remove-orphans >/dev/null 2>&1" EXIT; \
	docker compose up -d --build; \
	echo "Waiting for services to be ready..."; \
	timeout=60; \
	while [ $$timeout -gt 0 ]; do \
		if curl -sf --max-time 10 http://localhost >/dev/null 2>&1; then \
			echo "OK: Services are ready"; \
			break; \
		fi; \
		sleep 2; \
		timeout=$$((timeout - 2)); \
	done; \
	if [ $$timeout -eq 0 ]; then \
		echo "FAIL: Services did not become ready within 60s"; \
		docker compose logs; \
		exit 1; \
	fi; \
	test_url="http://localhost/?cachebust=$$(openssl rand -hex 8)"; \
	echo "Priming cache..."; \
	cache=$$(curl -sI --max-time 10 "$$test_url" | grep -i x-cache); \
	if ! echo "$$cache" | grep -qi MISS; then \
		echo "FAIL: Expected X-Cache MISS, got: $$cache"; \
		exit 1; \
	fi; \
	echo "OK: X-Cache MISS"; \
	echo "Checking X-Cache HIT..."; \
	cache=$$(curl -sI --max-time 10 "$$test_url" | grep -i x-cache); \
	if ! echo "$$cache" | grep -qi HIT; then \
		echo "FAIL: Expected X-Cache HIT, got: $$cache"; \
		exit 1; \
	fi; \
	echo "OK: X-Cache HIT"; \
	echo "Sending PURGE..."; \
	status=$$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -X PURGE "$$test_url"); \
	if [ "$$status" != "200" ]; then \
		echo "FAIL: Expected PURGE HTTP 200, got $$status"; \
		exit 1; \
	fi; \
	echo "OK: PURGE returned 200"; \
	echo "Checking X-Cache MISS after PURGE..."; \
	cache=$$(curl -sI --max-time 10 "$$test_url" | grep -i x-cache); \
	if ! echo "$$cache" | grep -qi MISS; then \
		echo "FAIL: Expected X-Cache MISS after PURGE, got: $$cache"; \
		exit 1; \
	fi; \
	echo "OK: X-Cache MISS after PURGE"; \
	echo "=== Test: PURGE PASSED ==="

test-grace:
	@echo "=== Test: Grace period (backend down) ==="
	@set -euo pipefail; \
	trap "docker compose up -d web >/dev/null 2>&1; docker compose down --remove-orphans >/dev/null 2>&1" EXIT; \
	docker compose up -d --build; \
	echo "Waiting for services to be ready..."; \
	timeout=60; \
	while [ $$timeout -gt 0 ]; do \
		if curl -sf --max-time 10 http://localhost >/dev/null 2>&1; then \
			echo "OK: Services are ready"; \
			break; \
		fi; \
		sleep 2; \
		timeout=$$((timeout - 2)); \
	done; \
	if [ $$timeout -eq 0 ]; then \
		echo "FAIL: Services did not become ready within 60s"; \
		docker compose logs; \
		exit 1; \
	fi; \
	test_url="http://localhost/?cachebust=$$(openssl rand -hex 8)"; \
	echo "Priming cache..."; \
	status=$$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$$test_url"); \
	if [ "$$status" != "200" ]; then \
		echo "FAIL: Expected HTTP 200, got $$status"; \
		exit 1; \
	fi; \
	echo "OK: Cache primed with HTTP 200"; \
	echo "Stopping web container..."; \
	docker compose stop web; \
	echo "Waiting for backend to be marked sick (~15s)..."; \
	sleep 18; \
	echo "Checking request with backend down..."; \
	status=$$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$$test_url"); \
	if [ "$$status" != "200" ]; then \
		echo "FAIL: Expected HTTP 200 from grace, got $$status"; \
		exit 1; \
		fi; \
	echo "OK: HTTP 200 from grace"; \
	echo "=== Test: Grace period PASSED ==="

test-hostile-static-cookie:
	@echo "=== Test: Hostile static asset strips cookies and stays cacheable ==="
	@set -euo pipefail; \
	trap "docker compose -f docker-compose.yml -f docker-compose.hostile.yml down --remove-orphans >/dev/null 2>&1" EXIT; \
	docker compose -f docker-compose.yml -f docker-compose.hostile.yml up -d --build hostile-backend varnish-hostile; \
	echo "Waiting for hostile services to be ready..."; \
	timeout=60; \
	while [ $$timeout -gt 0 ]; do \
		if curl -sf --max-time 10 http://localhost:8081/ready >/dev/null 2>&1; then \
			echo "OK: Hostile services are ready"; \
			break; \
		fi; \
		sleep 2; \
		timeout=$$((timeout - 2)); \
	done; \
	if [ $$timeout -eq 0 ]; then \
		echo "FAIL: Hostile services did not become ready within 60s"; \
		docker compose -f docker-compose.yml -f docker-compose.hostile.yml logs; \
		exit 1; \
	fi; \
	url="http://localhost:8081/static/app.css"; \
	echo "Purging any existing cached asset..."; \
	status=$$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -X PURGE "$$url"); \
	if [ "$$status" != "200" ]; then \
		echo "FAIL: Expected PURGE HTTP 200, got $$status"; \
		exit 1; \
	fi; \
	tmpdir=$$(mktemp -d); \
	trap "rm -rf $$tmpdir; docker compose -f docker-compose.yml -f docker-compose.hostile.yml down --remove-orphans >/dev/null 2>&1" EXIT; \
	resp1_headers="$$tmpdir/resp1.headers"; \
	resp1_body="$$tmpdir/resp1.body"; \
	resp2_headers="$$tmpdir/resp2.headers"; \
	resp2_body="$$tmpdir/resp2.body"; \
	echo "Requesting static asset with Cookie (first request)..."; \
	curl -sS --max-time 10 -D "$$resp1_headers" -o "$$resp1_body" -H 'Cookie: client=alice' "$$url"; \
	if ! grep -q '^asset=app.css$$' "$$resp1_body"; then \
		echo "FAIL: Expected first response body to contain asset=app.css"; \
		cat "$$resp1_body"; \
		exit 1; \
	fi; \
	if ! grep -q '^cookie=none$$' "$$resp1_body"; then \
		echo "FAIL: Expected first response body to contain cookie=none"; \
		cat "$$resp1_body"; \
		exit 1; \
	fi; \
	if ! grep -qi '^X-Cache: MISS' "$$resp1_headers"; then \
		echo "FAIL: Expected first response X-Cache: MISS"; \
		cat "$$resp1_headers"; \
		exit 1; \
	fi; \
	echo "OK: First request reached origin without Cookie and was a MISS"; \
	echo "Requesting static asset with Cookie (second request)..."; \
	curl -sS --max-time 10 -D "$$resp2_headers" -o "$$resp2_body" -H 'Cookie: client=alice' "$$url"; \
	if ! grep -q '^asset=app.css$$' "$$resp2_body"; then \
		echo "FAIL: Expected second response body to contain asset=app.css"; \
		cat "$$resp2_body"; \
		exit 1; \
	fi; \
	if ! grep -q '^cookie=none$$' "$$resp2_body"; then \
		echo "FAIL: Expected second response body to contain cookie=none"; \
		cat "$$resp2_body"; \
		exit 1; \
	fi; \
	if ! grep -qi '^X-Cache: HIT' "$$resp2_headers"; then \
		echo "FAIL: Expected second response X-Cache: HIT"; \
		cat "$$resp2_headers"; \
		exit 1; \
	fi; \
	echo "OK: Second request stayed cacheable and was a HIT"; \
	echo "=== Test: Hostile static asset strips cookies and stays cacheable PASSED ==="

test-hostile-account-cookie-isolation:
	@echo "=== Test: Hostile account requests with cookies stay isolated per client ==="
	@set -euo pipefail; \
	trap "docker compose -f docker-compose.yml -f docker-compose.hostile.yml down --remove-orphans >/dev/null 2>&1" EXIT; \
	docker compose -f docker-compose.yml -f docker-compose.hostile.yml up -d --build hostile-backend varnish-hostile; \
	echo "Waiting for hostile services to be ready..."; \
	timeout=60; \
	while [ $$timeout -gt 0 ]; do \
		if curl -sf --max-time 10 http://localhost:8081/ready >/dev/null 2>&1; then \
			echo "OK: Hostile services are ready"; \
			break; \
		fi; \
		sleep 2; \
		timeout=$$((timeout - 2)); \
	done; \
	if [ $$timeout -eq 0 ]; then \
		echo "FAIL: Hostile services did not become ready within 60s"; \
		docker compose -f docker-compose.yml -f docker-compose.hostile.yml logs; \
		exit 1; \
	fi; \
	url="http://localhost:8081/account"; \
	echo "Purging any existing cached account response..."; \
	status=$$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -X PURGE "$$url"); \
	if [ "$$status" != "200" ]; then \
		echo "FAIL: Expected PURGE HTTP 200, got $$status"; \
		exit 1; \
	fi; \
	tmpdir=$$(mktemp -d); \
	trap "rm -rf $$tmpdir; docker compose -f docker-compose.yml -f docker-compose.hostile.yml down --remove-orphans >/dev/null 2>&1" EXIT; \
	alice_headers="$$tmpdir/alice.headers"; \
	alice_body="$$tmpdir/alice.body"; \
	bob_headers="$$tmpdir/bob.headers"; \
	bob_body="$$tmpdir/bob.body"; \
	echo "Requesting /account as alice..."; \
	curl -sS --max-time 10 -D "$$alice_headers" -o "$$alice_body" -H 'Cookie: client=alice' "$$url"; \
	if ! grep -q '^route=account$$' "$$alice_body"; then \
		echo "FAIL: Expected alice response body to contain route=account"; \
		cat "$$alice_body"; \
		exit 1; \
	fi; \
	if ! grep -q '^client=alice$$' "$$alice_body"; then \
		echo "FAIL: Expected alice response body to contain client=alice"; \
		cat "$$alice_body"; \
		exit 1; \
	fi; \
	if grep -q '^client=bob$$' "$$alice_body"; then \
		echo "FAIL: Alice response leaked client=bob"; \
		cat "$$alice_body"; \
		exit 1; \
	fi; \
	if ! grep -qi '^X-Cache: MISS' "$$alice_headers"; then \
		echo "FAIL: Expected alice response X-Cache: MISS"; \
		cat "$$alice_headers"; \
		exit 1; \
	fi; \
	alice_request_id=$$(grep -i '^X-Backend-Request-Id:' "$$alice_headers" | tr -d '\r' | cut -d' ' -f2); \
	if [ -z "$$alice_request_id" ]; then \
		echo "FAIL: Expected alice response to include X-Backend-Request-Id"; \
		cat "$$alice_headers"; \
		exit 1; \
	fi; \
	echo "OK: Alice response stayed uncached and client-specific"; \
	echo "Requesting /account as bob..."; \
	curl -sS --max-time 10 -D "$$bob_headers" -o "$$bob_body" -H 'Cookie: client=bob' "$$url"; \
	if ! grep -q '^route=account$$' "$$bob_body"; then \
		echo "FAIL: Expected bob response body to contain route=account"; \
		cat "$$bob_body"; \
		exit 1; \
	fi; \
	if ! grep -q '^client=bob$$' "$$bob_body"; then \
		echo "FAIL: Expected bob response body to contain client=bob"; \
		cat "$$bob_body"; \
		exit 1; \
	fi; \
	if grep -q '^client=alice$$' "$$bob_body"; then \
		echo "FAIL: Bob response leaked client=alice"; \
		cat "$$bob_body"; \
		exit 1; \
	fi; \
	if ! grep -qi '^X-Cache: MISS' "$$bob_headers"; then \
		echo "FAIL: Expected bob response X-Cache: MISS"; \
		cat "$$bob_headers"; \
		exit 1; \
	fi; \
	bob_request_id=$$(grep -i '^X-Backend-Request-Id:' "$$bob_headers" | tr -d '\r' | cut -d' ' -f2); \
	if [ -z "$$bob_request_id" ]; then \
		echo "FAIL: Expected bob response to include X-Backend-Request-Id"; \
		cat "$$bob_headers"; \
		exit 1; \
	fi; \
	if [ "$$alice_request_id" = "$$bob_request_id" ]; then \
		echo "FAIL: Expected distinct backend request ids, got $$alice_request_id"; \
		echo "--- alice headers ---"; \
		cat "$$alice_headers"; \
		echo "--- bob headers ---"; \
		cat "$$bob_headers"; \
		exit 1; \
	fi; \
	echo "OK: Bob response stayed uncached and isolated from alice"; \
	echo "=== Test: Hostile account requests with cookies stay isolated per client PASSED ==="
