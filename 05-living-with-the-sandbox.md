# Step 05: Living with the sandbox

| | |
|---|---|
| Required | recommended reading |
| Depends on | [step 04](04-claude-code-sandbox.md) |
| If you skip it: security | When a command fails, you may widen the sandbox more than it needs, or run an agent's `!` suggestion without reading it. |
| If you skip it: operations | Each blocked command costs a detour, and the same blocks come back with no record of them. |
| If you skip it: change elsewhere | nothing |

[Step 04](04-claude-code-sandbox.md) turns the sandbox on. This page
covers what breaks afterwards, the narrowest fix for each, and a loop
that records blocks so you fix them once.

Each settings change below is one `jq` command. It copies
`~/.claude/settings.json` to `settings.json.bak` first, writes a new
copy, then moves it into place. The next change overwrites that
backup, so keep your own copy before you start:

```zsh
cp ~/.claude/settings.json ~/.claude/settings.json.before-05
```

## What runs outside the sandbox

The sandbox wraps the Bash tool's commands and their children, in
macOS Seatbelt. These run outside it, with your full access:

- commands you type after `!` in most sessions;
- the Read, Edit and Write tools;
- WebFetch and WebSearch;
- MCP servers;
- hooks.

An agent may suggest you run a command with `!`. That runs it
unsandboxed, as you. Read it first.

Inside the sandbox, commands can write only to:

- the session's working folder;
- `$TMPDIR`;
- folders added with `/add-dir` or `permissions.additionalDirectories`;
- `sandbox.filesystem.allowWrite` entries. A `*` there is a literal
  character, not a glob.

Read and Edit deny rules merge into the sandbox's `denyRead` and
`denyWrite`, and deny beats allow. So an `Edit(~/X/**)` deny cancels
any `allowWrite` inside `~/X`, with no warning.

The network goes through a proxy allowlist. On a new host Claude Code
prompts. "Yes" allows it for the rest of the session. "Yes, and don't
ask again" saves a `WebFetch(domain:HOST)` allow rule to that
project's `.claude/settings.local.json`. In auto mode a classifier
decides instead of a prompt. Hosts you want in every project go in
`sandbox.network.allowedDomains` in `~/.claude/settings.json`. Prefer
exact hosts. A wildcard over an organisation's domain also opens its
internal services.

Permission rules apply in order: deny, then ask, then allow. The first
match wins. An ask rule prompts even in auto mode.

## Common friction and fixes

### Another folder or a git worktree

- **Symptom:** writes outside the session's folder fail with
  "Operation not permitted".
- **Cause:** the sandbox allows writes only in the session's folder
  and the folders you add.
- **Fix:** start the session in that folder, or run `/add-dir PATH`
  for this session. For worktrees, keep them under one parent folder
  beside the repo, and add that parent once:

  ```zsh
  cp ~/.claude/settings.json ~/.claude/settings.json.bak && jq --arg d "$HOME/git/REPO-worktrees" '.permissions.additionalDirectories = ((.permissions.additionalDirectories // []) + [$d] | unique)' ~/.claude/settings.json > ~/.claude/settings.json.new && mv ~/.claude/settings.json.new ~/.claude/settings.json
  ```

  Move an existing worktree there with
  `git worktree move OLD_PATH ~/git/REPO-worktrees/BRANCH`. Prefer a
  sibling parent to one inside the repo. Claude Code guards some files
  in a repo, such as `.gitmodules`, and a worktree inside the repo can
  run into those guards. Tell agents where to put worktrees with a
  line in your `CLAUDE.md`, such as "Create git worktrees under
  ~/git/REPO-worktrees, never inside the repo."
- **Cost:** agents can write anywhere under that parent, in every
  session.

### Local dev servers

- **Symptom:** a dev server fails to start with "Operation not
  permitted" when it binds a port.
- **Cause:** step 04 leaves `allowLocalBinding` off.
- **Fix:**

  ```zsh
  cp ~/.claude/settings.json ~/.claude/settings.json.bak && jq '.sandbox.network.allowLocalBinding = true' ~/.claude/settings.json > ~/.claude/settings.json.new && mv ~/.claude/settings.json.new ~/.claude/settings.json
  ```

- **Cost:** it covers every port. Sandboxed commands can then reach any
  service on localhost. Do not run an unauthenticated local service
  that holds secrets, such as `bw serve`.

### Package installs

- **Symptom:** installs fail on the network, or on writes to a cache
  or store.
- **Cause:** the registry host is not allowed, or the cache sits
  outside the writable folders. npm's cache in `~/.npm` is not
  writable, so [step 02's env file](02-agent-routing.md#what-it-writes)
  moves it under `$TMPDIR`. pnpm works when its store is inside the
  project; `pnpm store path` shows where it is.
- **Fix:** allow the registry host, for example:

  ```zsh
  cp ~/.claude/settings.json ~/.claude/settings.json.bak && jq '.sandbox.network.allowedDomains = ((.sandbox.network.allowedDomains // []) + ["registry.npmjs.org"] | unique)' ~/.claude/settings.json > ~/.claude/settings.json.new && mv ~/.claude/settings.json.new ~/.claude/settings.json
  ```

  A pnpm store elsewhere needs that one folder in
  `sandbox.filesystem.allowWrite`, added the same way.
- **Cost:** install scripts run inside the sandbox and can read your
  registry config. So registry tokens must be read-only; see
  [step 01](01-github.md#find-package-registry-tokens).
- **Note:** a dead or expired registry token makes every request fail
  with 401, even for public packages. npm then reports sandbox write
  denials as "root-owned files". Remove or replace the token first.

### Version managers

- **Symptom:** every `pnpm` or `npm` command fails on a write under the
  version manager's folder.
- **Cause:** some version managers write their shims on every run.
  proto resets the shim files' permissions each time; asdf and mise may
  differ.
- **Fix:** give `allowWrite` only the shims folders, one entry per
  installed version, because `*` is not a glob. Regenerate the list
  from the install folder after each upgrade. For proto:

  ```zsh
  shims=$(for t in pnpm npm; do for v in ~/.proto/tools/$t/*/; do [ -d "${v}shims" ] && printf '"~/.proto/tools/%s/%s/shims"\n' "$t" "$(basename "$v")"; done; done | jq -s .) && cp ~/.claude/settings.json ~/.claude/settings.json.bak && jq --argjson s "$shims" '.sandbox.filesystem.allowWrite = ([(.sandbox.filesystem.allowWrite // [])[] | select(startswith("~/.proto/tools/") | not)] + $s | unique)' ~/.claude/settings.json > ~/.claude/settings.json.new && mv ~/.claude/settings.json.new ~/.claude/settings.json
  ```

  An `Edit(~/.proto/**)` deny cancels these entries. Find the failing
  write with the tool's trace logging, such as `PROTO_LOG=trace`.
- **Cost:** small. Do not allow the whole folder. It holds programs you
  run unsandboxed, so a bad install script could plant itself in your
  toolchain.

### Browsers

- **Symptom:** Playwright, Puppeteer or any Chromium fails at launch
  with "bootstrap_check_in ... Permission denied (1100)".
- **Cause:** Chromium cannot register its Mach ports inside the macOS
  sandbox, whatever the profile or build.
- **Fix:** use Microsoft's Playwright MCP server, which runs outside
  the sandbox. Pin a version you have checked:

  ```zsh
  claude mcp add --scope user --transport stdio playwright -- npx -y @playwright/mcp@VERSION --headless --isolated
  ```

  `--isolated` keeps the browser profile in memory. Then allow its
  tools and deny the one that runs supplied code in the server:

  ```zsh
  cp ~/.claude/settings.json ~/.claude/settings.json.bak && jq '.permissions.allow = ((.permissions.allow // []) + ["mcp__playwright__*"] | unique) | .permissions.deny = ((.permissions.deny // []) + ["mcp__playwright__browser_run_code_unsafe"] | unique)' ~/.claude/settings.json > ~/.claude/settings.json.new && mv ~/.claude/settings.json.new ~/.claude/settings.json
  ```

  Reconnect with `/mcp`, or start a new session.
- **Cost:** the browser runs unsandboxed and can reach any site.
  `--allowed-origins` exists, but its README says it is not a security
  boundary. Never use an extension that drives your real browser for
  this; that browser holds your sessions.

Dev servers that open a browser on start, such as Vite, Storybook or
Ladle, fail that step inside the sandbox, often with blocked `ps` or
`open` calls. Step 02's env file sets `BROWSER=none`, which these tools
read as "never open a browser". A dev server whose port is busy may
quietly pick another one, so read the actual port from its startup
output before pointing the browser tools at it.

### `gh` and other Go programs fail TLS

- **Symptom:** `gh` fails with a certificate error, OSStatus -26276.
- **Cause:** Go programs verify certificates through a macOS service
  the sandbox blocks.
- **Fix:** [step 02's env file](02-agent-routing.md#what-it-writes)
  sets `SSL_CERT_FILE=/etc/ssl/cert.pem` in agent shells. Rerun the
  installer if your env file predates it.
- **Cost:** none.

### Verifying commit signatures

- **Symptom:** signing works; `git log --show-signature` or
  `git verify-commit` fails.
- **Cause:** gpg opens its trust database for writing when it
  verifies.
- **Fix:** verify in your own terminal, or on GitHub. Do not allow
  writes to `~/.gnupg`.
- **Cost:** none.

### Listing processes

- **Symptom:** `ps` and `pgrep` fail.
- **Cause:** the sandbox blocks reading other processes.
- **Fix:** run such checks yourself, in your own terminal.
- **Cost:** none.

### Web research

- **Symptom:** fetch prompts on every new site.
- **Cause:** WebFetch runs outside the sandbox, so permission rules
  decide.
- **Fix:** WebSearch is low risk. WebFetch can carry data out in a URL.
  Allow the documentation hosts you use, and leave the rest to prompts
  or the classifier:

  ```zsh
  cp ~/.claude/settings.json ~/.claude/settings.json.bak && jq '.permissions.allow = ((.permissions.allow // []) + ["WebFetch(domain:HOST)"] | unique)' ~/.claude/settings.json > ~/.claude/settings.json.new && mv ~/.claude/settings.json.new ~/.claude/settings.json
  ```

  Do not add `"ask": ["WebFetch"]`. Ask beats allow, so it prompts for
  every fetch, allowed hosts included. To prompt for unlisted hosts
  even in auto mode, a PreToolUse hook on WebFetch can return "ask";
  hook asks prompt in auto mode.
- **Cost:** an allowed host can receive whatever the agent puts in a
  URL.

### Internal services

- **Symptom:** requests to a dashboard, API or database host fail on
  the network.
- **Cause:** the host is not in `allowedDomains`.
- **Fix:** allow the exact host for the need, as in
  [Package installs](#package-installs). Give agents a read-only or
  viewer token for that service, never your own login.
- **Cost:** the agent can read what that token reads, and send data to
  that host.

## The friction loop

Agents record each block in a log. You review the log now and then,
and fix the common ones once. Agents propose; you apply. Treat every
log field as untrusted, since agents wrote it.

1. Create the log folder, and let sandboxed commands write to it:

   ```zsh
   mkdir -p ~/.local/state/agent-friction
   cp ~/.claude/settings.json ~/.claude/settings.json.bak && jq '.sandbox.filesystem.allowWrite = ((.sandbox.filesystem.allowWrite // []) + ["~/.local/state/agent-friction"] | unique)' ~/.claude/settings.json > ~/.claude/settings.json.new && mv ~/.claude/settings.json.new ~/.claude/settings.json
   ```

2. Add the agent rules to your user `CLAUDE.md`. Read
   [`files/claude-md-agent-rules.md`](files/claude-md-agent-rules.md)
   first, and edit it to fit. Its "Sandbox friction" section tells
   agents how to log a block and what fix to propose.

   ```zsh
   cp ~/.claude/CLAUDE.md ~/.claude/CLAUDE.md.bak 2>/dev/null; cat files/claude-md-agent-rules.md >> ~/.claude/CLAUDE.md
   ```

3. Install the triage skill, from
   [`files/skills/sandbox-triage`](files/skills/sandbox-triage/SKILL.md):

   ```zsh
   mkdir -p ~/.claude/skills/sandbox-triage && cp files/skills/sandbox-triage/SKILL.md ~/.claude/skills/sandbox-triage/
   ```

4. Now and then, count the log yourself:

   ```zsh
   cut -f2,3 ~/.local/state/agent-friction/log.tsv | sort | uniq -c | sort -rn
   ```

   Or ask an agent to "triage sandbox friction". The skill proposes
   the narrowest fix for each entry, as a `jq` command for you to run.
   It never applies one.
5. After any settings change, rerun [step 04's checks](04-claude-code-sandbox.md#checks).

## Checks

Start a new agent session. Ask it to run these lines, which write a
test line to a separate file and count it as the triage does:

```zsh
printf '%s\t%s\t%s\t%s\t%s\n' "$(date -u +%F)" write /example/path "$PWD" "2 one allowWrite path" >> ~/.local/state/agent-friction/test.tsv
cut -f2,3 ~/.local/state/agent-friction/test.tsv | sort | uniq -c | sort -rn
```

The count must show 1 for `write` and `/example/path`. If the write fails,
the `allowWrite` entry is missing or a deny cancels it. Then ask the
agent which skills it has: `sandbox-triage` must be one. Delete the
test file afterwards:

```zsh
rm ~/.local/state/agent-friction/test.tsv
```

## Rollback

- Settings: restore your copy,
  `cp ~/.claude/settings.json.before-05 ~/.claude/settings.json`.
- Playwright: `claude mcp remove --scope user playwright`.
- Agent rules: delete the added sections from `~/.claude/CLAUDE.md`,
  or restore `~/.claude/CLAUDE.md.bak`.
- Skill: `rm -r ~/.claude/skills/sandbox-triage`.
- Log: `rm -r ~/.local/state/agent-friction`, after you have read it.
