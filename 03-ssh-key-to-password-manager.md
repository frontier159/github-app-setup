# Step 03: Move your SSH key into a password manager

| | |
|---|---|
| Required | recommended |
| Depends on | [step 02](02-agent-identity.md) |
| If you skip it: security | Your private key stays a readable file. Without [04](04-claude-code-sandbox.md) the agent can use it directly; with 04 the sandbox blocks the file, but any Bash path outside the sandbox, or a Desktop sandbox gap, can still use it. |
| If you skip it: operations | Nothing changes; you keep the file-based key. |
| If you skip it: change elsewhere | In [04](04-claude-code-sandbox.md#settings), keep `~/.ssh` in `denyRead` (already there); nothing else. |

Goal: `~/.ssh/id_rsa` stops existing as a file. Your shells get the key
from the password manager's SSH agent, with a prompt per use. Agent
shells have no agent socket ([step 02](02-agent-identity.md#what-it-writes)). After [step 04](04-claude-code-sandbox.md) they cannot read
`~/.ssh` or open agent sockets at all.

Prerequisite: [step 02 checks](02-agent-identity.md#checks) pass. The agent must already be on HTTPS.

Only Bitwarden's flow was walked through. Any password manager that
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

Before touching the key, list where it is used:

```zsh
ssh-keygen -lf ~/.ssh/id_rsa.pub                   # fingerprint; compare with GitHub → Settings → SSH keys
grep -n 'IdentityFile\|Host ' ~/.ssh/config 2>/dev/null
grep -rl 'id_rsa' ~/Library/LaunchAgents ~/.config 2>/dev/null   # unattended users of the file
crontab -l 2>/dev/null | grep -n ssh
```

Interactive uses (servers, GitHub, other git hosts) keep working once
the agent serves the key. Unattended uses (launchd, cron, scripts with
`-i ~/.ssh/id_rsa`) break by design and need their own key. List them;
they are the break-glass cases.

## Break-glass backup

An encrypted disk image, offline, holding the whole `~/.ssh`:

```zsh
hdiutil create -size 20m -fs APFS -encryption AES-256 -volname breakglass-ssh ~/Desktop/breakglass-ssh.dmg
hdiutil attach ~/Desktop/breakglass-ssh.dmg
cp -Rp ~/.ssh /Volumes/breakglass-ssh/ssh-$(date +%Y%m%d)
diff -r ~/.ssh /Volumes/breakglass-ssh/ssh-$(date +%Y%m%d) && echo backup-verified
hdiutil detach /Volumes/breakglass-ssh
```

`hdiutil` prompts for the passphrase. diff reports sockets
(ControlMaster) as differing; those lines are expected.

Store the passphrase in Bitwarden as a separate login item. Move the
`.dmg` to a USB stick or your existing backup target. Do not leave it in
`~/Desktop`; any process running as your user can read it.

Second copy: Bitwarden's own encrypted export (Settings → Export vault →
**.json (Encrypted)**) includes SSH key items. CSV does not.

## Import into Bitwarden

Bitwarden accepts OpenSSH and PKCS#8 formats. A key that begins with
`-----BEGIN RSA PRIVATE KEY-----` is legacy PEM. Convert a copy inside
the mounted image first:

```zsh
hdiutil attach ~/path/to/breakglass-ssh.dmg
cp /Volumes/breakglass-ssh/ssh-*/id_rsa /Volumes/breakglass-ssh/id_rsa.openssh
ssh-keygen -p -o -N "" -f /Volumes/breakglass-ssh/id_rsa.openssh    # OpenSSH format, no passphrase; the vault encrypts it
head -1 /Volumes/breakglass-ssh/id_rsa.openssh                       # must say OPENSSH PRIVATE KEY
```

In the Bitwarden desktop app: **New item → SSH key**, name it
`github / servers rsa (alice)`. Then use **Import key from clipboard**.

Pause any clipboard manager and turn off Handoff, or the key lands in
clipboard history.

```zsh
pbcopy < /Volumes/breakglass-ssh/id_rsa.openssh
# click "Import key from clipboard" in Bitwarden, confirm the fingerprint matches the inventory
pbcopy < /dev/null                                                   # clear the clipboard
rm /Volumes/breakglass-ssh/id_rsa.openssh
hdiutil detach /Volumes/breakglass-ssh
```

## Enable the agent

Bitwarden desktop → **Settings → Enable SSH agent**. Also tick **Ask for
authorization when using SSH agent**. Settings → Security → **Unlock
with Touch ID** makes the unlock prompt a fingerprint. The docs do not
say whether Touch ID covers the per-signature prompt.

Confirm the socket exists:

```zsh
ls -l ~/.bitwarden-ssh-agent.sock
```

## Point your shells at it

In `~/.zshenv`, or `~/.bash_profile` for bash, **above** the source line from [step 02](02-agent-identity.md#why-two-startup-files):

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
git -C ~/git/<repo> fetch              # works
```

If `ssh -T` fails, `ssh -vT git@github.com 2>&1 | grep -i 'agent\|Offering'`
shows whether the agent was reached.

## Remove the file

Once GitHub and your servers work through the agent:

```zsh
rm ~/.ssh/id_rsa.disabled              # the backup is the .dmg and the vault
ls ~/.ssh                              # id_rsa.pub may stay; it is public
```

## Unattended users and migration

Each item from the inventory that needs a key file gets its own:

```zsh
ssh-keygen -t ed25519 -f ~/.ssh/<job-name> -C "<job> on $(hostname)"
```

Add the public half only where that job needs it. Narrow keys per job
beat the old shared RSA key; losing one is bounded.

Optional rotation: generate an Ed25519 key in Bitwarden (New item → SSH
key, no import). Add its public key to GitHub and each server. Use it
for a month. Then remove the RSA public key everywhere and delete the
item.

## Break-glass

Mount the `.dmg`, then run `ssh -i /Volumes/breakglass-ssh/ssh-*/id_rsa
host`, or `GIT_SSH_COMMAND='ssh -i /Volumes/breakglass-ssh/ssh-*/id_rsa'
git ...`. Detach afterwards. Never copy the key back to `~/.ssh`.

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

Copy `id_rsa` from the `.dmg` back to `~/.ssh/id_rsa` (`chmod 600`).
Remove the `SSH_AUTH_SOCK` line.
