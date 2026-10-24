#!/bin/bash
docker rm -fv vx24-varnish vx24-origin >/dev/null 2>&1 || true
docker network rm vx24-net >/dev/null 2>&1 || true
