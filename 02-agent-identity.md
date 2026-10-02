# Step 02: Give the agent its own git and `gh` identity

| | |
|---|---|
| Required | yes |
| Depends on | [step 01](01-github.md) |
| If you skip it: security | The agent keeps using your SSH key and `gh` login, so GitHub cannot tell it from you. |
| If you skip it: operations | [Steps 03](03-ssh-key-to-password-manager.md) and [04](04-claude-code-sandbox.md) then break the agent's GitHub access entirely. |
| If you skip it: change elsewhere | Skip [03](03-ssh-key-to-password-manager.md) and [04](04-claude-code-sandbox.md) too. |

Mechanism: Claude Code sets `CLAUDECODE=1` in every Bash shell, in the
CLI and in Desktop. Two source lines load an env file only when that
marker is set. The env file points git at an agent-only global config.
It points `gh` at a config dir with no stored login and puts a `gh`
shim first on `PATH`. It unsets `SSH_AUTH_SOCK`. Your own shells never
set `CLAUDECODE`, so nothing changes for you.

## Before you run it

- Steps in [01](01-github.md) are done: the App exists, is installed on
  each owner, and its private key is at `~/.config/agent-git/app.pem`
  with mode 600.
- `jq` is available. It ships with macOS 15 and later as
  `/usr/bin/jq`. On older macOS, `brew install jq`.

## The credential helper

[`files/git-credential-agent`](files/git-credential-agent) is the only
code that reads the App's private key, so it lives in this repo and
uses nothing third-party. It signs a nine-minute JWT with the key using
`/usr/bin/openssl`, and posts it to GitHub with `/usr/bin/curl` in
exchange for a one-hour installation token. It reads GitHub's reply with
`jq`, preferring the copy in `/usr/bin`. It calls `openssl` and `curl`
by absolute path, so nothing earlier on your `PATH` can stand in for
them. The JWT goes to `curl` on stdin, so it never appears in the
process list. Read it before you run the installer; it is under 70
lines.

## Run the installer

From the root of this repo:

```bash
./install.sh --app-id <APP_ID> --default-owner <OWNER>
```

- `--app-id` is the App ID from [step 01](01-github.md#register-the-app).
- `--default-owner` is the owner `gh` uses when it is run outside a
  repo. It must be one of the App's installations.

The installer runs in three stages:

1. **Preflight.** It checks macOS, a zsh or bash login shell, git 2.32
   or newer, `gh` on `PATH`, `openssl`, `curl` and `jq`, the private key and its mode,
   and that `~/.gitconfig` does not rewrite GitHub HTTPS to SSH. It then
   asks the helper for the App's installations. Any failure stops it
   with the reason and the fix, and nothing is changed.
2. **Plan.** It prints every file it will create or overwrite, the
   owners and installation IDs it found, and each startup-file line it
   will add or move. It waits for `y`. Anything else cancels.
3. **Install and verify.** It writes the files, then mints a token for
   each owner and makes one API call with it. It reports any owner that
   fails.

Rerun it whenever you install the App on another owner. A rerun
rewrites its own files and changes nothing else.

`./install.sh --check` repeats the verification without changing
anything. It also reports whether [step 03](03-ssh-key-to-password-manager.md)
and [step 04](04-claude-code-sandbox.md) look done.

## What it writes

| Path | What it is |
|---|---|
| `~/.config/agent-git/gitconfig` | The agent's global gitconfig. It includes your `~/.gitconfig`, clears inherited credential helpers, adds one App helper line per owner, and rewrites SSH remotes to HTTPS |
| `~/.config/agent-git/env.sh` | Sets `GIT_CONFIG_GLOBAL`, `GH_CONFIG_DIR` and the default owner, puts the `gh` shim first on `PATH`, unsets `SSH_AUTH_SOCK` |
| `~/.config/agent-git/bin/git-credential-agent` | The [credential helper](#the-credential-helper), from `files/` |
| `~/.config/agent-gh/bin/gh` | The [`gh` shim](files/gh). It finds the repo owner, gets that owner's token from git and exports it as `GH_TOKEN`, then runs the real `gh` |
| the source line, at the end of two startup files | Loads `env.sh` only when `CLAUDECODE` is set |

The startup files are `~/.zshenv` and `~/.zprofile` for zsh, and
`~/.bash_profile` and `~/.bashrc` for bash. Your `~/.gitconfig`,
`~/.ssh` and own `gh` login are never touched.

Every git and `gh` call mints a fresh token, which costs one API round
trip. There is nothing to renew.

Owner names match case-sensitively. A remote's owner must match the
owner's login on GitHub exactly.

## Why two startup files

Claude Code's Bash runs a login shell. Any login file that prepends
`PATH` after `~/.zshenv` would put the real `gh` ahead of the shim.
Examples are macOS `path_helper` in `/etc/zprofile`, Homebrew's
`brew shellenv`, mise, asdf and nix. The source line at the end of the
login file puts the shim back in front. The shim finds the real `gh`
wherever it lives, so no path to `gh` is hardcoded.

If you later add lines below the source line, `--check` reports it and
a rerun moves the line back to the end.

Set your own `SSH_AUTH_SOCK` in `~/.zshenv` or `~/.bash_profile`, above
the source line. Never set it in `~/.zshrc`: anything that runs after
the source line can undo the unset.

## Who the commits belong to

Commit author and committer come from `user.name` and `user.email`,
set by the included `~/.gitconfig`. Commits the agent makes are still
authored by `alice` and signed with your key. The App identity applies
to the transport and the API. GitHub records the push, the branch
creation and the PR as `alice-agent[bot]`. The audit log and the PR
Approve button use that identity.

Alternative, not recommended: set `user.email` in the agent's gitconfig
to `<APP_ID>+alice-agent[bot]@users.noreply.github.com`, so commits show
the bot. Your GPG signature then no longer matches the committer email.
GitHub marks the commits Unverified unless you add that email as a UID
on your key.

## Checks

The installer has already checked that each owner's token works. These
checks cover what only an agent session can show. Ask the agent to run
them in a CLI session and in a Desktop session, inside a checkout of
`ExampleOrg/repo`:

| Check | Command | Expect |
|---|---|---|
| Env | `echo $GIT_CONFIG_GLOBAL $GH_CONFIG_DIR ${SSH_AUTH_SOCK:-nosock}` | agent paths, `nosock` |
| Shim first | `command -v gh` | `~/.config/agent-gh/bin/gh` |
| Fetch | `git ls-remote --heads origin stage \| head -1` | a sha |
| Transport | `GIT_TRACE=1 git ls-remote origin HEAD 2>&1 \| grep -m1 -o 'https://github.com[^ ]*'` | an https URL |
| App identity | `gh api /installation/repositories --jq .total_count` | a number |
| Admin blocked | `gh api -X PUT repos/ExampleOrg/repo/branches/stage/protection 2>&1 \| head -1` | 403 |
| Repo create blocked | `gh repo create alice/zz-test --private 2>&1 \| head -1` | an error |
| Feature push | `git push origin HEAD:refs/heads/zz-agent-test && git push origin --delete zz-agent-test` | both succeed |
| PR | `gh pr list --limit 1` | works |
| Personal owner | `git ls-remote git@github.com:alice/<repo>.git HEAD` | a sha |
| Workflow file | push a branch that touches `.github/workflows/x.yml` | rejected: the App lacks Workflows |

The App identity check works because `/installation/repositories`
answers only for an App installation token.

In your own terminal, in the same checkout: `git fetch` still uses SSH.
`gh auth status` still shows your own login, unchanged.

## Rollback

If you finished [03](03-ssh-key-to-password-manager.md) and
[04](04-claude-code-sandbox.md), roll those back first, or the agent has
no GitHub access at all. Then delete the source line from both startup
files. To remove the files too, keep the private key:

```bash
rm -r ~/.config/agent-gh ~/.config/agent-git/gitconfig ~/.config/agent-git/env.sh ~/.config/agent-git/bin
```
