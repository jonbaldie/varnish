#!/bin/bash

set -euo pipefail

fail() {
	echo "ERROR: $*" >&2
	exit 1
}

if [ -n "${VARNISH_START:-}" ]; then
	if [ -n "${VARNISH_LISTEN:-}" ] || [ -n "${VARNISH_VCL:-}" ] || [ -n "${VARNISH_STORAGE:-}" ] || [ -n "${VARNISH_EXTRA_ARGS:-}" ] || [ -n "${VARNISH_BACKEND_HOST:-}" ] || [ -n "${VARNISH_BACKEND_PORT:-}" ] || [ -n "${VARNISH_BACKEND_PROBE_PATH:-}" ]; then
		fail "VARNISH_START cannot be combined with VARNISH_LISTEN, VARNISH_VCL, VARNISH_STORAGE, VARNISH_EXTRA_ARGS, or VARNISH_BACKEND_*"
	fi

	exec /bin/bash -lc "${VARNISH_START}"
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

	VARNISH_BACKEND_HOST="${backend_host:-127.0.0.1}" \
	VARNISH_BACKEND_PORT="${backend_port:-8080}" \
	VARNISH_BACKEND_PROBE_PATH="${backend_probe_path:-/}" \
		/usr/local/bin/render-vcl /etc/varnish/backend.vcl
fi

case "${listen}" in
	*:* ) ;;
	* )
		fail "Invalid VARNISH_LISTEN '${listen}'; expected host:port"
		;;
esac

if [ ! -f "${vcl_path}" ]; then
	fail "Invalid VARNISH_VCL '${vcl_path}'; file does not exist"
fi

case "${storage}" in
	*,* ) ;;
	* )
		fail "Invalid VARNISH_STORAGE '${storage}'; expected backend,size"
		;;
esac

args=(
	/usr/sbin/varnishd
	-F
	-f "${vcl_path}"
	-a "${listen}"
	-s "${storage}"
)

if [ -n "${extra_args}" ]; then
	read -r -a extra_words <<< "${extra_args}"
	args+=("${extra_words[@]}")
fi

exec "${args[@]}"
