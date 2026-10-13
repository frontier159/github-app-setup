#!/bin/bash
# Checks the GitHub side of step 01 with the App's own key. Changes nothing. Bash 3.2 compatible.
#
#   ./check-github.sh --app-id <id> [--repo <owner/repo>]...
#
# --repo checks that repo's rulesets against the recipe in 01-github.md. Repeat it per repo.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
HELPER="$HERE/files/git-credential-agent"
KEY="$HOME/.config/agent-git/app.pem"
GITHUB_ACTIONS_APP_ID=15368
# What step 01 grants. Anything else on an installation is reported.
EXPECTED='{"actions":"read","checks":"read","contents":"write","issues":"write","metadata":"read","pull_requests":"write"}'

usage() { sed -n '4p' "$0" | sed 's/^# *//' >&2; exit 2; }
fails=0 warns=0
ok()   { printf '  ok %s\n' "$*"; }
warn() { printf '  - %s\n' "$*"; warns=$((warns + 1)); }
fail() { printf '  x %s\n' "$*"; fails=$((fails + 1)); }

app_id="" repos=""
while [ $# -gt 0 ]; do
  case $1 in
    --app-id) app_id=${2:-}; shift 2 ;;
    --repo) case ${2:-} in */*) repos="$repos ${2}" ;; *) usage ;; esac; shift 2 ;;
    *) usage ;;
  esac
done
case $app_id in ''|*[!0-9]*) echo "check-github: --app-id must be the numeric App ID" >&2; usage ;; esac
JQ=/usr/bin/jq; [ -x "$JQ" ] || JQ=$(command -v jq) || { echo "check-github: jq not found" >&2; exit 1; }
command -v gh >/dev/null || { echo "check-github: gh not found" >&2; exit 1; }

echo "Private key"
if [ -f "$KEY" ]; then
  perms=$(stat -f '%Lp' "$KEY")
  [ "$perms" = 600 ] && ok "$KEY, mode 600" || fail "$KEY has mode $perms; run: chmod 600 $KEY"
  head -c 31 "$KEY" | grep -q 'BEGIN RSA PRIVATE KEY' && ok "GitHub's PEM format" || warn "not GitHub's usual PEM header; check it is the App key"
else
  fail "not found at $KEY; see 01-github.md, Private key"
  echo "Stopped." >&2; exit 1
fi

echo "Installations"
installs=$("$HELPER" --app-id "$app_id" installations-json 2>&1) || { fail "$installs"; exit 1; }
count=$(printf '%s' "$installs" | "$JQ" length)
[ "$count" -gt 0 ] && ok "$count installation(s)" || { fail "the App has no installations; install it on each owner"; exit 1; }

# A token per owner, kept in a variable and never printed.
token_for() {
  printf 'protocol=https\nhost=github.com\npath=%s/_.git\n\n' "$1" \
    | "$HELPER" --app-id "$app_id" --installation-id "$2" get 2>/dev/null | sed -n 's/^password=//p'
}
api() { local t=$1; shift; GH_TOKEN=$t GH_CONFIG_DIR="$tmpdir" gh api "$@" 2>&1; }
tmpdir=$(mktemp -d); trap 'rm -rf "$tmpdir"' EXIT

lines=$(printf '%s' "$installs" | "$JQ" -r '.[] | "\(.account.login) \(.id) \(.repository_selection)"')
while read -r owner id selection; do
  echo "$owner (installation $id)"
  [ "$selection" = selected ] && ok "only selected repositories" \
    || warn "all repositories selected; choose only the repos the agent works on"
  extra=$(printf '%s' "$installs" | "$JQ" -r --arg id "$id" --argjson want "$EXPECTED" \
    '.[] | select((.id|tostring) == $id) | .permissions | to_entries[] | select($want[.key] != .value) | "\(.key)=\(.value)"')
  if [ -z "$extra" ]; then ok "permissions match step 01"
  else for e in $extra; do fail "permission $e is not in step 01; remove it in the App's Permissions & events"; done; fi
  token=$(token_for "$owner" "$id")
  if [ -z "$token" ]; then fail "no token minted"; continue; fi
  ok "token minted"
  first=$(api "$token" "/installation/repositories?per_page=1" --jq '.repositories[0].full_name' || true)
  if [ -n "$first" ]; then
    code=$(api "$token" "repos/$first/hooks" | grep -o 'HTTP [0-9]*' | head -1 || true)
    [ "$code" = "HTTP 403" ] && ok "admin-only call refused (403 on $first)" || fail "admin-only call on $first gave '${code:-success}'"
  fi
  unset token
done <<< "$lines"

for repo in $repos; do
  owner=${repo%%/*}
  echo "Rulesets on $repo"
  id=$(printf '%s' "$installs" | "$JQ" -r --arg o "$owner" '.[] | select(.account.login == $o) | .id')
  [ -n "$id" ] || { fail "the App is not installed on $owner"; continue; }
  token=$(token_for "$owner" "$id")
  branch=$(api "$token" "repos/$repo" --jq .default_branch) || { fail "cannot read $repo: $branch"; continue; }
  rules=$(api "$token" "repos/$repo/rules/branches/$branch")
  pr=$(printf '%s' "$rules" | "$JQ" -c '[.[] | select(.type == "pull_request") | .parameters] | first // empty')
  if [ -z "$pr" ]; then fail "$branch: no pull request required"
  else
    [ "$(printf '%s' "$pr" | "$JQ" '.required_approving_review_count')" -ge 1 ] && ok "$branch: at least one approval" || fail "$branch: no approvals required"
    [ "$(printf '%s' "$pr" | "$JQ" '.require_last_push_approval')" = true ] && ok "$branch: approval of the most recent push" \
      || fail "$branch: an approval given before the last push still counts; tick 'require approval of the most recent reviewable push'"
    [ "$(printf '%s' "$pr" | "$JQ" '.dismiss_stale_reviews_on_push')" = true ] && ok "$branch: stale approvals dismissed" || warn "$branch: stale approvals are not dismissed on push"
    [ "$(printf '%s' "$pr" | "$JQ" '.require_code_owner_review')" = true ] && ok "$branch: Code Owner review" || warn "$branch: no Code Owner review"
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
