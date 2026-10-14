# Step 04: Claude Code sandbox and deny rules

| | |
|---|---|
| Required | recommended |
| Depends on | [step 02](02-agent-routing.md) |
| If you skip it: security | Nothing OS-enforced stops the agent reading files or reaching agent sockets. [Step 02](02-agent-routing.md) is the only thing routing it to its tokens, and an env var can be unset. |
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
the HTTPS token path from [step 02](02-agent-routing.md).

## Settings

Merge [`files/claude-settings-fragment.json`](files/claude-settings-fragment.json)
into `~/.claude/settings.json` (user scope, so every repo). Do not
replace existing keys.

Notes:

- `Read(~/.ssh/**)` covers the Read tool and the common file commands
  (`cat`, `head`, `sed`) by pattern. `filesystem.denyRead` covers every
  process, including `grep -r` and scripts. Keep both.
- The `Edit(...)` rules cover every file-editing tool, which runs
  outside the sandbox. They stop the agent changing what you run: the
  `gh-admin` wrapper and other tools in `~/.local/bin`, Homebrew's
  `gh` and `bw`, the agent's routing files, and your shell startup
  files. A changed copy of any of them could catch your master password
  or a token.
- The Bitwarden paths are the desktop app's data (dmg and App Store
  builds) and the CLI's. Each holds an encrypted copy of your vault,
  with your SSH key and the `gh-admin` token, protected only by your
  master password. The `Read(...)` rules cover the Read tool;
  `denyRead` covers processes.
- Do not deny `~/.gitconfig`; the agent's config includes it.
- `~/.config/agent-git/tokens/` stays readable on purpose. It holds
  the agent's credentials.
- `allowedDomains` lists GitHub only. Other hosts prompt on first use;
  approve the registries and RPC endpoints your repos reach.
- `allowUnixSockets` lists only the GPG agent socket. The agent signs
  commits with your GPG key, as it does today; commits stay yours.
  The same socket also lets the agent decrypt anything encrypted to
  your key. If you sign with SSH (`gpg.format=ssh`), the agent cannot
  sign at all; see [step 02](02-agent-routing.md#who-the-commits-belong-to).
- `Bash(security *)` and `Bash(git credential-osxkeychain *)` are speed
  bumps, not a boundary. See [Known limits](#known-limits).
- `allowUnsandboxedCommands: false` removes the "run this outside the
  sandbox" escape. If a tool needs more, add a path or domain instead of
  flipping this.
- `allowLocalBinding: true` keeps local dev servers working.
- `excludedCommands` is not used. Anything listed there runs with full
  access, which would undo the point for `git` or `gh`.

Precedence: deny rules merge across scopes and always win, so a
project cannot remove these. The rest of the sandbox block is weaker.
Once you trust a workspace, its own `.claude/settings.json` can turn
the sandbox off or widen it, with more sockets, domains or local
binding. User settings cannot prevent that. Only managed settings that
make the sandbox admin-required can. So check `.claude/settings*.json`
in a repo you clone before you trust it. A team that needs this
enforced should use managed settings.

## Known limits

- **Keychain.** The sandbox allows the macOS keychain service, so
  `/usr/bin/security` can likely read your `gh` token without a prompt.
  The deny rules are speed bumps. [Step 01](01-github.md#restrict-your-own-gh-login) makes that login a
  restricted token, so reading it gains the agent nothing.
- **Edit deny rules in Desktop.** Desktop has a report of ignoring some
  Edit and Write deny rules (anthropics/claude-code#98443). Run the
  edit check under [Checks](#checks) in Desktop too.
- **Desktop.** If Desktop reads `~/.ssh` while the CLI cannot, Desktop
  is not applying the sandbox. [Steps 02](02-agent-routing.md) and [03](03-ssh-key-to-password-manager.md) still hold.

## Checks

Start a new session in the CLI and in Desktop, inside a scratch
checkout of one of your repos. The sandbox confines writes to the
session's working directory, so the signing line needs the session to
start there. Ask the agent to run each line and report the result:

```zsh
ls ~/.ssh                                    # permission denied
cat ~/.config/gh/hosts.yml                   # denied
ssh -T git@github.com                        # denied or fails to connect
git ls-remote origin HEAD                    # a sha (HTTPS, agent token)
gh api user --jq .login                      # your login, via the agent token
git commit --allow-empty -S -m "sandbox signing test" && git log --show-signature -1
<your repo's normal build or check command>
```

Then the edit check. Ask the agent to create
`~/.local/bin/agent-edit-test` with its Write tool, not with Bash. A
deny rule must refuse it. If the file appears, delete it: that session
ignores the `Edit(...)` rules.

The signing line must show a good signature. Run it on a scratch
branch and drop the commit with `git reset --hard HEAD~1`. Signing
needs only the agent socket: a signed commit succeeded with every write
to `~/.gnupg` blocked.

## Rollback

Set `"sandbox": { "enabled": false }` and remove the deny entries. New
Bash commands pick up the change; no session restart.
