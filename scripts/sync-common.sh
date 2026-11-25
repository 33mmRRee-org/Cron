#!/usr/bin/env bash
# Shared snapshot and GitHub publishing mechanics. Distribution policy lives in each sync.sh.
REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d "${RUNNER_TEMP:-/tmp}/container-source-sync.XXXXXXXX")
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"
if ! declare -F extra_refs >/dev/null; then extra_refs() { :; }; fi
add_latest_alias() {
  jq -e 'length > 0' releases.json >/dev/null
  newest=$(jq -r 'sort_by(.version | split(".") | map(tonumber)) | last | .version' releases.json)
  jq --arg newest "$newest" 'map(if .version == $newest then .aliases += ["latest"] else . end)' releases.json > next.json
  mv next.json releases.json
}
set -euo pipefail
test -n "${GH_TOKEN:-}" || { echo 'GH_TOKEN secret is required.' >&2; exit 1; }
org=33mmRRee-org
target="https://github.com/$org/$DISTRO.git"
marker="Managed by $org/Cron; upstream: $UPSTREAM; scope: container production code"
today=$(date -u +%F)
git -c protocol.version=1 ls-remote --heads "$UPSTREAM" > upstream-refs
test -s upstream-refs
printf '[]\n' > releases.json
entry() {
  jq --arg version "$1" --arg branch "$2" --arg bootstrap "$3" --argjson aliases "$4" \
    '. + [{version:$version,branch:$branch,bootstrap:$bootstrap,aliases:$aliases}]' \
    releases.json > next.json
  mv next.json releases.json
}
discover_releases
{ printf '%s\tmain\n' "$DEFAULT_REF"; jq -r '.[] | select(.branch!="main") | [.branch,.branch] | @tsv' releases.json; } | sort -u > selected-refs
extra_refs
sort -u -o selected-refs selected-refs
if description=$(gh api "repos/$org/$DISTRO" --jq '.description // ""' 2>/dev/null); then
  [[ "$description" == "Managed by $org/Cron; upstream: "* ]] \
    || { echo 'Refusing to replace a repository not managed by Cron.' >&2; exit 1; }
  gh api -X PATCH "repos/$org/$DISTRO" -f "description=$marker" --silent
else
  gh api -X POST "orgs/$org/repos" -f "name=$DISTRO" -f "description=$marker" \
    -F private=false -F auto_init=false --silent
fi
gh api -X PUT "repos/$org/$DISTRO/actions/permissions" -F enabled=false --silent
login=$(gh api user --jq .login)
uid=$(gh api user --jq .id)
export GIT_AUTHOR_NAME="$login" GIT_COMMITTER_NAME="$login"
export GIT_AUTHOR_EMAIL="$uid+$login@users.noreply.github.com" GIT_COMMITTER_EMAIL="$uid+$login@users.noreply.github.com"
auth=$(printf 'x-access-token:%s' "$GH_TOKEN" | base64 -w0)
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.https://github.com/.extraheader
export GIT_CONFIG_VALUE_0="AUTHORIZATION: basic $auth"
git ls-remote --refs --heads --tags "$target" > previous-refs
{ awk '$2=="main"' selected-refs; awk '$2!="main"' selected-refs; } > ordered-refs
# Fetch every selected branch in one pass. Ubuntu mirrors six upstream branches
# and a separate clone+fetch per branch dominated its runtime, while the refs a
# single remote serves can travel in one request.
rm -rf upstream.git
git init --bare --quiet upstream.git
declare -A fetched_from
while read -r upstream_ref _branch alternate_upstream; do
  selected_upstream=${alternate_upstream:-$UPSTREAM}
  [[ -z "${fetched_from[$selected_upstream]:-}" ]] || continue
  fetched_from[$selected_upstream]=1
  # Explicit refspecs are required: a bare "refs/heads/x" fetch lands only in
  # FETCH_HEAD and leaves no local ref for the archive step to read.
  mapfile -t specs < <(awk -v mirror="$selected_upstream" -v fallback="$UPSTREAM" \
    '{ source = ($3 == "" ? fallback : $3);
       if (source == mirror) { ref = "refs/heads/" $1; print "+" ref ":" ref } }' ordered-refs)
  git -c protocol.version=1 -C upstream.git fetch --quiet --depth=1 --no-tags \
    "$selected_upstream" "${specs[@]}"
done < ordered-refs

while read -r upstream_ref branch alternate_upstream; do
  selected_upstream=${alternate_upstream:-$UPSTREAM}
  rm -rf snapshot
  git -C upstream.git rev-parse --verify --quiet "refs/heads/$upstream_ref" >/dev/null \
    || git -c protocol.version=1 -C upstream.git fetch --quiet --depth=1 --no-tags \
        "$selected_upstream" "refs/heads/$upstream_ref" >/dev/null 2>&1
  oid=$(git -C upstream.git rev-parse "refs/heads/$upstream_ref")
  stamp=$(git -C upstream.git show -s --format=%cI "refs/heads/$upstream_ref")
  mkdir snapshot
  paths=()
  while IFS= read -r -d '' path; do
    if keep_path "$path"; then paths+=("$path"); fi
  done < <(git -C upstream.git ls-tree -rz --name-only "refs/heads/$upstream_ref")
  ((${#paths[@]}))
  git -C upstream.git archive "refs/heads/$upstream_ref" -- "${paths[@]}" | tar -xf - -C snapshot
  jq -n --arg distribution "$DISTRO" --arg upstream "$selected_upstream" --arg ref "$upstream_ref" --arg revision "$oid" \
    '{schema:1,distribution:$distribution,upstream:$upstream,ref:$ref,revision:$revision}' > snapshot/.container-source.json
  cp releases.json snapshot/.container-releases.json
  git -C snapshot init --quiet --initial-branch=main
  git -C snapshot add --all
  tree=$(git -C snapshot write-tree)
  export GIT_AUTHOR_DATE="$stamp" GIT_COMMITTER_DATE="$stamp"
  commit=$(git -C snapshot commit-tree "$tree" -m "Sync $DISTRO container production code from $oid")
  previous=$(awk -v ref="refs/heads/$branch" '$2==ref {print $1}' previous-refs)
  if [[ "$commit" != "$previous" ]]; then
    git -C snapshot push --force-with-lease="refs/heads/$branch:$previous" "$target" "$commit:refs/heads/$branch"
  fi
done < ordered-refs
gh api -X PATCH "repos/$org/$DISTRO" -f default_branch=main --silent
deletions=()
leases=()
prune_batch() {
  ((${#deletions[@]})) || return 0
  git -C snapshot push "${leases[@]}" "$target" "${deletions[@]}"
  deletions=()
  leases=()
}
while read -r oid ref; do
  if [[ "$ref" == refs/tags/* ]] || ! awk -v branch="${ref#refs/heads/}" '$2==branch {found=1} END {exit !found}' selected-refs; then
    leases+=("--force-with-lease=$ref:$oid")
    deletions+=(":$ref")
    if ((${#deletions[@]} == 100)); then prune_batch; fi
  fi
done < previous-refs
prune_batch