#!/bin/bash
# Checks each repo's branch and tag rules against 01-github.md, using the agent's
# stored token for that repo's owner. Changes nothing. Bash 3.2 compatible.
#
#   ./check-github.sh [--solo] --repo <owner/repo> [--repo <owner/repo>]...
#
# --solo skips the pull request checks on every repo given, for repos only you work on.
set -euo pipefail

TOKENS="$HOME/.config/agent-git/tokens"
GITHUB_ACTIONS_APP_ID=15368

usage() { sed -n '5p' "$0" | sed 's/^# *//' >&2; exit 2; }
fails=0 warns=0
ok()   { printf '  ok %s\n' "$*"; }
warn() { printf '  - %s\n' "$*"; warns=$((warns + 1)); }
fail() { printf '  x %s\n' "$*"; fails=$((fails + 1)); }

repos="" solo=""
while [ $# -gt 0 ]; do
  case $1 in
    --solo) solo=1; shift ;;
    --repo) case ${2:-} in ?*/?*) repos="$repos ${2}" ;; *) usage ;; esac; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$repos" ] || usage
JQ=/usr/bin/jq; [ -x "$JQ" ] || JQ=$(command -v jq) || { echo "check-github: jq not found" >&2; exit 1; }
command -v gh >/dev/null || { echo "check-github: gh not found" >&2; exit 1; }

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/check-github.XXXXXX"); trap 'rm -rf "$tmpdir"' EXIT
# stderr goes to a file, so an error message never reads as data.
api() { local t=$1; shift; GH_TOKEN=$t GH_CONFIG_DIR="$tmpdir" command gh api "$@" 2>"$tmpdir/err"; }
api_error() { tr '\n' ' ' < "$tmpdir/err"; }

for repo in $repos; do
  owner=${repo%%/*}
  echo "Rulesets on $repo"
  [ -s "$TOKENS/$owner" ] || { fail "no agent token for $owner in ${TOKENS/#$HOME/~}; run install.sh"; continue; }
  token=$(cat "$TOKENS/$owner")
  branch=$(api "$token" "repos/$repo" --jq .default_branch) || { fail "cannot read $repo: $(api_error)"; continue; }
  rules=$(api "$token" "repos/$repo/rules/branches/$branch" --paginate --slurp) || { fail "cannot read the rules on $branch: $(api_error)"; continue; }
  rules=$(printf '%s' "$rules" | "$JQ" -c 'add // []')
  # Several rulesets can each add a pull_request rule; GitHub enforces the strictest.
  pr=$(printf '%s' "$rules" | "$JQ" -c '[.[] | select(.type == "pull_request") | .parameters]
    | if length == 0 then empty else {
        required_approving_review_count: (map(.required_approving_review_count // 0) | max),
        require_last_push_approval: any(.[]; .require_last_push_approval == true),
        dismiss_stale_reviews_on_push: any(.[]; .dismiss_stale_reviews_on_push == true) } end')
  if [ -n "$solo" ]; then warn "$branch: pull request checks skipped (--solo)"
  elif [ -z "$pr" ]; then fail "$branch: no pull request required"
  else
    [ "$(printf '%s' "$pr" | "$JQ" '.required_approving_review_count')" -ge 1 ] && ok "$branch: at least one approval" || fail "$branch: no approvals required"
    [ "$(printf '%s' "$pr" | "$JQ" '.require_last_push_approval')" = true ] && ok "$branch: approval of the most recent push" \
      || fail "$branch: an approval given before the last push still counts; tick 'require approval of the most recent reviewable push'"
    [ "$(printf '%s' "$pr" | "$JQ" '.dismiss_stale_reviews_on_push')" = true ] && ok "$branch: stale approvals dismissed" || warn "$branch: stale approvals are not dismissed on push"
  fi
  # Rulesets stack, so a context is held to GitHub Actions when any rule requires that source.
  checks=$(printf '%s' "$rules" | "$JQ" -r --argjson app "$GITHUB_ACTIONS_APP_ID" '[.[] | select(.type == "required_status_checks") | .parameters.required_status_checks[]]
    | group_by(.context)[] | "\(any(.[]; .integration_id == $app)) \(.[0].context)"')
  if [ -z "$checks" ]; then warn "$branch: no required status checks"
  else
    while read -r actions context; do
      [ "$actions" = true ] && ok "$branch: check '$context' must come from GitHub Actions" \
        || fail "$branch: check '$context' accepts any source; set its source to GitHub Actions"
    done <<< "$checks"
  fi
  for r in deletion non_fast_forward; do
    printf '%s' "$rules" | "$JQ" -e --arg r "$r" 'any(.[]; .type == $r)' >/dev/null && ok "$branch: $r blocked" || fail "$branch: $r not blocked"
  done
  ids=$(api "$token" "repos/$repo/rulesets" --paginate --jq '.[] | select(.target == "tag" and .enforcement == "active") | .id') \
    || { fail "cannot list the rulesets on $repo: $(api_error)"; continue; }
  tag_rules=""
  for rid in $ids; do
    if out=$(api "$token" "repos/$repo/rulesets/$rid" --jq '"\(.name) (\(.conditions.ref_name.include // [] | join(" ")))" as $n | .rules[] | "\(.type) \($n)"'); then
      tag_rules="$tag_rules$out
"
    else fail "cannot read tag ruleset $rid: $(api_error)"; fi
  done
  for r in creation update deletion; do
    by=$(printf '%s' "$tag_rules" | sed -n "s/^$r //p" | sort -u | paste -sd, -)
    [ -n "$by" ] && ok "tag $r restricted by: $by" \
      || fail "no active tag ruleset restricts tag $r; the agent can change release tags"
  done
  unset token
done

echo
if [ $fails -gt 0 ]; then echo "$fails problem(s), $warns warning(s)."; exit 1; fi
echo "No problems, $warns warning(s)."
