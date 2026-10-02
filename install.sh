#!/usr/bin/env bash
# Sets up step 02: the agent's own git and gh identity through a GitHub App.
# Bash 3.2 compatible (macOS /bin/bash). Rerunning is safe.
#
#   ./install.sh --app-id <id> --default-owner <owner>   show the plan, confirm, install, verify
#   ./install.sh --check                                 verify only, change nothing
set -euo pipefail

AG="$HOME/.config/agent-git"
AH="$HOME/.config/agent-gh"
HELPER="$AG/bin/git-credential-github-app"
KEY="$AG/app.pem"
HERE=$(cd "$(dirname "$0")" && pwd)
SOURCE_LINE='[ -n "$CLAUDECODE" ] && [ -r "$HOME/.config/agent-git/env.sh" ] && . "$HOME/.config/agent-git/env.sh"'

usage() { sed -n '5,6p' "$0" | sed 's/^# *//' >&2; exit 2; }
problems=0
problem() { printf '  x %s\n' "$*" >&2; problems=$((problems + 1)); }
ok() { printf '  ok %s\n' "$*"; }
t() { printf '%s' "${1/#$HOME/~}"; }   # show a path relative to ~

mode=install app_id="" default_owner=""
while [ $# -gt 0 ]; do
  case $1 in
    --app-id) app_id=${2:-}; shift 2 ;;
    --default-owner) default_owner=${2:-}; shift 2 ;;
    --check) mode=check; shift ;;
    *) usage ;;
  esac
done
if [ $mode = install ]; then
  case $app_id in ''|*[!0-9]*) echo "install: --app-id must be the numeric App ID from step 01" >&2; usage ;; esac
  [ -n "$default_owner" ] || { echo "install: --default-owner is required" >&2; usage; }
fi

# The startup files the agent's login shell reads, last line first.
startup_files() {
  case $(basename "${SHELL:-}") in
    zsh) echo "$HOME/.zshenv $HOME/.zprofile" ;;
    bash) echo "$HOME/.bash_profile $HOME/.bashrc" ;;
  esac
}

last_line() { [ -f "$1" ] && grep -v '^[[:space:]]*$' "$1" | tail -1 || true; }

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
[ -x "$HERE/files/gh" ] || problem "$HERE/files/gh missing or not executable; run from a full checkout"

helper_src=""
if [ -x "$HELPER" ]; then ok "credential helper at $(t "$HELPER")"
elif command -v git-credential-github-app >/dev/null; then
  helper_src=$(command -v git-credential-github-app); ok "credential helper at $(t "$helper_src") (will be copied)"
else
  problem "git-credential-github-app not found. Install it, then rerun:
      go install github.com/bdellegrazie/git-credential-github-app@latest
    or download a release from github.com/bdellegrazie/git-credential-github-app/releases"
fi

if [ -f "$KEY" ]; then
  perms=$(stat -f '%Lp' "$KEY")
  [ "$perms" = 600 ] && ok "App private key at $(t "$KEY")" || problem "$(t "$KEY") has mode $perms; run: chmod 600 $(t "$KEY")"
else problem "App private key not found at $(t "$KEY"); see step 01, Private key"; fi

if [ -f "$HOME/.gitconfig" ]; then
  reverse=$(git config --file "$HOME/.gitconfig" --includes --get-regexp '^url\..*\.insteadof$' 2>/dev/null \
            | grep -E '^url\.(git@github\.com:|ssh://git@github\.com/?)\.insteadof +https://github\.com' || true)
  [ -z "$reverse" ] && ok "no HTTPS-to-SSH rewrite in ~/.gitconfig" \
    || problem "~/.gitconfig rewrites GitHub HTTPS to SSH; remove it, the agent config cannot cancel it: $reverse"
fi

# ---- installations ---------------------------------------------------------
# owners holds "owner installation_id" lines.
owners=""
if [ $mode = install ] && [ $problems -eq 0 ]; then
  bin=${helper_src:-$HELPER}
  generated=$("$bin" -username x-access-token -appId "$app_id" -privateKeyFile "$KEY" generate 2>&1) \
    || problem "listing the App's installations failed: $generated"
  if [ $problems -eq 0 ]; then
    tmp=$(mktemp); printf '%s\n' "$generated" > "$tmp"
    owners=$(git config --file "$tmp" --get-regexp '^credential\.https://github\.com/[^.]*\.helper$' \
      | sed -n 's#^credential\.https://github\.com/\([^ ]*\)\.helper .*-installationId \([0-9][0-9]*\).*#\1 \2#p')
    rm -f "$tmp"
    [ -n "$owners" ] || problem "the App has no installations; install it on each owner (step 01)"
    printf '%s\n' "$owners" | awk '{print $1}' | grep -qxF "$default_owner" \
      || problem "--default-owner '$default_owner' is not one of the App's installations: $(printf '%s ' $(printf '%s\n' "$owners" | awk '{print $1}'))"
  fi
elif [ $mode = check ] && [ -f "$AG/gitconfig" ]; then
  owners=$(git config --file "$AG/gitconfig" --get-regexp '^credential\.https://github\.com/[^.]*\.helper$' \
    | sed -n 's#^credential\.https://github\.com/\([^ ]*\)\.helper .*-installationId \([0-9][0-9]*\).*#\1 \2#p')
fi

if [ $problems -gt 0 ]; then echo "Stopped: $problems problem(s) above. Nothing was changed." >&2; exit 1; fi

# ---- verification (also run after install) ---------------------------------
verify() {
  echo "Verify"
  local fails=0 f owner id token count
  [ -x "$AH/bin/gh" ] && [ -f "$AG/gitconfig" ] && [ -f "$AG/env.sh" ] && ok "agent files installed" \
    || { problem "agent files missing; run install"; fails=1; }
  for f in $(startup_files); do
    [ "$(last_line "$f")" = "$SOURCE_LINE" ] && ok "$(basename "$f") ends with the source line" \
      || { problem "$(basename "$f") does not end with the source line; rerun install"; fails=1; }
  done
  while read -r owner id; do
    [ -n "$owner" ] || continue
    token=$(printf 'protocol=https\nhost=github.com\npath=%s/_.git\n\n' "$owner" \
      | GIT_CONFIG_GLOBAL="$AG/gitconfig" GIT_TERMINAL_PROMPT=0 git credential fill 2>/dev/null | sed -n 's/^password=//p')
    if [ -z "$token" ]; then problem "$owner: no token minted (installation $id)"; fails=1; continue; fi
    count=$(GH_TOKEN="$token" GH_CONFIG_DIR="$AH" command gh api /installation/repositories --jq .total_count 2>/dev/null) \
      && ok "$owner: App token works, $count repo(s) selected" \
      || { problem "$owner: token minted but the API call failed"; fails=1; }
  done <<< "$owners"
  [ -z "$owners" ] && { problem "no owners configured"; fails=1; }
  echo "Steps 03 and 04 (advisory)"
  ls "$HOME"/.ssh/id_* 2>/dev/null | grep -v '\.pub$' >/dev/null \
    && echo "  - a private key file is still in ~/.ssh; step 03 moves it into a password manager" \
    || echo "  ok no private key files in ~/.ssh"
  [ "$(plutil -extract sandbox.enabled raw "$HOME/.claude/settings.json" 2>/dev/null)" = true ] \
    && echo "  ok Claude Code sandbox enabled" \
    || echo "  - Claude Code sandbox is off; see step 04"
  return $fails
}

if [ $mode = check ]; then verify && exit 0 || exit 1; fi

# ---- plan and confirm ------------------------------------------------------
state() { [ -e "$1" ] && echo "overwrite" || echo "create"; }
echo
echo "Plan"
[ -n "$helper_src" ] && echo "  copy    $(t "$helper_src") -> $(t "$HELPER")"
echo "  $(state "$AG/gitconfig")  $(t "$AG/gitconfig")"
while read -r owner id; do echo "            $owner -> installation $id"; done <<< "$owners"
echo "  $(state "$AG/env.sh")  $(t "$AG/env.sh")   (default owner $default_owner)"
echo "  $(state "$AH/bin/gh")  $(t "$AH/bin/gh")   (from files/gh)"
for f in $(startup_files); do
  if [ "$(last_line "$f")" = "$SOURCE_LINE" ]; then echo "  keep    $(t "$f")   (already ends with the source line)"
  elif [ -f "$f" ] && grep -qxF "$SOURCE_LINE" "$f"; then echo "  move    the source line to the end of $(t "$f")"
  else echo "  append  the source line to $(t "$f")"; fi
done
echo "  source line: $SOURCE_LINE"
echo "Nothing else changes. Your ~/.gitconfig, ~/.ssh and gh login are not touched."
printf 'Proceed? [y/N] '
read -r answer || answer=""
case $answer in y|Y|yes) ;; *) echo "Cancelled. Nothing was changed."; exit 1 ;; esac

# ---- install ---------------------------------------------------------------
mkdir -p "$AG/bin" "$AH/bin"; chmod 700 "$AG"
[ -n "$helper_src" ] && install -m 755 "$helper_src" "$HELPER"

{
  echo "# Generated by install.sh; rerun it instead of editing. Read only inside agent shells."
  echo "[include]"
  echo "    path = ~/.gitconfig"
  echo "[credential]"
  echo "    helper ="
  echo "    useHttpPath = true"
  while read -r owner id; do
    echo "[credential \"https://github.com/$owner\"]"
    echo "    helper = $HELPER -username x-access-token -appId $app_id -privateKeyFile $KEY -installationId $id"
  done <<< "$owners"
  echo "[url \"https://github.com/\"]"
  echo "    insteadOf = git@github.com:"
  echo "    insteadOf = ssh://git@github.com/"
} > "$AG/gitconfig"
chmod 600 "$AG/gitconfig"

cat > "$AG/env.sh" <<ENV
# Generated by install.sh. Sourced in agent shells only; POSIX so zsh and bash both read it.
export GIT_CONFIG_GLOBAL="\$HOME/.config/agent-git/gitconfig"
export GH_CONFIG_DIR="\$HOME/.config/agent-gh"
export AGENT_GH_DEFAULT_OWNER=$default_owner
export PATH="\$HOME/.config/agent-gh/bin:\$PATH"
unset SSH_AUTH_SOCK
ENV
chmod 600 "$AG/env.sh"

install -m 755 "$HERE/files/gh" "$AH/bin/gh"

for f in $(startup_files); do
  [ "$(last_line "$f")" = "$SOURCE_LINE" ] && continue
  tmp=$(mktemp)
  [ -f "$f" ] && grep -vxF "$SOURCE_LINE" "$f" > "$tmp" || true
  printf '%s\n' "$SOURCE_LINE" >> "$tmp"
  cat "$tmp" > "$f"; rm -f "$tmp"
done

echo "Installed."
verify && echo "Done. New agent sessions use the App; open a new one to pick it up." || exit 1
