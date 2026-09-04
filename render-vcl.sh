#!/bin/bash

set -euo pipefail

output_path="${1:-/etc/varnish/backend.vcl}"
backend_host="${VARNISH_BACKEND_HOST:-127.0.0.1}"
backend_port="${VARNISH_BACKEND_PORT:-8080}"
backend_probe_path="${VARNISH_BACKEND_PROBE_PATH:-/}"

escape_vcl_string() {
	printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

case "${backend_host}" in
	*[$'\r\n']*|*[[:space:]]*|*[\'\"\;\\\{\}]*)
		echo "ERROR: Invalid VARNISH_BACKEND_HOST '${backend_host}'; contains invalid characters" >&2
		exit 1
		;;
esac

case "${backend_port}" in
	''|*[!0-9]*)
		echo "ERROR: Invalid VARNISH_BACKEND_PORT '${backend_port}'; expected digits" >&2
		exit 1
		;;
esac

if [ "${backend_port}" -lt 1 ] || [ "${backend_port}" -gt 65535 ]; then
	echo "ERROR: Invalid VARNISH_BACKEND_PORT '${backend_port}'; expected port between 1 and 65535" >&2
	exit 1
fi

case "${backend_probe_path}" in
	/*) ;;
	*)
		echo "ERROR: Invalid VARNISH_BACKEND_PROBE_PATH '${backend_probe_path}'; expected absolute path" >&2
		exit 1
		;;
esac

case "${backend_probe_path}" in
	*[$'\r\n']*|*[\'\"\;\\\{\}]*)
		echo "ERROR: Invalid VARNISH_BACKEND_PROBE_PATH '${backend_probe_path}'; contains invalid characters" >&2
		exit 1
		;;
esac

cat > "${output_path}" <<EOF
probe backend_probe {
    .url = "$(escape_vcl_string "${backend_probe_path}")";
    .timeout = 2s;
    .interval = 5s;
    .window = 5;
    .threshold = 3;
}

backend default {
    .host = "$(escape_vcl_string "${backend_host}")";
    .port = "$(escape_vcl_string "${backend_port}")";
    .probe = backend_probe;
}
EOF
