SHELL := /bin/bash

.PHONY: build test test-makefile-shell test-restart-docs test-existence test-vcl-compile test-smoke test-container-restart test-smoke-runtime-interface test-backend-config-adapter test-integration test-security test-purge test-grace test-perf test-e2e-hard test-e2e-harness-module test-e2e-scenario-config test-hostile-static-cookie test-hostile-static-cookie-canary test-hostile-account-cookie-isolation test-hostile-set-cookie-isolation test-5xx-not-cached test-purge-unauthorized test-post-not-cached test-grace-stale test-campaign

IMAGE := jonbaldie/varnish:latest
CONTAINER_PREFIX := varnish-test

build:
	set -euo pipefail; \
	docker build -t $(IMAGE) .

# test-makefile-shell: Validates the shell environment supports required features
# This is a canary test that catches shell compatibility issues early, before they
# manifest as cryptic failures in other tests. It verifies that:
# - The shell supports 'set -euo pipefail' (bash-specific feature)
# - The environment is properly configured for running the test suite
# Run this first if you suspect shell configuration issues.
test-makefile-shell:
	@echo "=== Test: Makefile shell compatibility ==="
	@set -euo pipefail; echo "OK: pipefail supported"
	@echo "=== Test: Makefile shell compatibility PASSED ==="

test: build test-restart-docs test-existence test-vcl-compile test-smoke test-container-restart test-smoke-runtime-interface test-backend-config-adapter test-e2e-harness-module test-integration test-security test-purge test-grace

test-restart-docs:
	@echo "=== Test: Restart documentation ==="
	@set -euo pipefail; \
		grep -q "docker restart" README.md; \
		grep -q "docker compose restart varnish" README.md; \
		grep -q "sudo service varnish restart" README.md; \
		echo "OK: README documents container restart workflow"; \
		echo "=== Test: Restart documentation PASSED ==="

test-e2e-hard: test-e2e-harness-module test-e2e-scenario-config test-hostile-static-cookie test-hostile-static-cookie-canary test-hostile-account-cookie-isolation test-hostile-set-cookie-isolation test-5xx-not-cached test-purge-unauthorized test-post-not-cached test-grace-stale

test-existence:
	@echo "=== Test: File existence ==="
	@set -euo pipefail; \
	cid=$$(docker create $(IMAGE)); \
	tmpdir=$$(mktemp -d); \
	trap "docker rm -f $$cid >/dev/null 2>&1; rm -rf $$tmpdir" EXIT; \
	for f in /usr/sbin/varnishd /etc/varnish/default.vcl /etc/varnish/backend.vcl /etc/varnish/cache-policy.vcl /start.sh; do \
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
	docker run --rm --name $$name $(IMAGE) varnishd -C -f /etc/varnish/default.vcl >/dev/null 2>&1; \
	echo "OK: Embedded VCL compiles"; \
	name="$(CONTAINER_PREFIX)-emb-config-$$(openssl rand -hex 4)"; \
	docker run --rm --name $$name \
		-e VARNISH_BACKEND_HOST=localhost \
		-e VARNISH_BACKEND_PORT=9090 \
		-e VARNISH_BACKEND_PROBE_PATH=/healthz \
		$(IMAGE) /bin/bash -lc '/usr/local/bin/render-vcl /tmp/backend.vcl && grep -q "\\.host = \"localhost\";" /tmp/backend.vcl && grep -q "\\.port = \"9090\";" /tmp/backend.vcl && grep -q "\\.url = \"/healthz\";" /tmp/backend.vcl && cp /etc/varnish/default.vcl /tmp/default.vcl && sed -i "s#/etc/varnish/backend.vcl#/tmp/backend.vcl#" /tmp/default.vcl && /usr/sbin/varnishd -C -f /tmp/default.vcl >/dev/null 2>&1'; \
	echo "OK: Embedded VCL compiles with configured backend output"; \
	name="$(CONTAINER_PREFIX)-compose-config-$$(openssl rand -hex 4)"; \
	docker run --rm --name $$name --add-host web:127.0.0.1 $(IMAGE) /bin/bash -lc 'VARNISH_BACKEND_HOST=web VARNISH_BACKEND_PORT=80 VARNISH_BACKEND_PROBE_PATH=/ /usr/local/bin/render-vcl /tmp/backend.vcl && cp /etc/varnish/default.vcl /tmp/default.vcl && sed -i "s#/etc/varnish/backend.vcl#/tmp/backend.vcl#" /tmp/default.vcl && /usr/sbin/varnishd -C -f /tmp/default.vcl >/dev/null 2>&1'; \
	echo "OK: Compose backend adapter VCL compiles"; \
	name="$(CONTAINER_PREFIX)-hostile-config-$$(openssl rand -hex 4)"; \
	docker run --rm --name $$name --add-host hostile-backend:127.0.0.1 $(IMAGE) /bin/bash -lc 'VARNISH_BACKEND_HOST=hostile-backend VARNISH_BACKEND_PORT=8080 VARNISH_BACKEND_PROBE_PATH=/ready /usr/local/bin/render-vcl /tmp/backend.vcl && cp /etc/varnish/default.vcl /tmp/default.vcl && sed -i "s#/etc/varnish/backend.vcl#/tmp/backend.vcl#" /tmp/default.vcl && /usr/sbin/varnishd -C -f /tmp/default.vcl >/dev/null 2>&1'; \
	echo "OK: Hostile backend adapter VCL compiles"; \
	name="$(CONTAINER_PREFIX)-repo-$$(openssl rand -hex 4)"; \
	docker run --rm --name $$name --add-host web:127.0.0.1 -v $$(pwd)/default.vcl:/etc/varnish/default.vcl:ro -v $$(pwd)/cache-policy.vcl:/etc/varnish/cache-policy.vcl:ro $(IMAGE) varnishd -C -f /etc/varnish/default.vcl >/dev/null 2>&1; \
	echo "OK: Repo VCL compiles"; \
	echo "=== Test: VCL compilation PASSED ==="
test-smoke:
	@echo "=== Test: Smoke test ==="
	@set -euo pipefail; \
		name="$(CONTAINER_PREFIX)-smoke-$$(openssl rand -hex 4)"; \
		host_port=18080; \
		docker run -d --name $$name -p $$host_port:80 $(IMAGE) >/dev/null; \
		trap "docker rm -f $$name >/dev/null 2>&1" EXIT; \
		echo "Waiting for varnishd to serve HTTP on $$host_port..."; \
		timeout=30; \
		status="000"; \
		while [ $$timeout -gt 0 ]; do \
			status=$$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://localhost:$$host_port || true); \
			if [ "$$status" != "000" ]; then \
				echo "OK: varnishd served HTTP $$status on port $$host_port"; \
				break; \
			fi; \
			sleep 1; \
			timeout=$$((timeout - 1)); \
		done; \
		if [ "$$status" = "000" ]; then \
			echo "FAIL: varnishd did not serve HTTP within 30s"; \
			docker logs $$name; \
			exit 1; \
		fi; \
		docker exec $$name varnishadm status >/dev/null; \
		echo "OK: varnishadm status responded"; \
		echo "=== Test: Smoke test PASSED ==="

test-container-restart:
	@echo "=== Test: Container restart ==="
	@set -euo pipefail; \
		name="$(CONTAINER_PREFIX)-restart-$$(openssl rand -hex 4)"; \
		host_port=18083; \
		docker run -d --name $$name -p $$host_port:80 $(IMAGE) >/dev/null; \
		trap "docker rm -f $$name >/dev/null 2>&1" EXIT; \
		for phase in initial restarted; do \
			if [ "$$phase" = "restarted" ]; then \
				docker restart $$name >/dev/null; \
			fi; \
			echo "Waiting for $$phase varnishd HTTP on $$host_port..."; \
			timeout=30; \
			status="000"; \
			while [ $$timeout -gt 0 ]; do \
				status=$$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://localhost:$$host_port || true); \
				if [ "$$status" != "000" ]; then \
					echo "OK: $$phase container served HTTP $$status"; \
					break; \
				fi; \
				sleep 1; \
				timeout=$$((timeout - 1)); \
			done; \
			if [ "$$status" = "000" ]; then \
				echo "FAIL: $$phase container did not expose HTTP on $$host_port"; \
				docker logs $$name; \
				exit 1; \
			fi; \
		done; \
		echo "=== Test: Container restart PASSED ==="

test-smoke-runtime-interface:
	@echo "=== Test: Runtime start interface ==="
	@set -euo pipefail; \
	name="$(CONTAINER_PREFIX)-runtime-$$(openssl rand -hex 4)"; \
	host_port=18081; \
		tmpdir=$$(mktemp -d); \
		trap "docker rm -f $$name >/dev/null 2>&1; rm -rf $$tmpdir" EXIT; \
		docker run -d --name $$name \
			-e VARNISH_LISTEN=0.0.0.0:8080 \
			-p $$host_port:8080 \
			$(IMAGE) >/dev/null; \
		echo "Waiting for overridden HTTP listener on $$host_port..."; \
		timeout=30; \
		status="000"; \
		while [ $$timeout -gt 0 ]; do \
			status=$$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://localhost:$$host_port || true); \
			if [ "$$status" != "000" ]; then \
				echo "OK: runtime override served HTTP $$status on port $$host_port"; \
				break; \
			fi; \
			sleep 1; \
			timeout=$$((timeout - 1)); \
		done; \
		if [ "$$status" = "000" ]; then \
			echo "FAIL: runtime override did not expose HTTP on port $$host_port"; \
			docker logs $$name; \
			exit 1; \
		fi; \
		docker rm -f $$name >/dev/null; \
		log_file="$$tmpdir/invalid-listen.log"; \
		set +e; \
		docker run --rm -e VARNISH_LISTEN=invalid $(IMAGE) >"$$log_file" 2>&1 & \
		pid=$$!; \
		for _ in 1 2 3 4 5; do \
			if ! kill -0 $$pid >/dev/null 2>&1; then \
				break; \
			fi; \
			sleep 1; \
		done; \
		if kill -0 $$pid >/dev/null 2>&1; then \
			kill $$pid >/dev/null 2>&1 || true; \
			wait $$pid >/dev/null 2>&1 || true; \
			status=124; \
		else \
			wait $$pid; \
			status=$$?; \
		fi; \
		set -e; \
		if [ $$status -eq 0 ] || [ $$status -eq 124 ]; then \
			echo "FAIL: invalid VARNISH_LISTEN should fail fast"; \
			cat "$$log_file"; \
			exit 1; \
		fi; \
	if ! grep -q "Invalid VARNISH_LISTEN" "$$log_file"; then \
		echo "FAIL: invalid VARNISH_LISTEN should fail clearly"; \
		cat "$$log_file"; \
		exit 1; \
	fi; \
	log_file="$$tmpdir/start-backend-conflict.log"; \
	set +e; \
	docker run --rm -e VARNISH_START='echo hi' -e VARNISH_BACKEND_HOST=localhost $(IMAGE) >"$$log_file" 2>&1 & \
	pid=$$!; \
	for _ in 1 2 3 4 5; do \
		if ! kill -0 $$pid >/dev/null 2>&1; then \
			break; \
		fi; \
		sleep 1; \
	done; \
	if kill -0 $$pid >/dev/null 2>&1; then \
		kill $$pid >/dev/null 2>&1 || true; \
		wait $$pid || true; \
		status=124; \
	else \
		wait $$pid; \
		status=$$?; \
	fi; \
	set -e; \
	if [ $$status -eq 0 ] || [ $$status -eq 124 ]; then \
		echo "FAIL: VARNISH_START with VARNISH_BACKEND_* should fail fast"; \
		cat "$$log_file"; \
		exit 1; \
	fi; \
	if ! grep -q "VARNISH_START cannot be combined" "$$log_file"; then \
		echo "FAIL: VARNISH_START with VARNISH_BACKEND_* should fail clearly"; \
		cat "$$log_file"; \
		exit 1; \
	fi; \
	name="$(CONTAINER_PREFIX)-backend-config-$$(openssl rand -hex 4)"; \
	docker run -d --name $$name \
		-e VARNISH_BACKEND_HOST=localhost \
		-e VARNISH_BACKEND_PORT=9090 \
		-e VARNISH_BACKEND_PROBE_PATH=/healthz \
		-p 18082:80 \
		$(IMAGE) >/dev/null; \
	echo "Waiting for backend-configured container on 18082..."; \
	timeout=30; \
	status="000"; \
	while [ $$timeout -gt 0 ]; do \
		status=$$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://localhost:18082 || true); \
		if [ "$$status" != "000" ]; then \
			echo "OK: backend-configured runtime served HTTP $$status"; \
			break; \
		fi; \
		sleep 1; \
		timeout=$$((timeout - 1)); \
	done; \
	if [ "$$status" = "000" ]; then \
		echo "FAIL: backend-configured runtime did not expose HTTP on 18082"; \
		docker logs $$name; \
		docker rm -f $$name >/dev/null 2>&1 || true; \
		exit 1; \
	fi; \
	docker exec $$name grep -q '.host = "localhost";' /etc/varnish/backend.vcl || { \
		echo "FAIL: expected rendered backend host in backend VCL"; \
		docker exec $$name cat /etc/varnish/backend.vcl; \
		exit 1; \
	}; \
	docker exec $$name grep -q '.port = "9090";' /etc/varnish/backend.vcl || { \
		echo "FAIL: expected rendered backend port in backend VCL"; \
		docker exec $$name cat /etc/varnish/backend.vcl; \
		exit 1; \
	}; \
	docker exec $$name grep -q '.url = "/healthz";' /etc/varnish/backend.vcl || { \
		echo "FAIL: expected rendered backend probe path in backend VCL"; \
		docker exec $$name cat /etc/varnish/backend.vcl; \
		exit 1; \
	}; \
	docker exec $$name /usr/sbin/varnishd -C -f /etc/varnish/default.vcl >/dev/null 2>&1; \
	docker rm -f $$name >/dev/null; \
	echo "OK: invalid listen configuration failed clearly"; \
	echo "=== Test: Runtime start interface PASSED ==="

test-backend-config-adapter:
	@echo "=== Test: Backend configuration adapter ==="
	@./test/e2e/assert-backend-config-adapter.sh
	@echo "=== Test: Backend configuration adapter PASSED ==="

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
	@echo "=== Test: Hostile static asset strips cookies stays cacheable ==="
	@./test/e2e/run-hostile-scenario.sh static-cookie

test-hostile-static-cookie-canary:
	@echo "=== Test: Hostile static asset depends on shared cache policy ==="
	@set -euo pipefail; \
	log_file=$$(mktemp); \
	trap 'rm -f "$$log_file"' EXIT; \
	if HOSTILE_CACHE_POLICY_PATH="$$(pwd)/test/e2e/fixtures/cache-policy-static-cookie-pass.vcl" ./test/e2e/run-hostile-scenario.sh static-cookie >"$$log_file" 2>&1; then \
		echo "FAIL: hostile static-cookie scenario passed with a mutant shared cache policy"; \
		cat "$$log_file"; \
		exit 1; \
	fi; \
	if ! grep -Eq "first static asset request|second static asset request" "$$log_file"; then \
		echo "FAIL: hostile static-cookie canary should fail with semantic cache-domain assertion"; \
		cat "$$log_file"; \
		exit 1; \
	fi; \
	echo "OK: hostile static-cookie scenario failed under mutant shared cache policy"

test-hostile-account-cookie-isolation:
	@echo "=== Test: Hostile account requests cookies stay isolated per client ==="
	@./test/e2e/run-hostile-scenario.sh account-cookie

test-hostile-set-cookie-isolation:
	@echo "=== Test: Hostile Set-Cookie responses not shared across clients ==="
	@./test/e2e/run-hostile-scenario.sh set-cookie

test-e2e-scenario-config:
	@echo "=== Test: E2E hostile scenario config ==="
	@./test/e2e/assert-scenario-compose-config.sh

test-e2e-harness-module:
	@echo "=== Test: E2E harness module ==="
	@./test/e2e/assert-e2e-harness-module.sh

test-5xx-not-cached:
	@echo "=== Test: Backend 5xx responses not served from cache ==="
	@./test/e2e/run-hostile-scenario.sh 5xx

test-purge-unauthorized:
	@echo "=== Test: Unauthorized PURGE outside ACL returns 405 ==="
	@./test/e2e/run-hostile-scenario.sh purge-acl

test-post-not-cached:
	@echo "=== Test: POST cached URL bypasses cache hits origin ==="
	@./test/e2e/run-hostile-scenario.sh post

test-grace-stale:
	@echo "=== Test: Grace serves stale cached object when backend is unavailable ==="
	@./test/e2e/run-hostile-scenario.sh grace

test-perf:
	@echo "=== Test: Performance and caching effectiveness ==="
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
	echo ""; \
	echo "=== Performance Test: Cache MISS (uncached requests) ==="; \
	echo "Testing with 1000 requests, 50 concurrent..."; \
	ab -n 1000 -c 50 -q http://localhost/?cachebust=$$(openssl rand -hex 8) 2>&1 | grep -E '(Requests per second|Time per request|Failed requests)'; \
	miss_rps=$$(ab -n 1000 -c 50 -q http://localhost/?cachebust=$$(openssl rand -hex 8) 2>&1 | grep 'Requests per second' | awk '{print $$4}'); \
	echo "Cache MISS performance: $$miss_rps req/sec"; \
	echo ""; \
	echo "=== Performance Test: Cache HIT (cached requests) ==="; \
	test_url="http://localhost/?perf-test=$$(openssl rand -hex 8)"; \
	echo "Priming cache..."; \
	curl -sf --max-time 10 "$$test_url" >/dev/null; \
	cache=$$(curl -sI --max-time 10 "$$test_url" | grep -i x-cache); \
	if ! echo "$$cache" | grep -qi HIT; then \
		echo "FAIL: Cache not warming properly: $$cache"; \
		exit 1; \
	fi; \
	echo "OK: Cache primed"; \
	echo "Testing with 1000 requests, 50 concurrent..."; \
	ab -n 1000 -c 50 -q "$$test_url" 2>&1 | grep -E '(Requests per second|Time per request|Failed requests)'; \
	hit_rps=$$(ab -n 1000 -c 50 -q "$$test_url" 2>&1 | grep 'Requests per second' | awk '{print $$4}'); \
	echo "Cache HIT performance: $$hit_rps req/sec"; \
	echo ""; \
	echo "=== Performance Validation ==="; \
	improvement=$$(awk "BEGIN {printf \"%.2f\", ($$hit_rps / $$miss_rps)}"); \
	echo "Cache HIT is $$improvement times faster than MISS"; \
	if [ $$(awk "BEGIN {print ($$hit_rps <= $$miss_rps)}") -eq 1 ]; then \
		echo "FAIL: Cache HITs ($$hit_rps req/sec) should be faster than MISSes ($$miss_rps req/sec)"; \
		exit 1; \
	fi; \
	echo "OK: Cache HITs are measurably faster than MISSes"; \
	echo ""; \
	echo "=== Concurrency stress test ==="; \
	echo "Testing with 2000 requests, 100 concurrent..."; \
	ab -n 2000 -c 100 -q "$$test_url" 2>&1 | grep -E '(Requests per second|Failed requests)'; \
	concurrent_rps=$$(ab -n 2000 -c 100 -q "$$test_url" 2>&1 | grep 'Requests per second' | awk '{print $$4}'); \
	echo "High concurrency performance: $$concurrent_rps req/sec"; \
	if [ $$(ab -n 2000 -c 100 -q "$$test_url" 2>&1 | grep 'Failed requests' | awk '{print $$3}') -gt 0 ]; then \
		echo "FAIL: Failed requests under load"; \
		exit 1; \
	fi; \
	echo "OK: No failed requests under high concurrency"; \
	echo ""; \
	echo "=== Performance Summary ==="; \
	echo "  Cache MISS: $$miss_rps req/sec"; \
	echo "  Cache HIT:  $$hit_rps req/sec"; \
	echo "  High load:  $$concurrent_rps req/sec"; \
	echo "  Speedup:    $${improvement}x"; \
	echo ""; \
	echo "Note: With fast backends like nginx, cache speedup may be modest."; \
	echo "The key benefit is reduced backend load and consistent performance under high concurrency."; \
	echo ""; \
	echo "=== Test: Performance and caching effectiveness PASSED ==="

test-campaign: build
	@echo "=== Test: Long and vigorous bug-finding campaign (resource-capped container) ==="
	@set -euo pipefail; \
	docker build -t varnish-campaign:latest test/campaign >/dev/null; \
	docker run --rm \
		--cpus 2 \
		--memory 2g \
		--memory-swap 2g \
		--pids-limit 1000 \
		-v "$$(pwd)/test/campaign:/campaign" \
		-v "$$(pwd)/cache-policy.vcl:/etc/varnish/cache-policy.vcl:ro" \
		varnish-campaign:latest
