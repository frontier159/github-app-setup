# Step 03: Move your SSH key into a password manager

| | |
|---|---|
| Required | recommended |
| Depends on | [step 02](02-agent-routing.md) |
| If you skip it: security | Your private key stays a readable file. Without [04](04-claude-code-sandbox.md) the agent can use it directly; with 04 the sandbox blocks the file, but any Bash path outside the sandbox, or a Desktop sandbox gap, can still use it. |
| If you skip it: operations | Nothing changes; you keep the file-based key. |
| If you skip it: change elsewhere | In [04](04-claude-code-sandbox.md#settings), keep `~/.ssh` in `denyRead` (already there); nothing else. |

Goal: `~/.ssh/id_rsa` stops existing as a file. Your shells get the key
from the password manager's SSH agent, with a prompt per use. Agent
shells have no agent socket ([step 02](02-agent-routing.md#what-it-writes)). After [step 04](04-claude-code-sandbox.md) they cannot read
`~/.ssh` or open agent sockets at all.

Prerequisite: [step 02 checks](02-agent-routing.md#checks) pass. The agent must already be on HTTPS.

Only Bitwarden's flow was walked through. Bitwarden's SSH agent is
part of its [desktop app](https://bitwarden.com/download/), with its
own [setup guide](https://bitwarden.com/help/ssh-agent/). Any password manager that
runs an SSH agent gives the same property: key in the vault, socket on
disk, prompt per use. Substitute its socket path in [Point your shells at it](#point-your-shells-at-it). If the agent
lives in an app container, add that container to `denyRead` in [step 04](04-claude-code-sandbox.md#settings).

| Agent | macOS socket path |
|---|---|
| Bitwarden (dmg) | `~/.bitwarden-ssh-agent.sock` |
| Bitwarden (App Store) | `~/Library/Containers/com.bitwarden.desktop/Data/.bitwarden-ssh-agent.sock` |
| 1Password | `~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock` |
| Secretive | `~/Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/socket.ssh`. The key cannot be exported; enrol a second key as break-glass |

## Inventory

Before touching the key, find every private key and everything that
uses one. These commands print names, paths and fingerprints, never key
contents:

```zsh
ssh-keygen -lf ~/.ssh/id_rsa.pub                   # fingerprint; compare with GitHub → Settings → SSH keys
ls ~/.ssh | grep -v -E '\.pub$|^known_hosts|^config$|^authorized_keys$'   # private keys, and anything else
grep -n 'IdentityFile\|Host ' ~/.ssh/config 2>/dev/null
git config --global --get core.sshCommand
grep -rIl 'id_rsa' ~/Library/LaunchAgents ~/.config ~/.zshrc ~/.zprofile ~/.zshenv ~/bin ~/.local/bin 2>/dev/null
crontab -l 2>/dev/null | grep -n ssh
head -1 ~/.ssh/id_rsa                              # the format line only
```

- **Each private key** listed by `ls` gets the treatment below. An
  `agent` folder is not a key: newer OpenSSH keeps agent sockets there.
- **Interactive uses**, such as GitHub, servers and other git hosts,
  keep working once the agent serves the key.
- **Unattended uses**, such as launchd, cron or scripts with
  `-i ~/.ssh/id_rsa`, break by design and need their own key. See
  [Unattended users and migration](#unattended-users-and-migration).
- **The format line** says whether the key imports as is.
  `-----BEGIN OPENSSH PRIVATE KEY-----` does.
  `-----BEGIN RSA PRIVATE KEY-----` is legacy PEM and needs converting
  first.

## Import into Bitwarden

The Bitwarden item becomes the key's home and its backup. The vault
encrypts it and syncs it to your other devices, so you need no separate
copy on disk.

Bitwarden accepts OpenSSH and PKCS#8 formats. This tells you whether
the key has a passphrase:

```zsh
ssh-keygen -y -P "" -f ~/.ssh/id_rsa >/dev/null 2>&1 && echo "no passphrase" || echo "has a passphrase"
```

If the format line said `OPENSSH PRIVATE KEY` and the key has no
passphrase, skip to **In the Bitwarden desktop app** below and copy
straight from `~/.ssh/id_rsa`.

Only if the format line said `RSA PRIVATE KEY`, or the key has a
passphrase, make an unencrypted OpenSSH copy in a private temporary
folder. The vault's encryption replaces the passphrase:

```zsh
T=$(mktemp -d) && cp ~/.ssh/id_rsa "$T/key" && ssh-keygen -p -o -N "" -f "$T/key" && head -1 "$T/key"
```

It asks for the old passphrase if there is one, and prints only the
format line, which is the same for every key. That line must now read
`-----BEGIN OPENSSH PRIVATE KEY-----`.

In the Bitwarden desktop app: **New item → SSH key**, name it
`github / servers rsa (alice)`. Pause any clipboard manager and turn off
Handoff first, or the key lands in clipboard history. Then:

```zsh
pbcopy < ~/.ssh/id_rsa            # or < "$T/key" if you converted
```

Click **Import key from clipboard**, and check the fingerprint
Bitwarden shows matches the one from the inventory. Save the item, then
clear the clipboard and any converted copy:

```zsh
pbcopy < /dev/null; [ -n "${T:-}" ] && rm -rf "$T"
```

## Optional: a copy that does not depend on Bitwarden

The vault item is enough for GitHub: if you ever lose it, sign in on
the web and add a new key. It matters for a server where this key is
your only way in.

For an independent copy, use Bitwarden's encrypted export: **Settings
→ Export vault**, format **.json (Encrypted)**, export type **File
password protected**, with a password you choose and keep somewhere
other than this vault. The **Account restricted** type decrypts only
with this Bitwarden account. The export includes SSH key
items. The file is encrypted, so a cloud folder such as iCloud Drive is
a reasonable place for it. Do not use the CSV export: it leaves out SSH
keys and is not encrypted.

## Enable the agent

Bitwarden desktop → **Settings → Enable SSH agent**. Then set **Ask for
authorization when using SSH agent** to the choice that asks every
time, at least until [step 04](04-claude-code-sandbox.md) is done. A
choice that remembers an approval lets later requests through without
a prompt. Settings → Security → **Unlock
with Touch ID** makes the unlock prompt a fingerprint. The docs do not
say whether Touch ID covers the per-signature prompt.

Confirm the socket exists. This is the dmg path; App Store users use
the path from the table above:

```zsh
ls -l ~/.bitwarden-ssh-agent.sock
```

## Point your shells at it

In `~/.zshenv`, or `~/.bash_profile` for bash, **above** the source line from [step 02](02-agent-routing.md#why-two-startup-files).
App Store users use the path from the table above:

```zsh
export SSH_AUTH_SOCK="$HOME/.bitwarden-ssh-agent.sock"
```

A GUI git client that does not read `~/.zshenv` needs the socket set in
its own settings.

New terminal, then:

```zsh
ssh-add -L | ssh-keygen -lf -          # fingerprint from the inventory appears
mv ~/.ssh/id_rsa ~/.ssh/id_rsa.disabled
ssh -T git@github.com                  # Bitwarden prompts; "Hi alice!"
git -C ~/git/REPO fetch                # works
```

If `ssh -T` fails, `ssh -vT git@github.com 2>&1 | grep -i 'agent\|Offering'`
shows whether the agent was reached.

## Remove the file

macOS runs its own SSH agent, which may still hold the key from
earlier use. Its socket stays reachable after the file is gone. Clear
it, then check:

```zsh
SSH_AUTH_SOCK=$(launchctl getenv SSH_AUTH_SOCK) ssh-add -D
SSH_AUTH_SOCK=$(launchctl getenv SSH_AUTH_SOCK) ssh-add -l
```

The second line must print `The agent has no identities.` If
`~/.ssh/config` has `UseKeychain` or `AddKeysToAgent` lines for this
key, remove them.

Once GitHub and your servers work through the agent:

```zsh
rm ~/.ssh/id_rsa.disabled              # the vault item is the copy
ls ~/.ssh                              # id_rsa.pub may stay; it is public
```

## Unattended users and migration

Each item from the inventory that needs a key file gets its own:

```zsh
ssh-keygen -t ed25519 -f ~/.ssh/JOB -C "JOB on $(hostname)"
```

Add the public half only where that job needs it. For GitHub, that is
a read-only deploy key on the one repo the job uses, never a key on
your account. Narrow keys per job beat the old shared RSA key; losing
one is bounded.

Optional rotation: generate an Ed25519 key in Bitwarden (New item → SSH
key, no import). Add its public key to GitHub and each server. Use it
for a month. Then remove the RSA public key everywhere and delete the
item.

## Break-glass

For a job that needs the key as a file, pause any clipboard manager
and turn off Handoff. Then copy the private key from the Bitwarden
item, and use it from a private temporary folder:

```zsh
T=$(mktemp -d) && pbpaste > "$T/key" && chmod 600 "$T/key" && pbcopy < /dev/null
ssh -i "$T/key" host                   # or GIT_SSH_COMMAND="ssh -i $T/key" git ...
rm -rf "$T"
```

Never copy the key back to `~/.ssh`.

## When a prompt appears that you did not expect

The prompt names only the program, usually `ssh`. To see what started it,
install [`files/ssh-who`](files/ssh-who) once:

```bash
mkdir -p ~/.local/bin && install -m 755 files/ssh-who ~/.local/bin/ssh-who
```

Then run `ssh-who` in your own terminal while the prompt is open. It waits
up to a minute for an `ssh` to appear. For each one it shows the host, the
folder it runs in, the chain of processes that started it, and the app at
the top of that chain. Common sources are an editor's background fetch, a
git app, or a terminal waiting on `git fetch`. Agent shells cannot reach the
agent socket; if the chain shows `claude`, deny the prompt.

### Editors and git apps

Editors and git apps fetch in the background, such as VS Code with
`git.autofetch` on. Each fetch over SSH asks for the key. There are two
fixes.

**Turn off auto-fetch.** In VS Code, set `"git.autofetch": false`.
You fetch by hand, and each prompt then matches something you did.

**Point the editor's git at the agent tokens.**
[`files/git-pat`](files/git-pat) runs git with the agent's config, so
it uses HTTPS with the per-owner tokens from
[step 02](02-agent-routing.md), never SSH. Install it:

```zsh
mkdir -p ~/.local/bin && install -m 755 files/git-pat ~/.local/bin/git-pat
```

Then point the editor at it. For VS Code, in its settings, with your
home folder in place of `/Users/YOU`:

```json
"git.path": "/Users/YOU/.local/bin/git-pat"
```

What changes:

- The editor's remotes switch to HTTPS. Your own terminal stays on SSH.
- Commits stay yours and signed. The agent's config includes your own.
- An owner with no agent token fails, and so does every owner once its
  token expires or is revoked.
- The editor can do only what the agent's tokens allow. Pushing a
  change to a workflow file fails, for example.
- Extensions with their own GitHub sign-in, such as VS Code's GitHub
  Pull Requests, do not use `git.path`.

Background fetch failures are silent. To see refusals in VS Code, open
**View → Output** and pick **Git**:

| Message | Meaning |
|---|---|
| `told us to quit` | no agent token for that owner |
| `Permission to OWNER/REPO.git denied`, or 403 | the token is not allowed, or the repo is not selected on it |
| `refusing to allow a Personal Access Token to create or update workflow` | the push touches a workflow file |
| `Authentication failed` | the token expired or was revoked |

## Checks

In your own terminal:

| Check | Command | Expect |
|---|---|---|
| SSH | `ssh -T git@github.com` | Bitwarden prompt, `Hi alice!` |
| Fetch | `git fetch` in any repo | works over SSH |
| `gh` | `gh auth status` | your own login, unchanged |
| No file | `ls ~/.ssh/id_rsa` | no such file |
| Env | `echo ${CLAUDECODE:-unset} $GIT_CONFIG_GLOBAL` | `unset`, empty |

In an agent shell, `ssh -T git@github.com` must fail without a
Bitwarden prompt.

## Rollback

Pause any clipboard manager and turn off Handoff. Copy the private key
from the Bitwarden item, then:

```zsh
pbpaste > ~/.ssh/id_rsa && chmod 600 ~/.ssh/id_rsa && pbcopy < /dev/null
```

Remove the `SSH_AUTH_SOCK` line.
