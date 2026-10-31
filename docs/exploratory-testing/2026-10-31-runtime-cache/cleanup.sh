#!/bin/bash
docker rm -f -v exp-varnish-20261031 exp-origin-20261031 >/dev/null 2>&1 || true
docker network rm exp-varnish-20261031 >/dev/null 2>&1 || true
docker image rm exp-varnish-20261031:local >/dev/null 2>&1 || true
