#!/usr/bin/env bash
set -euo pipefail

image="${1:-jonbaldie/varnish:latest}"
tmpdir="$(mktemp -d)"
containers=()

cleanup() {
    for name in "${containers[@]}"; do
        docker rm -f "$name" >/dev/null 2>&1 || true
    done
    rm -rf "$tmpdir"
}
trap cleanup EXIT

new_name() {
    printf 'varnish-test-config-check-%s' "$(openssl rand -hex 4)"
}

wait_for_exit() {
    local name="$1"
    for _ in {1..100}; do
        if [[ "$(docker inspect -f '{{.State.Status}}' "$name")" == "exited" ]]; then
            return 0
        fi
        sleep 0.1
    done
    echo "FAIL: $name did not exit"
    docker logs "$name" || true
    return 1
}

run_invocation() {
    local name="$1"
    local command="$2"
    shift 2
    containers+=("$name")
    docker run -d --name "$name" "$@" --entrypoint /bin/bash "$image" \
        -c "$command > /tmp/start.stdout 2> /tmp/start.stderr" >/dev/null
    wait_for_exit "$name"
    check_status="$(docker inspect -f '{{.State.ExitCode}}' "$name")"
    docker cp "$name:/tmp/start.stdout" "$tmpdir/$name.stdout" >/dev/null
    docker cp "$name:/tmp/start.stderr" "$tmpdir/$name.stderr" >/dev/null
}

run_check() {
    local name="$1"
    shift
    run_invocation "$name" '/start.sh --check' "$@"
}

run_start() {
    local name="$1"
    shift
    containers+=("$name")
    docker run -d --name "$name" "$@" "$image" /start.sh >/dev/null
}

assert_check_output() {
    local name="$1"
    cat "$tmpdir/$name.stdout" "$tmpdir/$name.stderr"
}

name="$(new_name)"
run_check "$name"
if [[ "$check_status" != 0 ]]; then
    echo "FAIL: default /start.sh --check exited $check_status"
    assert_check_output "$name"
    exit 1
fi
if [[ -s "$tmpdir/$name.stdout" ]]; then
    echo "FAIL: successful /start.sh --check wrote to stdout"
    cat "$tmpdir/$name.stdout"
    exit 1
fi
echo "OK: default config check succeeds without stdout"

name="$(new_name)"
run_check "$name" -e VARNISH_BACKEND_HOST=nosuchhost
if [[ "$check_status" == 0 ]]; then
    echo "FAIL: unresolvable backend passed /start.sh --check"
    exit 1
fi
if ! grep -Eiq 'VCC-compiler failed|VCL compilation failed|failed to resolve|could not resolve' \
    "$tmpdir/$name.stdout" "$tmpdir/$name.stderr"; then
    echo "FAIL: backend compile error was not reported"
    assert_check_output "$name"
    exit 1
fi
echo "OK: unresolvable backend fails configuration check with compiler output"

name="$(new_name)"
run_check "$name" -e 'VARNISH_START=echo override'
if [[ "$check_status" == 0 ]] || ! grep -Fq 'VARNISH_START cannot be used with --check' \
    "$tmpdir/$name.stdout" "$tmpdir/$name.stderr"; then
    echo "FAIL: --check did not clearly reject VARNISH_START"
    assert_check_output "$name"
    exit 1
fi
echo "OK: --check rejects VARNISH_START"

name="$(new_name)"
run_invocation "$name" '/start.sh --unknown'
if [[ "$check_status" == 0 ]] || ! grep -Fq 'Unknown argument' \
    "$tmpdir/$name.stdout" "$tmpdir/$name.stderr"; then
    echo "FAIL: start.sh did not reject an unknown argument"
    assert_check_output "$name"
    exit 1
fi
echo "OK: start.sh rejects unknown arguments"

name="$(new_name)"
run_check "$name" -e VARNISH_LISTEN=invalid
if [[ "$check_status" == 0 ]] || ! grep -Fq 'ERROR: Invalid VARNISH_LISTEN' \
    "$tmpdir/$name.stdout" "$tmpdir/$name.stderr"; then
    echo "FAIL: --check did not preserve the runtime validation error"
    assert_check_output "$name"
    exit 1
fi
echo "OK: --check preserves runtime validation errors"

name="$(new_name)"
run_start "$name"
sleep 2
if [[ "$(docker inspect -f '{{.State.Running}}' "$name")" != true ]]; then
    echo "FAIL: real start did not remain running for the valid default config"
    docker logs "$name" || true
    exit 1
fi
echo "OK: configuration check and real start both accept the default config"

name="$(new_name)"
run_start "$name" -e VARNISH_BACKEND_HOST=nosuchhost
wait_for_exit "$name"
start_status="$(docker inspect -f '{{.State.ExitCode}}' "$name")"
if [[ "$start_status" == 0 ]]; then
    echo "FAIL: real start accepted the unresolvable backend"
    exit 1
fi
echo "OK: configuration check and real start both reject an unresolvable backend"
