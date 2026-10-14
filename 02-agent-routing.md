# Step 02: Route the agent's git and `gh` through its tokens

| | |
|---|---|
| Required | yes |
| Depends on | [step 01](01-github.md) |
| If you skip it: security | The agent keeps using your SSH key and your own `gh` login. |
| If you skip it: operations | [Steps 03](03-ssh-key-to-password-manager.md) and [04](04-claude-code-sandbox.md) then break the agent's GitHub access entirely. |
| If you skip it: change elsewhere | Skip [03](03-ssh-key-to-password-manager.md) and [04](04-claude-code-sandbox.md) too. |

Mechanism: Claude Code sets `CLAUDECODE=1` in every Bash shell, in the
CLI and in Desktop. Two source lines load an env file only when that
marker is set. The env file points git at an agent-only global config,
which sends git over HTTPS with the agent's token for the repo's owner.
It points `gh` at a config dir with no stored login, and defines a `gh`
shell function that calls the `gh` shim, which uses the same tokens. It
unsets `SSH_AUTH_SOCK`. Your own shells never set `CLAUDECODE`, so
nothing changes for you.

## Routing, not a boundary

The agent cannot stop Claude Code setting `CLAUDECODE=1` when a shell
starts. Inside its own commands it can still step around the routing:
`unset CLAUDECODE` before starting a new shell, run git with
`env -u GIT_CONFIG_GLOBAL`, or call the real `gh` by its full path, such
as `/opt/homebrew/bin/gh`. An agent that hits a refusal may try exactly
this.

So this step makes the restricted tokens the agent's default path. It does not keep
the agent on it. What a bypass reaches depends on the later steps:

| Done | What the agent reaches by stepping around the routing |
|---|---|
| Only 01 and 02 | your SSH key file, which can do anything you can over git; your [own `gh` login](01-github.md#restrict-your-own-gh-login) is already restricted |
| Plus [03](03-ssh-key-to-password-manager.md) | no key file; your password manager prompts for each use, so you see it |
| Plus [04](04-claude-code-sandbox.md) | reading `~/.ssh` and opening agent sockets fail, so SSH as you fails |

Do 03 and 04 if you want a bypass to gain nothing over the agent's own
tokens. These make one less likely, but none is a boundary:

- **Auto mode's classifier** tends to block deliberate workarounds of a
  refusal.
- **Deny rules** such as `Bash(unset CLAUDECODE*)`, `Bash(env -u *)`
  and `Bash(/opt/homebrew/bin/gh *)` catch the plain forms, not ones
  inside a script.
- **An instruction in your `CLAUDE.md`**, such as "if GitHub refuses a
  call, stop and report it; never switch credentials or routing",
  steers a well-behaved agent. A prompt-injected one may ignore it.

## Before you run it

- [Step 01](01-github.md) is done, except the agent's tokens. Create
  each one in the browser when the installer asks for it, and paste it
  straight in. Never save a token yourself; the installer stores it.
- You run the installer in a terminal, so it can ask for each token
  with your typing hidden.
- If you sign commits with SSH (`gpg.format=ssh`), decide how agent
  commits are signed first. See
  [Who the commits belong to](#who-the-commits-belong-to).

## The credential helper

[`files/git-credential-agent`](files/git-credential-agent) is about 25
lines. When git needs a password for `github.com`, it takes the repo's
owner from the path git asks about and returns the token stored in
`~/.config/agent-git/tokens/<owner>`. It answers only over https. For
an owner with no token file, it tells git to stop, so git asks no later
helper, not even one a repo sets in its own config. Any other protocol
or host gets nothing, and git asks the next helper. The env file turns
off askpass and terminal prompts, so git cannot fall back to them.
Read the helper before you run the installer.

## Run the installer

```bash
./install.sh --owner ExampleOrg --owner alice --default-owner ExampleOrg
```

- `--owner` names an owner the agent works in. Repeat it for each.
- `--default-owner` is the owner `gh` uses when it is run outside a
  repo. It must be one of the `--owner` values.

The installer runs in three stages:

1. **Preflight.** It checks macOS, a zsh or bash login shell, git 2.32
   or newer, `gh` on `PATH`, and that neither `~/.config/git/config`
   nor `~/.gitconfig` rewrites GitHub HTTPS to SSH. Any failure stops it with the reason and the
   fix, and nothing is changed.
2. **Plan.** It prints every file it will create or overwrite, which
   tokens it will ask for, and each startup-file line it will add or
   move. It waits for `y`. Anything else cancels.
3. **Install and verify.** It asks you to paste each token it does not
   have yet, with echo off, and refuses anything that is not a
   fine-grained PAT. It writes the files, then checks every token: that
   GitHub accepts it, how long until it expires, and that an admin-only
   call is refused.

To add an owner, rerun it with every owner, the new one included, and
the same `--default-owner`. A rerun keeps stored tokens, rewrites its
own files and changes nothing else. To replace a token, delete its file and
rerun.

`./install.sh --check` repeats the verification without changing
anything. It also reports whether [step 03](03-ssh-key-to-password-manager.md)
and [step 04](04-claude-code-sandbox.md) look done.

## What it writes

| Path | What it is |
|---|---|
| `~/.config/agent-git/tokens/<owner>` | One token per owner, mode 600, in a folder only you can read |
| `~/.config/agent-git/gitconfig` | The agent's global gitconfig. It includes your `~/.config/git/config` and `~/.gitconfig`, clears inherited credential helpers, adds the agent's helper, and rewrites SSH remotes to HTTPS |
| `~/.config/agent-git/env.sh` | Sets `GIT_CONFIG_GLOBAL`, `GH_CONFIG_DIR` and the default owner, puts the shim dir first on `PATH`, and defines a `gh` function that calls the shim. Clears inherited GitHub tokens (`GH_TOKEN`, `GITHUB_TOKEN`), askpass programs and `SSH_AUTH_SOCK`, and turns off git's terminal prompt. Points `SSL_CERT_FILE` at macOS's certificate bundle, because `gh` cannot reach the system's certificate service inside the sandbox, and moves npm's cache into the sandbox's temp folder |
| `~/.config/agent-git/bin/git-credential-agent` | The [credential helper](#the-credential-helper), from `files/` |
| `~/.config/agent-gh/bin/gh` | The [`gh` shim](files/gh). It finds the repo owner, gets that owner's token from git and exports it as `GH_TOKEN`, then runs the real `gh` |
| the source line, at the end of two startup files | Loads `env.sh` only when `CLAUDECODE` is set |

The startup files are `~/.zshenv` and `~/.zprofile` for zsh, and
`~/.bash_profile` and `~/.bashrc` for bash. Before it changes one, the
installer makes a first backup, `<file>.agent-bak`, and keeps it across
reruns. Login bash stops reading `~/.profile` once `~/.bash_profile`
exists. So if you have only `~/.profile`, the new `~/.bash_profile`
gets a line that sources it, above the source line. Your
`~/.gitconfig`, `~/.ssh` and own `gh` login are never touched.

The tokens expire on the date you set in step 01. `--check` warns two
weeks ahead. Replace a token by creating a new one, deleting the old
file and rerunning the installer.

## Why two startup files

Claude Code runs each Bash command as `zsh -c`, or your shell's
equivalent. zsh reads `~/.zshenv` for every shell, and on the machine
this was written on it also read `~/.zprofile`. Claude Code then
sources a snapshot of your shell taken when the session started, and
that snapshot sets `PATH` again. So a `PATH` entry from the env file
does not survive, and `gh` would resolve to the real one.

A shell function does survive, because the snapshot only replaces
`PATH` and aliases. The env file defines `gh` as a function that calls
the shim, so a plain `gh` command reaches the shim. The source line
sits last in both files so that nothing after it redefines the
routing. The shim finds the real `gh` wherever it lives, so no path to
`gh` is hardcoded.

A script that runs `gh` as a child process does not see the function.
It gets the real `gh`, which finds the agent's empty config dir and
reports no login. It fails closed: it never falls back to your own
login.

bash is less certain. `bash -c` reads neither `~/.bash_profile` nor
`~/.bashrc`, so the routing may not load at all. After installing, run
the shim check under [Checks](#checks) in an agent session. If `gh`
is not a function there, this setup does not yet route your shell.

If you later add lines below the source line, `--check` reports it and
a rerun moves the line back to the end.

Set your own `SSH_AUTH_SOCK` in `~/.zshenv` or `~/.bash_profile`, above
the source line. Never set it in `~/.zshrc`: anything that runs after
the source line can undo the unset.

## Who the commits belong to

Everything the agent does is recorded as you: commits, pushes, PRs,
comments and reviews. Commit author and committer come from
`user.name` and `user.email` in your own git config. The agent's
gitconfig includes both `~/.config/git/config` and `~/.gitconfig`, in
git's own order, so identity and signing set in either one carry over.

GPG signing keeps working: agent commits stay signed with your key.
SSH signing (`gpg.format=ssh`) does not. Agent shells have no SSH
agent, step 03 removes the key file, and step 04 blocks the sockets.
With `commit.gpgsign=true`, every agent commit then fails. Choose one:

- Switch your signing to GPG.
- After installing, add these lines by hand to
  `~/.config/agent-git/gitconfig`, so agent commits go unsigned. The
  installer rewrites that file, so add them again after each rerun.

  ```ini
  [commit]
      gpgsign = false
  ```

Because its approvals would count as yours, the `gh` shim refuses
`gh pr review --approve` and API calls that approve. Comment reviews
still work. This is a speed bump, not a boundary: an agent that called
the real `gh` directly could approve.

## Checks

The installer has already checked that each owner's token works. These
checks cover what only an agent session can show. Ask the agent to run
them in a CLI session and in a Desktop session, inside a checkout of
`ExampleOrg/repo`:

| Check | Command | Expect |
|---|---|---|
| Env | `echo $GIT_CONFIG_GLOBAL $GH_CONFIG_DIR ${SSH_AUTH_SOCK:-nosock}` | agent paths, `nosock` |
| Shim used | `type gh` | `gh is a shell function` (zsh) or `gh is a function` (bash) |
| Fetch | `git ls-remote origin HEAD` | a sha |
| Transport | `GIT_TRACE=1 git ls-remote origin HEAD 2>&1 \| grep -m1 -o 'https://github.com[^ ]*'` | an https URL |
| Token used | `gh api user --jq .login` | your login |
| Admin blocked | `gh api repos/ExampleOrg/repo/keys 2>&1 \| grep -o 'HTTP 403'` | `HTTP 403` |
| Approval blocked | `gh pr review 999999999 --approve` | refused by the shim; real `gh` would say not found |
| Feature push | `git push origin HEAD:refs/heads/zz-agent-test && git push origin --delete zz-agent-test` | both succeed |
| PR | `gh pr list --limit 1` | works |
| CI for a branch | `gh run list --branch BRANCH --limit 3` | its workflow runs and results |
| CI runs | `gh run list --limit 1` | the latest workflow run |
| Personal owner | `git ls-remote git@github.com:alice/REPO.git HEAD` | a sha |
| Workflow file | push a branch that touches `.github/workflows/x.yml` | rejected: the token lacks Workflows |

The admin check reads a repo's deploy keys, which needs Administration.
It changes nothing even if the token were wrongly allowed.

In your own terminal, in the same checkout: `git fetch` still uses SSH.
`gh auth status` still shows your own login, unchanged.

## Rollback

If you finished [03](03-ssh-key-to-password-manager.md) and
[04](04-claude-code-sandbox.md), roll those back first, or the agent has
no GitHub access at all. Then delete the source line from both startup
files. To remove the files and tokens too:

```bash
rm -r ~/.config/agent-gh ~/.config/agent-git
```

Revoke the tokens on GitHub as in [step 01's rollback](01-github.md#rollback).
