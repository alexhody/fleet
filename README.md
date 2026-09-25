# fleet

Turn old laptops into always-on workers for AI coding agents (Claude Code,
Codex, opencode), and drive them from your main machine.

This repo holds the setup, written as skills an agent can follow. Point Claude
Code at one and it provisions a machine end to end: power and sleep, SSH and
Tailscale, firewall, toolchain, agent CLIs and remote access through
T3 Code. It's also where fixes for each machine get recorded.

## How it works

- **One control machine** where you work and prompt (a Mac here).
- **Workers** that run long agent jobs unattended, so closing the control
  machine doesn't stop them.
- **Connections:** everything goes over Tailscale. T3 Connect gives each worker
  a UI and terminal that don't depend on Tailscale, and on the same LAN a worker
  is also reachable as `<name>.local`.
- **Handoff is git only:** workers commit and push to branches, and you review
  on the control machine.

`FLEET.md` describes the machines, what runs where, and the daily workflow.

## Layout

```
FLEET.md                 inventory, conventions, how to hand work to a worker
credentials.example.md   template for your private values
setup/
  linux-worker/          any Ubuntu/Debian machine → worker, plus tuning and measuring
  macos-worker/          any Apple Silicon Mac → worker, incl. Xcode and Android
  saturn/                example: 2015 MacBook Pro on Ubuntu (hardware quirks)
  neptune/               example: M1 Max MacBook Pro on macOS (RustDesk server)
```

Each folder has a `SKILL.md` (the steps), a `TROUBLESHOOTING.md` (symptoms,
causes, fixes, undo) and `scripts/` (`setup.sh`, and `verify.sh` to check the
result after a reboot).

## Using it

1. Clone the repo on your control machine and create your private values file:

   ```bash
   cp credentials.example.md credentials.md
   ```

   It's gitignored. Fill in what you know (tailnet, accounts, git identity),
   or leave it and the agent will ask.

2. Ask your agent to follow the skill for the new machine, for example:

   > Set up my old ThinkPad as a worker using `setup/linux-worker/SKILL.md`.

   It reads `credentials.md` first, asks for anything missing in one go, and
   then runs the steps. Passwords and logins are never passed to it: you type
   them at the machine's own prompts or approve them in a browser.

3. For a machine with quirks of its own, add `setup/<host>/` with a `SKILL.md`
   that runs the generic skill and then its extras. `saturn/` and `neptune/`
   show the pattern.

## Requirements

- A control machine with an agent that can run shell commands (Claude Code,
  Codex, …)
- A Tailscale account, and a T3 Code account for T3 Connect
- Workers you can reach over SSH on the LAN for the first run

## Security

- No secrets live in this repo. Personal values go in `credentials.md`, which
  isn't committed.
- SSH is key-only; macOS workers also accept Tailscale SSH. On Linux workers
  the firewall allows everything over Tailscale, and only SSH and mDNS from
  private LAN ranges.
- Linux workers get passwordless `sudo` by design. Treat the workers as
  disposable, and don't give them credentials you can't revoke.
