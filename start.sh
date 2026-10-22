#!/bin/bash

set -euo pipefail

fail() {
	echo "ERROR: $*" >&2
	exit 1
}

check_mode=false
case "$#" in
	0) ;;
	1)
		if [ "$1" = "--check" ]; then
			check_mode=true
		else
			fail "Unknown argument '$1'; expected --check"
		fi
		;;
	*)
		fail "Unknown arguments '$*'; expected --check or no arguments"
		;;
esac

if [ "${check_mode}" = true ] && [ -n "${VARNISH_START:-}" ]; then
	fail "VARNISH_START cannot be used with --check"
fi

if [ -n "${VARNISH_START:-}" ]; then
	# Defaults belong below this branch so they do not look caller-supplied here.
	if [ -n "${VARNISH_LISTEN:-}" ] || [ -n "${VARNISH_VCL:-}" ] || [ -n "${VARNISH_STORAGE:-}" ] || [ -n "${VARNISH_EXTRA_ARGS:-}" ] || [ -n "${VARNISH_BACKEND_HOST:-}" ] || [ -n "${VARNISH_BACKEND_PORT:-}" ] || [ -n "${VARNISH_BACKEND_PROBE_PATH:-}" ]; then
		fail "VARNISH_START cannot be combined with VARNISH_LISTEN, VARNISH_VCL, VARNISH_STORAGE, VARNISH_EXTRA_ARGS, or VARNISH_BACKEND_*"
	fi

	exec /bin/bash -lc "export PATH=\"/usr/sbin:\$PATH\"; ${VARNISH_START}"
fi

listen="${VARNISH_LISTEN:-0.0.0.0:80}"
vcl_path="${VARNISH_VCL:-/etc/varnish/default.vcl}"
storage="${VARNISH_STORAGE:-malloc,1g}"
extra_args="${VARNISH_EXTRA_ARGS:-}"
backend_host="${VARNISH_BACKEND_HOST:-}"
backend_port="${VARNISH_BACKEND_PORT:-}"
backend_probe_path="${VARNISH_BACKEND_PROBE_PATH:-}"

if [ -n "${backend_host}${backend_port}${backend_probe_path}" ]; then
	if [ "${vcl_path}" != "/etc/varnish/default.vcl" ]; then
		fail "VARNISH_BACKEND_* requires VARNISH_VCL to be /etc/varnish/default.vcl"
	fi

fi

listen_host="${listen%:*}"
listen_port="${listen##*:}"

if [ -z "${listen_host}" ] || [ -z "${listen_port}" ]; then
	fail "Invalid VARNISH_LISTEN '${listen}'; expected host:port"
fi

case "${listen_port}" in
	''|*[!0-9]*)
		fail "Invalid VARNISH_LISTEN '${listen}'; expected numeric port"
		;;
esac

if [ "${listen_port}" -lt 1 ] || [ "${listen_port}" -gt 65535 ]; then
	fail "Invalid VARNISH_LISTEN '${listen}'; expected port between 1 and 65535"
fi

if [ ! -f "${vcl_path}" ]; then
	fail "Invalid VARNISH_VCL '${vcl_path}'; file does not exist"
fi

case "${storage}" in
	*,*)
		storage_backend="${storage%%,*}"
		storage_size="${storage#*,}"
		;;
	*)
		fail "Invalid VARNISH_STORAGE '${storage}'; expected backend,size"
		;;
esac

if [ -z "${storage_backend}" ] || [ -z "${storage_size}" ]; then
	fail "Invalid VARNISH_STORAGE '${storage}'; expected backend,size"
fi

extra_words=()
if [ -n "${extra_args}" ]; then
	read -r -a extra_words <<< "${extra_args}"
fi

# Populate an array, preserving argument boundaries for both invocation modes.
varnishd_args() {
	args=(
		/usr/sbin/varnishd
		"$1"
		-f "${vcl_path}"
		-a "${listen}"
		-s "${storage}"
	)
	if [ "${#extra_words[@]}" -gt 0 ]; then
		args+=("${extra_words[@]}")
	fi
}

# Candidates live on the destination filesystem so publication is one atomic rename.
# Without overrides, retain the caller's backend (including hand-edited files).
if [ -n "${backend_host}${backend_port}${backend_probe_path}" ]; then
	scratch="$(mktemp -d /etc/varnish/.backend-XXXXXX)"
else
	scratch="$(mktemp -d)"
fi
trap 'rm -rf "$scratch"' EXIT

if [ -n "${backend_host}${backend_port}${backend_probe_path}" ]; then
	/usr/local/bin/render-vcl "${scratch}/backend.vcl"
fi

if [ "${check_mode}" = true ] || [ -f "${scratch}/backend.vcl" ]; then
	varnishd_args -C
	# Isolate compiler artifacts from the running instance and concurrent checks.
	# Relative backend includes resolve to the candidate first, policy includes to
	# the installed configuration. No VCL text rewriting is needed.
	args+=(-n "${scratch}/instance")
	if [ -f "${scratch}/backend.vcl" ]; then
		args+=(-p "vcl_path=${scratch}:/etc/varnish")
	fi
	if "${args[@]}" >"${scratch}/compile-output" 2>&1; then
		:
	else
		compile_status=$?
		cat "${scratch}/compile-output" >&2
		exit "${compile_status}"
	fi
	if [ "${check_mode}" = true ]; then
		exit 0
	fi
	mv -f "${scratch}/backend.vcl" /etc/varnish/backend.vcl
fi

rm -rf "${scratch}"
trap - EXIT

varnishd_args -F
exec "${args[@]}"

