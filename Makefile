.PHONY: build test test-existence test-vcl-compile test-smoke test-integration

IMAGE := jonbaldie/varnish:latest
CONTAINER_PREFIX := varnish-test

build:
	set -euo pipefail; \
	docker build -t $(IMAGE) .

test: build test-existence test-vcl-compile test-smoke test-integration

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
