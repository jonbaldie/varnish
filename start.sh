#!/bin/bash

set -euo pipefail

fail() {
	echo "ERROR: $*" >&2
	exit 1
}

if [ -n "${VARNISH_START:-}" ]; then
	if [ -n "${VARNISH_LISTEN:-}" ] || [ -n "${VARNISH_VCL:-}" ] || [ -n "${VARNISH_STORAGE:-}" ] || [ -n "${VARNISH_EXTRA_ARGS:-}" ]; then
		fail "VARNISH_START cannot be combined with VARNISH_LISTEN, VARNISH_VCL, VARNISH_STORAGE, or VARNISH_EXTRA_ARGS"
	fi

	exec /bin/bash -lc "${VARNISH_START}"
fi

listen="${VARNISH_LISTEN:-0.0.0.0:80}"
vcl_path="${VARNISH_VCL:-/etc/varnish/default.vcl}"
storage="${VARNISH_STORAGE:-malloc,1g}"
extra_args="${VARNISH_EXTRA_ARGS:-}"

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
