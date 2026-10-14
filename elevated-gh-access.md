# Optional: elevated `gh` access through Bitwarden

| | |
|---|---|
| Required | optional |
| Depends on | [restricting your own `gh` login](01-github.md#restrict-your-own-gh-login), and [step 04](04-claude-code-sandbox.md) with its checks passing, in Desktop too |
| If you skip it: security | Nothing changes. Admin work stays in the browser. |
| If you skip it: operations | Admin commands such as `gh repo create` don't work from your terminal. |
| If you skip it: change elsewhere | nothing |

Your everyday `gh` login should be too weak to administer anything,
because the agent can probably borrow it. Sometimes you want admin
commands in the terminal anyway. `gh-admin` runs one `gh` command with
a stronger token that lives in your Bitwarden vault, then locks the
vault again:

```bash
gh-admin repo create alice/new-repo --private
```

Plain `gh` stays on your restricted login. The pattern is the same as
`aws-vault exec`: the strong credential is locked away and comes out
for one command.

Set up step 04 first. Without it, the agent can replace `gh-admin` or
`bw`, or add a `gh-admin` function to a startup file, and catch your
master password the next time you type it. Step 04's sandbox confines
the agent's Bash writes. Its `Edit(...)` deny rules cover the file
tools, which run outside the sandbox. Desktop has a report of ignoring
some Edit and Write deny rules (anthropics/claude-code#98443), so run
step 04's [edit check](04-claude-code-sandbox.md#checks) in Desktop.

## How it works

[`files/gh-admin`](files/gh-admin) is a short bash script. For each
call it:

1. refuses to run in an agent shell, or without a terminal;
2. turns off echo, prompts for your Bitwarden master password, and
   unlocks the Bitwarden CLI vault with it;
3. reads the password field of the vault item named `gh-admin`;
4. runs `gh` with that token as `GH_TOKEN` and an empty config
   directory, so it never touches your stored login;
5. locks the vault and deletes the config directory, whether `gh`
   succeeded or not.

The master password reaches `bw` through a file descriptor, never the
environment or the command line. The session key reaches `bw get`, and
the token reaches `gh`, through the environment. Any process running as
you can read a process's environment with `ps -E` while that command
runs. Keep `gh-admin` commands short. The token lives only in the
wrapper's memory and `gh`'s environment, never on disk or in argv.

## Set up

1. **Create the elevated token.** Prefer a fine-grained PAT over an
   OAuth login: GitHub → **Settings → Developer settings → Personal
   access tokens → Fine-grained tokens**. Give it only the repos you
   administer, Administration read and write plus what the task needs,
   and an expiry. An OAuth `gho_` token works too, but it never
   expires and covers every repo you can reach.
2. **Store it in Bitwarden** as a login item named exactly `gh-admin`,
   with the token as its password. The name must match one item only.
3. **Install and log in to the Bitwarden CLI**, once:

   ```bash
   brew install bitwarden-cli
   bw login
   ```

   The CLI is Bitwarden's own, separate from the desktop app; its
   [docs](https://bitwarden.com/help/cli/) list other ways to install it. It keeps
   an encrypted copy of your vault and needs your master password to
   read it.
4. **Install the wrapper**:

   ```bash
   mkdir -p ~/.local/bin && install -m 755 files/gh-admin ~/.local/bin/gh-admin
   ```

   If `~/.local/bin` is not on your `PATH`, add it in `~/.zshenv`.

5. **Check it:**

   ```bash
   gh-admin auth status
   ```

   It prompts for your master password and shows the elevated token's
   account.

If you add or change the `gh-admin` item in another Bitwarden app, run
`bw sync` once so the CLI sees it.

## What protects the token

- **The vault is locked between commands.** Reading the item needs
  your master password, typed at a terminal. An agent's shell has no
  terminal to type into.
- **The session ends with the command.** `gh-admin` locks the vault
  on exit, so no session key is left for another process to reuse.
- **Never export `BW_SESSION`** in a startup file or keep one in a
  terminal you leave open. An unlocked session is as good as the
  password for anything running as you.
- **The agent check is a speed bump.** The script refuses when
  `CLAUDECODE` is set, but an agent could unset it. The master
  password is the real control. The sandbox confines the agent's Bash
  writes. The `Edit(...)` deny rules cover its file tools, for the
  files they name only, with the Desktop caveat above. The settings
  fragment in [step 04](04-claude-code-sandbox.md#settings) also denies
  `gh-admin` and `bw` to the agent, and stops it reading the Bitwarden
  vault copies it names.
- **Code the agent wrote runs as you** when you run it outside an
  agent session: `npm test`, `make`, a git hook in a fresh clone, an
  `.envrc`. It runs unsandboxed, so it could catch your master
  password. Run builds and tests from the agent session, or read the
  diff, before you next type your master password.

## Limits

- **Your master password unlocks everything.** This uses the Bitwarden
  CLI's normal unlock, which opens the whole vault for the length of
  one command. Type it only into a `gh-admin` prompt you started.
- **An admin command runs with full power.** Read it before you press
  Return. The token can do whatever you gave it.

## Rollback

```bash
rm ~/.local/bin/gh-admin
bw logout
```

Then delete the `gh-admin` item in Bitwarden and revoke the token on
GitHub.
