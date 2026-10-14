#!/bin/bash
# Checks each repo's branch and tag rules against 01-github.md, using the agent's
# stored token for that repo's owner. Changes nothing. Bash 3.2 compatible.
#
#   ./check-github.sh --repo <owner/repo> [--repo <owner/repo>]...
set -euo pipefail

TOKENS="$HOME/.config/agent-git/tokens"
GITHUB_ACTIONS_APP_ID=15368

usage() { sed -n '5p' "$0" | sed 's/^# *//' >&2; exit 2; }
fails=0 warns=0
ok()   { printf '  ok %s\n' "$*"; }
warn() { printf '  - %s\n' "$*"; warns=$((warns + 1)); }
fail() { printf '  x %s\n' "$*"; fails=$((fails + 1)); }

repos=""
while [ $# -gt 0 ]; do
  case $1 in
    --repo) case ${2:-} in ?*/?*) repos="$repos ${2}" ;; *) usage ;; esac; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$repos" ] || usage
JQ=/usr/bin/jq; [ -x "$JQ" ] || JQ=$(command -v jq) || { echo "check-github: jq not found" >&2; exit 1; }
command -v gh >/dev/null || { echo "check-github: gh not found" >&2; exit 1; }

tmpdir=$(mktemp -d); trap 'rm -rf "$tmpdir"' EXIT
api() { local t=$1; shift; GH_TOKEN=$t GH_CONFIG_DIR="$tmpdir" command gh api "$@" 2>&1; }

for repo in $repos; do
  owner=${repo%%/*}
  echo "Rulesets on $repo"
  [ -s "$TOKENS/$owner" ] || { fail "no agent token for $owner in ${TOKENS/#$HOME/~}; run install.sh"; continue; }
  token=$(cat "$TOKENS/$owner")
  branch=$(api "$token" "repos/$repo" --jq .default_branch) || { fail "cannot read $repo: $branch"; continue; }
  rules=$(api "$token" "repos/$repo/rules/branches/$branch")
  pr=$(printf '%s' "$rules" | "$JQ" -c '[.[] | select(.type == "pull_request") | .parameters] | first // empty')
  if [ -z "$pr" ]; then fail "$branch: no pull request required"
  else
    [ "$(printf '%s' "$pr" | "$JQ" '.required_approving_review_count')" -ge 1 ] && ok "$branch: at least one approval" || fail "$branch: no approvals required"
    [ "$(printf '%s' "$pr" | "$JQ" '.require_last_push_approval')" = true ] && ok "$branch: approval of the most recent push" \
      || fail "$branch: an approval given before the last push still counts; tick 'require approval of the most recent reviewable push'"
    [ "$(printf '%s' "$pr" | "$JQ" '.dismiss_stale_reviews_on_push')" = true ] && ok "$branch: stale approvals dismissed" || warn "$branch: stale approvals are not dismissed on push"
  fi
  checks=$(printf '%s' "$rules" | "$JQ" -r '[.[] | select(.type == "required_status_checks") | .parameters.required_status_checks[]] | .[] | "\(.context) \(.integration_id // "any")"')
  if [ -z "$checks" ]; then warn "$branch: no required status checks"
  else
    while read -r context source; do
      [ "$source" = "$GITHUB_ACTIONS_APP_ID" ] && ok "$branch: check '$context' must come from GitHub Actions" \
        || fail "$branch: check '$context' accepts any source; set its source to GitHub Actions"
    done <<< "$checks"
  fi
  for r in deletion non_fast_forward; do
    printf '%s' "$rules" | "$JQ" -e --arg r "$r" 'any(.[]; .type == $r)' >/dev/null && ok "$branch: $r blocked" || fail "$branch: $r not blocked"
  done
  tag_creation=$(api "$token" "repos/$repo/rulesets" --jq '.[] | select(.target == "tag" and .enforcement == "active") | .id' | while read -r rid; do
      api "$token" "repos/$repo/rulesets/$rid" --jq 'select(any(.rules[]; .type == "creation")) | .name'
    done)
  [ -n "$tag_creation" ] && ok "tag creation restricted by: $(echo $tag_creation)" \
    || fail "no active tag ruleset restricts creation; the agent can create release tags"
  unset token
done

echo
if [ $fails -gt 0 ]; then echo "$fails problem(s), $warns warning(s)."; exit 1; fi
echo "No problems, $warns warning(s)."
