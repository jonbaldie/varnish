#!/bin/bash
set +e
docker rm -f -v exp-varnish-20261108 exp-origin-20261108 exp-check-20261108 >/dev/null 2>&1
docker network rm exp-varnish-20261108 >/dev/null 2>&1
docker image rm exp-varnish-20261108:local >/dev/null 2>&1
exit 0
