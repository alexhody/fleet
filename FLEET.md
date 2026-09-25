# Fleet

Machines that run agents for me, what each is for, and how work moves between
them. Provisioning lives in `setup/<host-kind>/SKILL.md`; this file is the
inventory and the conventions.

## Hosts

Every host is on the personal tailnet, `<tailnet>.ts.net` (`<personal email>`).
Use full MagicDNS names.

### `jupiter-mbp` — control plane

| | |
| --- | --- |
| Tailscale | `jupiter-mbp.<tailnet>.ts.net` (`100.x.y.z`) |
| Hardware | Apple M4 Max, 16 cores, 48 GB |
| Role | **where I prompt from.** Interactive work, anything needing macOS |
| Agents | Claude Code (under cmux), T3 Code, opencode |
| Runtimes | node (fnm), bun, pnpm, uv |

Builds Apple targets: iOS simulators, Xcode and a USB iPhone
(the `argent` workflow) stay here.

### `saturn-mbp` — worker

| | |
| --- | --- |
| Tailscale | `saturn-mbp.<tailnet>.ts.net` (`100.x.y.z`), SSH alias `saturn`, user `saturn` |
| LAN | `<LAN IP>`, SSH alias `saturn-lan`, faster at home |
| Hardware | MacBookPro11,5 (2015), i7-4870HQ 4c/8t, 16 GB |
| OS | Ubuntu 24.04, kernel 7.0 |
| Role | **long-running unattended work.** Always on. |
| Agents | Claude Code, Codex, opencode |
| Runtimes | node (fnm), uv, Docker (off until `dockeron`) |
| Repos | `~/Code/` |
| Setup / fixes | `setup/macbookpro-ubuntu-setup/` (`SKILL.md`, `TROUBLESHOOTING.md`) |
| Health check | `ssh saturn bash -s < setup/macbookpro-ubuntu-setup/scripts/verify.sh` |
| T3 Code | `t3` service (systemd user unit, linger on), reached through T3 Connect |

- Boots to a text console with the network up. `don` starts the desktop, `doff`
  stops it and turns the panel off, `dstat` reports. `dockeron`/`dockeroff`/`dkstat`
  do the same for Docker. None asks for a password.
- Those are shell functions, so over `ssh saturn cmd` use the commands behind them,
  which are also password-free:
  `sudo systemctl enable --now containerd docker docker.socket` (on) and
  `sudo systemctl disable --now docker.socket docker containerd` (off).
- Containers don't come back after a reboot until `dockeron`.
- `/tmp` is RAM and wiped on boot. Job files go in `~/jobs`.
- Browser: Chrome (apt). There are no snaps and `snap install` is blocked.
- A kernel hang reboots it within about 40 s. If it stays unreachable, suspect the
  network: `ssh saturn-lan` skips Tailscale.

### `neptune-mbp` — work worker

| | |
| --- | --- |
| Tailscale | `neptune-mbp.<tailnet>.ts.net` (`100.x.y.z`), SSH alias `neptune`, user `neptune` |
| Hardware | Apple M1 Max, 10 cores, 32 GB |
| OS | macOS 27 |
| Role | **work projects** |
| Agents | Claude Code, Codex |
| T3 Code | `t3` service (launchd, `com.t3tools.t3code.service`), reached through T3 Connect |

- SSH is Tailscale SSH in check mode: no keys, but a login can print a
  `login.tailscale.com` link to approve in the browser first.
- It's a Mac, so unattended work needs it logged in, plugged in and awake. On AC
  it never sleeps (`pmset` `sleep 0`).

## What goes where

Saturn is far slower per core than the M4 Max and throttles under sustained
all-core load, so split by **wall-clock duration, not compute**. Keep default
worker counts (`-j8` beats `-j4` there).

**Saturn:** long agent loops (overnight refactors, migrations), research and
scraping sweeps, I/O-bound integration suites and Docker services, anything that
should keep running while jupiter is closed.

**Jupiter:** simulators and Xcode, builds I'm waiting on, interactive UI work.

One serious job at a time on saturn: worktrees isolate files, not ports, Docker or
databases.

## Connecting

Saturn: key-only SSH over Tailscale or the LAN, plus T3 Connect for T3 Code.
Neptune: Tailscale SSH, plus T3 Connect for T3 Code. Agents on saturn need their own
logins (`claude auth login`, `codex login --device-auth`, `opencode auth login`;
see the setup skill, step 5). Renew before long runs: a session that outlives its
login stops. Never pass `--bare` on a subscription login, since it skips OAuth.

### 1. T3 Code — primary UI

Each worker runs its own T3 server, and agents live inside it, so closing
jupiter doesn't stop them.

- Both workers use T3 Connect, signed in as the personal account
  (`<personal email>`). Each `t3` service opens a Cloudflare tunnel to
  `relay.t3.codes`, so the connection doesn't depend on Tailscale. On jupiter,
  sign in to T3 Connect in Settings → Connections and pick the worker. Check it
  with `t3 service status` and `t3 connect status`.
- To link a new worker, run `t3 connect link --headless` (it prints a device
  code to approve at `accounts.t3.codes`), then `t3 service restart`.
- T3 Connect is also the way back in when Tailscale is down. Its terminal still
  works, so `tailscale login` can run from there.
- `t3 update` on a worker restarts its service and interrupts running turns.
  Update between runs.

### 2. `claude --bg` — detached Claude sessions

```bash
ssh saturn 'cat > ~/jobs/job1.task' <<'TASK'
Prompt text. Quotes, $VARS and pipes survive verbatim.
TASK
ssh saturn 'bash -ls' <<'RUN'
cd ~/Code/<repo>
claude --bg -n job1 --permission-mode auto "$(cat ~/jobs/job1.task)"
RUN
ssh saturn 'bash -lc "claude agents"'              # list with state
ssh saturn 'bash -lc "claude logs <id>"'           # recent output
ssh saturn -t 'bash -lc "claude attach <id>"'      # take over
ssh saturn 'bash -lc "claude stop <id>"'           # --resume still works
```

- Without a permission mode, a prompt pauses the session until someone attaches.
- Each session moves into a git worktree under `.claude/worktrees/` before its first
  edit. Turn that off per repo with `worktree.bgIsolation: "none"`.
- Idle, unattached sessions stop after about an hour; running ones don't.

### 3. tmux + `claude -p` — scripted runs, and Codex or opencode

```bash
ssh saturn 'cat > ~/jobs/job1.sh && chmod +x ~/jobs/job1.sh' <<'JOB'
#!/bin/bash
set -euo pipefail
cd ~/Code/<repo>
claude -p "$(cat ~/jobs/job1.task)" \
  --permission-mode auto --permission-prompts none \
  --max-budget-usd 20 --output-format json
JOB
ssh saturn 'bash -lc "tmux new -d -s job1 \"~/jobs/job1.sh > ~/jobs/job1.log 2>&1\""'
```

- Send tasks and launchers over stdin, as above. One `ssh` command with nested
  quotes mangles the prompt.
- `-p` without `--permission-mode auto --permission-prompts none` can't approve
  anything, so the run changes nothing.
- `--output-format json` returns `result`, `session_id` and `total_cost_usd`.
  `stream-json` needs `--verbose`.
- `tmux ls` is the status check: listed means running; gone means done, with the
  JSON in the log. A killed run resumes with `claude -p --resume <session_id>`.

### 4. Remote Control — watching only

claude.ai/code or the phone app attaches to a session already running on saturn.
It needs a full `claude auth login`, not a `setup-token`.

### Reaching services

UFW allows everything on `tailscale0`, so a dev server on saturn is at
`saturn-mbp.<tailnet>.ts.net:<port>` from jupiter. Anything on the tailnet can reach it too, so
nothing unauthenticated.

## Handoff

Git only. The worker commits to a branch and pushes, and review happens on
jupiter. No sshfs or shared filesystems.

## Deliberately not here

No orchestrator, no Kubernetes, no shared filesystem. Two machines don't need more
than T3 Code and `claude --bg`.
