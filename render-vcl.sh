#!/bin/bash

set -euo pipefail

template_path="${1:-/etc/varnish/default.vcl.template}"
output_path="${2:-/etc/varnish/default.vcl}"
backend_host="${VARNISH_BACKEND_HOST:-127.0.0.1}"
backend_port="${VARNISH_BACKEND_PORT:-8080}"
backend_probe_path="${VARNISH_BACKEND_PROBE_PATH:-/}"

escape_sed_replacement() {
	printf '%s' "$1" | sed -e 's/[\/&]/\\&/g'
}

if [ ! -f "${template_path}" ]; then
	echo "ERROR: VCL template '${template_path}' does not exist" >&2
	exit 1
fi

case "${backend_port}" in
	''|*[!0-9]*)
		echo "ERROR: Invalid VARNISH_BACKEND_PORT '${backend_port}'; expected digits" >&2
		exit 1
		;;
esac

case "${backend_probe_path}" in
	/*) ;;
	*)
		echo "ERROR: Invalid VARNISH_BACKEND_PROBE_PATH '${backend_probe_path}'; expected absolute path" >&2
		exit 1
		;;
esac

sed \
	-e "s/__BACKEND_HOST__/$(escape_sed_replacement "${backend_host}")/g" \
	-e "s/__BACKEND_PORT__/$(escape_sed_replacement "${backend_port}")/g" \
	-e "s/__BACKEND_PROBE_PATH__/$(escape_sed_replacement "${backend_probe_path}")/g" \
	"${template_path}" > "${output_path}"
