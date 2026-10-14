#!/usr/bin/env bash
# Sets up step 02: agent shells use a restricted fine-grained PAT per owner for git and gh.
# Bash 3.2 compatible (macOS /bin/bash). Rerunning is safe.
#
#   ./install.sh --owner <owner> [--owner <owner>]... --default-owner <owner>   plan, confirm, install, verify
#   ./install.sh --check                                                       verify only, change nothing
set -euo pipefail

AG="$HOME/.config/agent-git"
AH="$HOME/.config/agent-gh"
TOKENS="$AG/tokens"
HELPER="$AG/bin/git-credential-agent"
HERE=$(cd "$(dirname "$0")" && pwd)
SOURCE_LINE='if [ -n "${CLAUDECODE:-}" ] && [ -r "$HOME/.config/agent-git/env.sh" ]; then . "$HOME/.config/agent-git/env.sh"; fi'
# v0.1.0 wrote this form. It returns 1 when CLAUDECODE is unset, so the rewrite removes it.
OLD_SOURCE_LINE='[ -n "$CLAUDECODE" ] && [ -r "$HOME/.config/agent-git/env.sh" ] && . "$HOME/.config/agent-git/env.sh"'
PROFILE_LINE='[ -r "$HOME/.profile" ] && . "$HOME/.profile"'

usage() { sed -n '5,6p' "$0" | sed 's/^# *//' >&2; exit 2; }
problems=0
problem() { printf '  x %s\n' "$*" >&2; problems=$((problems + 1)); }
ok() { printf '  ok %s\n' "$*"; }
note() { printf '  - %s\n' "$*"; }
t() { printf '%s' "${1/#$HOME/~}"; }   # show a path relative to ~
is_login() { case $1 in ''|-*|*-|*[!A-Za-z0-9-]*) return 1 ;; esac; }

mode=install owners="" default_owner=""
while [ $# -gt 0 ]; do
  case $1 in
    --owner) is_login "${2:-}" || { echo "install: --owner must be a GitHub login" >&2; usage; }; owners="$owners $2"; shift 2 ;;
    --default-owner) is_login "${2:-}" || { echo "install: --default-owner must be a GitHub login" >&2; usage; }; default_owner=$2; shift 2 ;;
    --check) mode=check; shift ;;
    *) usage ;;
  esac
done
if [ $mode = install ]; then
  [ -n "$owners" ] || { echo "install: give at least one --owner" >&2; usage; }
  is_login "$default_owner" || { echo "install: --default-owner must be a GitHub login" >&2; usage; }
  case " $owners " in *" $default_owner "*) ;; *) echo "install: --default-owner must be one of the --owner values" >&2; usage ;; esac
else
  owners=$(ls "$TOKENS" 2>/dev/null | tr '\n' ' ' || true)
fi

# The startup files the agent's login shell reads.
startup_files() {
  case $(basename "${SHELL:-}") in
    zsh) echo "$HOME/.zshenv $HOME/.zprofile" ;;
    bash) echo "$HOME/.bash_profile $HOME/.bashrc" ;;
  esac
}
last_line() { [ -f "$1" ] && grep -av '^[[:space:]]*$' "$1" | tail -1 || true; }
# Login bash stops reading ~/.profile once ~/.bash_profile exists.
new_bash_profile() { [ "$1" = "$HOME/.bash_profile" ] && [ ! -e "$1" ] && [ -f "$HOME/.profile" ]; }

# ---- preflight -------------------------------------------------------------
echo "Preflight"
[ "$(uname -s)" = Darwin ] && ok "macOS" || problem "macOS only for now; see the README's On Linux section"
case $(basename "${SHELL:-}") in
  zsh|bash) ok "login shell $(basename "$SHELL")" ;;
  *) problem "login shell is '${SHELL:-unset}'; only zsh and bash are supported" ;;
esac
if command -v git >/dev/null; then
  v=$(git --version | awk '{print $3}'); major=${v%%.*}; rest=${v#*.}; minor=${rest%%.*}
  if [ "$major" -gt 2 ] || { [ "$major" -eq 2 ] && [ "$minor" -ge 32 ]; }; then ok "git $v"
  else problem "git $v is too old; GIT_CONFIG_GLOBAL needs git 2.32 or newer"; fi
else problem "git not found on PATH"; fi
command -v gh >/dev/null && ok "gh at $(command -v gh)" || problem "gh not found on PATH; the shim wraps it"
for f in gh git-credential-agent; do
  [ -x "$HERE/files/$f" ] || problem "$HERE/files/$f missing or not executable; run from a full checkout"
done
# The agent gitconfig includes both of these, in git's own order.
for f in "$HOME/.config/git/config" "$HOME/.gitconfig"; do
  [ -f "$f" ] || continue
  reverse=$(git config --file "$f" --includes --get-regexp '^url\..*insteadof$' 2>/dev/null \
            | grep -E '^url\.(git@github\.com:|ssh://git@github\.com)[^ ]*\.(push)?insteadof +https://github\.com' || true)
  [ -z "$reverse" ] && ok "no HTTPS-to-SSH rewrite in $(t "$f")" \
    || problem "$(t "$f") rewrites GitHub HTTPS to SSH; remove it, the agent config cannot cancel it: $reverse"
done
if [ $mode = install ]; then
  for o in $owners; do
    [ -s "$TOKENS/$o" ] && continue
    ( : </dev/tty ) 2>/dev/null || problem "no token stored for $o, and no terminal to paste one into; run the installer in a terminal"
  done
fi
if [ $problems -gt 0 ]; then echo "Stopped: $problems problem(s) above. Nothing was changed." >&2; exit 1; fi

# ---- token checks (install and --check) ------------------------------------
# A fine-grained PAT, valid, not near expiry, able to see the owner's repos, refused admin.
check_token() {
  local owner=$1 f="$TOKENS/$1" token cfg headers login expiry expires days repo code out
  [ -s "$f" ] || { problem "$owner: no token at $(t "$f")"; return 1; }
  [ "$(/usr/bin/stat -f '%Lp' "$f")" = 600 ] || { problem "$owner: $(t "$f") must be mode 600"; return 1; }
  token=$(cat "$f")
  case $token in
    github_pat_*) ;;
    *) problem "$owner: not a fine-grained PAT; classic and OAuth tokens reach every repo and can administer them"; return 1 ;;
  esac
  cfg=$(mktemp -d)
  headers=$(GH_TOKEN=$token GH_CONFIG_DIR=$cfg command gh api -i user 2>"$cfg/err") || {
    problem "$owner: gh api user failed: $(head -1 "$cfg/err"); the token may be expired or revoked"; rm -rf "$cfg"; return 1; }
  login=$(printf '%s\n' "$headers" | grep -o '"login": *"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
  expiry=$(printf '%s\n' "$headers" | tr -d '\r' | sed -n 's/^[Gg]ithub-[Aa]uthentication-[Tt]oken-[Ee]xpiration: //p' | head -1)
  if [ -n "$expiry" ]; then
    if expires=$(date -j -u -f '%Y-%m-%d %H:%M:%S' "${expiry% UTC}" +%s 2>/dev/null); then
      days=$(( (expires - $(date +%s)) / 86400 ))
      [ "$days" -ge 14 ] && ok "$owner: token works as $login, expires in $days days" \
        || note "$owner: token works as $login but expires in $days days; replace it soon"
    else
      ok "$owner: token works as $login, expires $expiry"
    fi
  else
    ok "$owner: token works as $login, no expiry"
  fi
  repo=$(GH_TOKEN=$token GH_CONFIG_DIR=$cfg command gh api '/user/repos?per_page=100' --paginate \
    --jq ".[] | select(.owner.login | ascii_downcase == \"$(printf '%s' "$owner" | tr 'A-Z' 'a-z')\") | .full_name" 2>/dev/null | head -1 || true)
  if [ -z "$repo" ]; then
    note "$owner: the token sees none of $owner's repos; check its resource owner and repository access"
  else
    # Deploy keys need Administration read; the token must have none. Only this message
    # blames the token; another 403, such as "Must have admin rights", blames your role.
    out=$(GH_TOKEN=$token GH_CONFIG_DIR=$cfg command gh api "repos/$repo/keys" 2>&1 >/dev/null || true)
    code=$(printf '%s\n' "$out" | grep -o 'HTTP [0-9]*' | head -1 || true)
    if printf '%s\n' "$out" | grep -q 'Resource not accessible by personal access token'; then
      ok "$owner: admin-only call refused (403 on $repo)"
    elif [ "$code" = "HTTP 403" ]; then
      note "$owner: the admin probe on $repo was inconclusive (a 403 for another reason); check the token has Administration set to No access"
    else
      problem "$owner: admin-only call on $repo gave '${code:-success}'; set Administration to No access"
    fi
  fi
  rm -rf "$cfg"
}

verify() {
  echo "Verify"
  local f o before=$problems
  [ -x "$AH/bin/gh" ] && [ -x "$HELPER" ] && [ -f "$AG/gitconfig" ] && [ -f "$AG/env.sh" ] && ok "agent files installed" \
    || problem "agent files missing; run install"
  for f in $(startup_files); do
    [ "$(last_line "$f")" = "$SOURCE_LINE" ] && ok "$(basename "$f") ends with the source line" \
      || problem "$(basename "$f") does not end with the source line; rerun install"
  done
  [ -n "${owners// /}" ] || problem "no tokens stored in $(t "$TOKENS")"
  for o in $owners; do check_token "$o" || true; done
  echo "Steps 03 and 04 (advisory)"
  ls "$HOME"/.ssh/id_* 2>/dev/null | grep -v '\.pub$' >/dev/null \
    && note "a private key file is still in ~/.ssh; step 03 moves it into a password manager" \
    || ok "no private key files in ~/.ssh"
  [ "$(/usr/bin/plutil -extract sandbox.enabled raw -o - "$HOME/.claude/settings.json" 2>/dev/null)" = true ] \
    && ok "Claude Code sandbox enabled" || note "Claude Code sandbox is off; see step 04"
  [ $problems -eq $before ]
}

if [ $mode = check ]; then verify && exit 0 || exit 1; fi

# ---- plan and confirm ------------------------------------------------------
state() { [ -e "$1" ] && echo "overwrite" || echo "create"; }
backup() { [ -e "$1.agent-bak" ] && echo "keeps the first backup, $(t "$1").agent-bak" || echo "backup $(t "$1").agent-bak"; }
echo
echo "Plan"
for o in $owners; do
  [ -s "$TOKENS/$o" ] && echo "  keep    $(t "$TOKENS/$o")   (stored token)" \
                      || echo "  create  $(t "$TOKENS/$o")   (you paste $o's PAT next, hidden)"
done
echo "  $(state "$HELPER")  $(t "$HELPER")   (from files/git-credential-agent)"
echo "  $(state "$AG/gitconfig")  $(t "$AG/gitconfig")"
echo "  $(state "$AG/env.sh")  $(t "$AG/env.sh")   (default owner $default_owner)"
echo "  $(state "$AH/bin/gh")  $(t "$AH/bin/gh")   (from files/gh)"
for f in $(startup_files); do
  if [ "$(last_line "$f")" = "$SOURCE_LINE" ]; then echo "  keep    $(t "$f")   (already ends with the source line)"
  elif new_bash_profile "$f"; then echo "  create  $(t "$f")   (sources ~/.profile, then the source line)"
  elif [ ! -f "$f" ]; then echo "  create  $(t "$f")   (the source line only)"
  elif grep -aqxF "$OLD_SOURCE_LINE" "$f"; then echo "  replace the old source line in $(t "$f"), at the end   ($(backup "$f"))"
  elif grep -aqxF "$SOURCE_LINE" "$f"; then echo "  move    the source line to the end of $(t "$f")   ($(backup "$f"))"
  else echo "  append  the source line to $(t "$f")   ($(backup "$f"))"; fi
done
echo "  source line: $SOURCE_LINE"
echo "Nothing else changes. Your ~/.gitconfig, ~/.ssh and own gh login are not touched."
printf 'Proceed? [y/N] '
read -r answer || answer=""
case $answer in y|Y|yes) ;; *) echo "Cancelled. Nothing was changed."; exit 1 ;; esac

# ---- install ---------------------------------------------------------------
umask 077
trap 'stty echo </dev/tty 2>/dev/null || true' EXIT
mkdir -p "$AG/bin" "$AH/bin" "$TOKENS"; chmod 700 "$AG" "$TOKENS"
for o in $owners; do
  [ -s "$TOKENS/$o" ] && continue
  while :; do
    # Echo goes off before the prompt appears, so nothing pasted early is shown.
    stty -echo </dev/tty
    printf "Paste the agent's PAT for %s (input hidden): " "$o"
    read -r token </dev/tty || token=""
    stty echo </dev/tty; echo
    case $token in *[[:space:]]*) ;; github_pat_?*) break ;; esac
    echo "  That is not a fine-grained PAT (github_pat_…). Try again." >&2
  done
  printf '%s' "$token" > "$TOKENS/$o"; chmod 600 "$TOKENS/$o"; unset token
done
install -m 755 "$HERE/files/git-credential-agent" "$HELPER"

cat > "$AG/gitconfig" <<CFG
# Generated by install.sh; rerun it instead of editing. Read only inside agent shells.
[include]
    path = ~/.config/git/config
    path = ~/.gitconfig
[credential]
    helper =
    helper = $HELPER
    useHttpPath = true
[core]
    askPass =
[url "https://github.com/"]
    insteadOf = git@github.com:
    insteadOf = ssh://git@github.com/
CFG
chmod 600 "$AG/gitconfig"

cat > "$AG/env.sh" <<ENV
# Generated by install.sh. Sourced in agent shells only; POSIX so zsh and bash both read it.
export GIT_CONFIG_GLOBAL="\$HOME/.config/agent-git/gitconfig"
export GH_CONFIG_DIR="\$HOME/.config/agent-gh"
export AGENT_GH_DEFAULT_OWNER=$default_owner
export PATH="\$HOME/.config/agent-gh/bin:\$PATH"
# Inherited tokens would skip the shim's routing; askpass and prompts would let git
# fall back to another credential.
unset GH_TOKEN GITHUB_TOKEN GIT_ASKPASS SSH_ASKPASS
export GIT_TERMINAL_PROMPT=0
# Claude Code resets PATH from its shell snapshot after startup files run;
# a function survives that, so plain gh still reaches the shim.
gh() { "\$HOME/.config/agent-gh/bin/gh" "\$@"; }
unset SSH_AUTH_SOCK
ENV
chmod 600 "$AG/env.sh"
install -m 755 "$HERE/files/gh" "$AH/bin/gh"

for f in $(startup_files); do
  [ "$(last_line "$f")" = "$SOURCE_LINE" ] && continue
  tmp=$(mktemp)
  if [ -f "$f" ]; then
    [ -e "$f.agent-bak" ] || cp -p "$f" "$f.agent-bak"
    grep -avxF -e "$SOURCE_LINE" -e "$OLD_SOURCE_LINE" "$f" > "$tmp" || true
  elif new_bash_profile "$f"; then
    printf '%s\n' "$PROFILE_LINE" > "$tmp"
  fi
  printf '%s\n' "$SOURCE_LINE" >> "$tmp"
  cat "$tmp" > "$f"; rm -f "$tmp"
done

echo "Installed."
verify && echo "Done. Open a new agent session to pick it up." || exit 1
