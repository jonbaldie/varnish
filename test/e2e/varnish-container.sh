#!/usr/bin/env bash

find_varnish_container() {
    local project="$1"

    docker ps \
        --filter "label=com.docker.compose.project=${project}" \
        --format '{{.ID}} {{.Label "com.docker.compose.service"}}' \
        | awk '$2 ~ /^varnish/ { print $1; exit }'
}
