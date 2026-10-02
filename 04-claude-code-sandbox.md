# Step 04: Claude Code sandbox and deny rules

| | |
|---|---|
| Required | recommended |
| Depends on | [step 02](02-agent-identity.md) |
| If you skip it: security | Nothing OS-enforced stops the agent reading files or reaching agent sockets. [Step 02](02-agent-identity.md) is the only thing routing it to the App, and an env var can be unset. |
| If you skip it: operations | Nothing changes. |
| If you skip it: change elsewhere | None, but [03](03-ssh-key-to-password-manager.md) becomes the main barrier. |

## What "sandbox" means here

Nothing you launch. It is a block in `~/.claude/settings.json`. When
`sandbox.enabled` is true, Claude Code wraps every command the Bash tool
runs, and every child process, in macOS Seatbelt. Every session that
reads that settings file should apply it: the CLI, and the Claude Code
bundled in Desktop. The [checks](#checks) confirm it. It is off by default.

| Covered by the sandbox | Not covered, use `permissions.deny` |
|---|---|
| The Bash tool and its children (`git`, `gh`, `ssh`, scripts) | Read / Edit / Write / Grep tools |
| File reads and writes those processes make | MCP servers, hooks |
| Network: proxy allowlist, unix sockets blocked unless listed | WebFetch |

Two consequences matter here. The Bitwarden agent socket is unreachable
from the agent's processes. SSH git remotes fail inside the sandbox,
because unix sockets and `~/.ssh` are denied. Both force the agent onto
the HTTPS App path from [step 02](02-agent-identity.md).

## Settings

Merge [`files/claude-settings-fragment.json`](files/claude-settings-fragment.json)
into `~/.claude/settings.json` (user scope, so every repo). Do not
replace existing keys.

Notes:

- `Read(~/.ssh/**)` covers the Read tool and the common file commands
  (`cat`, `head`, `sed`) by pattern. `filesystem.denyRead` covers every
  process, including `grep -r` and scripts. Keep both.
- Do not deny `~/.gitconfig`; the agent's config includes it.
- `~/.config/agent-git/app.pem` stays readable on purpose. It is the
  agent's credential.
- `allowedDomains` lists GitHub only. Other hosts prompt on first use;
  approve the registries and RPC endpoints your repos reach.
- `allowUnixSockets` lists only the GPG agent socket. The agent signs
  commits with your GPG key, as it does today; commits stay yours.
- `Bash(security *)` and `Bash(git credential-osxkeychain *)` are speed
  bumps, not a boundary. See [Known limits](#known-limits).
- `allowUnsandboxedCommands: false` removes the "run this outside the
  sandbox" escape. If a tool needs more, add a path or domain instead of
  flipping this.
- `allowLocalBinding: true` keeps local dev servers working.
- `excludedCommands` is not used. Anything listed there runs with full
  access, which would undo the point for `git` or `gh`.

Precedence: deny rules from any scope win over allow from any scope.
A project's `.claude/settings.json` can add deny rules but cannot remove
these.

## Known limits

- **Keychain.** The sandbox allows the macOS keychain service, so
  `/usr/bin/security` can likely read your `gh` token without a prompt.
  The deny rules are speed bumps. [Step 01](01-github.md#optional-restrict-your-own-gh-login) explains how to
  keep your own `gh` login weak if you want that bounded.
- **Desktop.** If Desktop reads `~/.ssh` while the CLI cannot, Desktop
  is not applying the sandbox. [Steps 02](02-agent-identity.md) and [03](03-ssh-key-to-password-manager.md) still hold. Track
  anthropics/claude-code#98443.

## Checks

Start a new session in the CLI and in Desktop. Ask the agent to run
each line and report the result:

```zsh
ls ~/.ssh                                    # permission denied
cat ~/.config/gh/hosts.yml                   # denied
ssh -T git@github.com                        # denied or fails to connect
git -C ~/git/<repo> ls-remote --heads origin stage | head -1   # works (HTTPS App)
gh api /installation/repositories --jq .total_count             # a number
security find-generic-password -s gh:github.com -w >/dev/null && echo READABLE
git -C ~/git/<repo> commit --allow-empty -S -m "sandbox signing test" && git -C ~/git/<repo> log --show-signature -1
<your repo's normal build or check command>
```

The signing line must show a good signature. Run it on a scratch
branch and drop the commit with `git reset --hard HEAD~1`. Signing
needs only the agent socket: a signed commit succeeded with every write
to `~/.gnupg` blocked.

The `security` line must not print the token itself. If it prints
`READABLE`, the [keychain limit](#known-limits) applies to you.

## Rollback

Set `"sandbox": { "enabled": false }` and remove the deny entries. New
Bash commands pick up the change; no session restart.
