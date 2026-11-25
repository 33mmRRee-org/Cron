#!/usr/bin/env bash
set -euo pipefail
DISTRO=Ubuntu
UPSTREAM=https://git.launchpad.net/livecd-rootfs
DEFAULT_REF=ubuntu/master

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
    grep -q "refs/heads/$ref$" upstream-refs || ref="$DEFAULT_REF"
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
