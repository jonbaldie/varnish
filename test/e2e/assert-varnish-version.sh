#!/usr/bin/env bash
# Regression check for #176 (VSV00020/VSV00018, DSA-6584-1):
# the shipped image must carry the supported fixed Varnish revision on trixie.
# Real image check: runs capped containers against the built image and asserts
# package inventory + varnishd version. No mocks.
set -euo pipefail

image="${1:-jonbaldie/varnish:latest}"
fixed_varnish="7.7.0-3+deb13u2"
fixed_pcre2="10.46-1~deb13u3"

run_sh() {
  docker run --rm --cpus 1 --memory 512m --pids-limit 100 --entrypoint sh "$image" -c "$1"
}

codename="$(run_sh '. /etc/os-release; printf %s "$VERSION_CODENAME"')"
if [ "$codename" != "trixie" ]; then
  echo "FAIL: expected Debian codename trixie (DSA-6584-1 fixed release), got '${codename}'" >&2
  run_sh 'cat /etc/os-release' >&2 || true
  exit 1
fi
echo "OK: Debian codename is trixie"

for pkg in varnish libvarnishapi3; do
  ver="$(run_sh "dpkg -s \"$pkg\" | sed -n 's/^Version: //p'")"
  if [ -z "$ver" ]; then
    echo "FAIL: package $pkg not found in image $image" >&2
    exit 1
  fi
  echo "INFO: $pkg=$ver"
  if ! run_sh "dpkg --compare-versions \"$ver\" ge \"$fixed_varnish\""; then
    echo "FAIL: $pkg $ver is older than fixed revision $fixed_varnish (DSA-6584-1, VSV00020/VSV00018)" >&2
    exit 1
  fi
  echo "OK: $pkg $ver >= $fixed_varnish"
done

pcre_ver="$(run_sh "dpkg -s libpcre2-8-0 | sed -n 's/^Version: //p'")"
echo "INFO: libpcre2-8-0=$pcre_ver"
if ! run_sh "dpkg --compare-versions \"$pcre_ver\" ge \"$fixed_pcre2\""; then
  echo "FAIL: libpcre2-8-0 $pcre_ver is older than fixed revision $fixed_pcre2 (CVE-2026-89160/CVE-2026-89156)" >&2
  exit 1
fi
echo "OK: libpcre2-8-0 $pcre_ver >= $fixed_pcre2"

version_output="$(docker run --rm --cpus 1 --memory 512m --pids-limit 100 --entrypoint varnishd "$image" -V 2>&1 || true)"
echo "INFO: $version_output" | head -n 1
case "$version_output" in
  *varnish-7.7.0*) echo "OK: varnishd reports 7.7.0" ;;
  *)
    echo "FAIL: varnishd -V did not report varnish-7.7.0: $version_output" >&2
    exit 1
    ;;
esac

echo "OK: Varnish package versions are at or above the DSA-6584-1 fixed revisions"
