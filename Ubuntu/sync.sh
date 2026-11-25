#!/usr/bin/env bash
set -euo pipefail
DISTRO=Ubuntu
UPSTREAM=https://git.launchpad.net/livecd-rootfs
DEFAULT_REF=ubuntu/master

# Upstream only ships the OCI/container profile from bionic onwards. Probe the
# branch instead of hard-coding versions, so a suite that loses the profile is
# dropped automatically and no future release needs a manual edit.
ref_has_oci_profile() {
  local ref=$1
  rm -rf profile-probe.git
  git init --bare --quiet profile-probe.git
  if ! git -c protocol.version=1 -C profile-probe.git fetch --quiet --depth=1 --no-tags \
      "$UPSTREAM" "refs/heads/$ref" 2>/dev/null; then
    return 2
  fi
  git -C profile-probe.git show FETCH_HEAD:live-build/auto/config 2>/dev/null | grep -q 'ubuntu-oci)'
}

discover_releases() {
  curl -fsSL --retry 3 https://changelogs.ubuntu.com/meta-release -o release-data
  # meta-release reports point releases ("20.04.5 LTS"); Docker Hub publishes only
  # major.minor tags ("20.04"), so trim the value before it becomes an image tag.
  awk 'BEGIN {RS=""; FS="\n"} {dist=""; version=""; supported=0;
    for(i=1;i<=NF;i++) {
      if($i ~ /^Dist: /) dist=substr($i,7);
      if($i ~ /^Version: /) {
        version=substr($i,10); sub(/ .*/,"",version);
        split(version, parts, "."); version=parts[1] "." parts[2];
      }
      if($i == "Supported: 1") supported=1;
    } if(supported && dist != "" && version != "") print dist,version;
  }' release-data > supported
  while read -r suite version; do
    ref="ubuntu/$suite"
    if ! grep -q "refs/heads/$ref$" upstream-refs; then ref="$DEFAULT_REF"; fi
    status=0
    ref_has_oci_profile "$ref" || status=$?
    if [[ "$status" == 1 ]]; then
      echo "Skipping $suite: upstream $ref has no ubuntu-oci profile." >&2
      continue
    fi
    entry "$version" "$ref" "docker.io/library/ubuntu:$version" "[\"$suite\"]"
  done < supported
  add_latest_alias
}

keep_path() {
  case "$1" in
    live-build/auto/*|debian/*|COPYING|README*|minimize-manual|auto-markable-pkgs|sync-mtime) return 0 ;;
    live-build/*) [[ "${1#live-build/}" != */* ]] ;;
    *) return 1 ;;
  esac
}
source "$(dirname -- "$0")/../scripts/sync-common.sh"
