---
name: linux-worker-tuning
description: Use when turning a laptop or PC (MacBook, ThinkPad, Dell, desktop) into an always-on, headless Linux worker for builds or coding agents, or when such a box idles at high power, throttles under sustained load, freezes, reboots, or logs disk errors. Also use before undervolting, capping power, or changing fans on one.
---

# Tuning a Linux worker

A laptop that runs 24/7 over SSH has three budgets, in this order: **reliability**
(nobody is there to press the button), **idle power** (1 W all month ≈ 0.72 kWh), and
**sustained throughput**. Every tweak is a hypothesis. Most popular ones did nothing
or made things worse when measured.

Worked example with scripts: `setup/macbookpro-ubuntu-setup` (MacBookPro11,5).
Commands for every measurement below: `MEASURE.md` in this folder.

## The loop

1. **Baseline in the same session.** Ambient, paste age and uptime shift results;
   yesterday's number is not a baseline.
2. **Change one thing.**
3. **Measure the metric that moves**, repeated: package C-state residency for idle,
   steady-state clock for load. One wall-clock build is noise (±1.5 % run to run).
4. **Reboot, then verify** with a checks script. A tweak that doesn't survive a
   reboot isn't done.
5. **Write down what you kept and what you rejected, with numbers**, so nobody
   retries a dead end.

## Order of work

1. **Can't lose the box.**
   - Two SSH paths (Tailscale plus a LAN alias), key-only.
   - Never sleeps: mask `sleep.target`/`suspend.target`/`hibernate.target`, and set
     logind to ignore the lid.
   - Open or closed lid is a measured choice, not a default. An ignored lid can
     leave the panel lit, and many laptops (MacBooks among them) vent at the hinge,
     so a closed lid traps heat. Compare full-load temperatures both ways, and keep
     it closed only if that costs nothing and the panel reads off (`dpms`).
   - Recovers by itself: `kernel.panic=10`, plus panic on oops, soft lockup, hard
     lockup and hung task (a hang without an oops never reboots otherwise).
     Add the hardware watchdog (`RuntimeWatchdogSec`) if `wdctl` finds one.
   - Keep the crash dumps (pstore), and clear them from EFI NVRAM once archived.
   - Set the BIOS to power on after AC loss where it offers that. Test the whole
     chain once with a sysrq crash. Testing AC-loss recovery needs someone at the
     socket, so do it before the box goes remote.
2. **Prove the disk.** Before tuning anything, run sustained writes with a
   read-back check (fio crc32c) and grep the kernel log for ATA/NVMe errors. Read
   SMART. New kernels break old controllers: 7.0 raised the maximum I/O size and an
   Apple SSD started throwing host bus errors until it was capped.
3. **Idle power: chase the package C-state, not watts.** If the package never
   reaches PC6 or deeper, something is holding it. Usual blockers:
   - a lit panel (with the lid ignored it stays on): `consoleblank=60`, or boot
     to a text console;
   - an awake dGPU. On a PC, use the driver's runtime D3 if it has one:
     amdgpu and nouveau do it by default, and NVIDIA Turing and newer need
     `NVreg_DynamicPowerManagement=0x02`. For older NVIDIA (Pascal and before) and
     anything else, bind no driver and set the
     device's `power/control` to `auto`. Either way `power_state` must leave `D0`
     and the package must reach PC6. A Mac uses the gmux (see the saturn skill);
   - a controller whose driver keeps it powered (Thunderbolt: blacklist and
     runtime-suspend it);
   - internal USB devices that never autosuspend.
   Did nothing on saturn: ASPM `powersave`, runtime PM on everything else, SATA
   LPM. Wi-Fi power save also did nothing, and it adds latency.
4. **Throughput: find the limiter before changing anything.** Read the CPU's
   throttle-reason register during load (`MEASURE.md`). Temperatures alone can't
   tell you which limit is active.
   - **Heat at Tjmax:** repaste and clean old machines, undervolt, keep the lid open
     if the vents are at the hinge.
   - **PL1/PL2:** raise only if the cooling holds.
   - **PROCHOT:** find the cause (charger, VRM, sensor). Don't disable it.
   Measured slower or no gain: RAPL power caps, `thermald` without OEM tables, the
   `performance` governor, earlier fan curves (check whether the fans are already
   at max).
5. **Housekeeping, cheap and safe:** zram swap, `noatime`, tmpfs `/tmp`, raised
   inotify limits, BBR + `fq` (big win on Wi-Fi), remove snapd and unused services,
   boot to a text console, cap the battery charge and re-apply it at every boot.

## What it did on saturn (i7-4870HQ, 2015)

| Change | Result |
| --- | --- |
| dGPU off (gmux) | Idle 24 → 15 W at the wall |
| Panel blanked, Thunderbolt off, USB autosuspend | Idle 13.3 → 6.1 W DC, PC2 → PC6 96 % |
| SSD I/O capped at 1280 KiB | Host bus errors gone, NCQ kept |
| `thermald` masked | Builds 18 % faster |
| Repaste (11-year-old paste) | Builds 137 → 128–131 s, idle 43 → 34 °C |
| Undervolt −65 mV | Full-load clock +5 %, one thread −1.8 W |
| BBR + `fq` | Wi-Fi upload lag 160 → 100 ms |
| RAPL cap 30–35 W | Builds 5–13 % slower (rejected) |

## Undervolting safely

- **Check support first:** write an offset and read it back.
  - Intel 4th–5th gen: works.
  - Intel 6th–10th gen: depends on the BIOS version. Plundervolt updates often lock
    it, and some BIOSes can unlock it.
  - Intel 11th gen and newer: mostly locked.
  - AMD: no MSR 0x150; use the BIOS Curve Optimizer or `ryzenadj` where available.
- **Sweep in 25 mV steps.** Each step runs: a 1-thread verify at top turbo, 5 min
  of mprime, an all-thread verify. Stop at the first error.
- **Soak the deepest passing offset for at least 2 h:** mprime, idle, partial
  load, and a real build hashed against a stock-voltage build. Silent errors don't
  crash; they corrupt output. Disable LTO and exclude timestamped objects so the
  build is reproducible.
- **Deploy 10 mV shallower than the soaked value** (−65 after soaking −75),
  through a boot service that stays at stock for one boot after any crash, so a
  bad offset can't loop.
- **Expect about 5 % more clock** at the thermal limit, not miracles.

## Common mistakes

- **Treating `thermal_throttle/*_count` as lost speed.** It counts limit hits; read
  the clock and the throttle reasons instead.
- **Measuring idle right after touching the box.** A woken panel read 12.5 W
  instead of 6.1.
- **Comparing against a baseline from another day** or from a single run.
- **Firmware-held settings silently reset.** An SMC reset or a battery unplug
  (repaste) puts the charge limit back to 100 %. Re-apply such settings at boot and
  check them in the verify script.
- **Remote-shell traps:**
  - `pgrep -f pattern` inside `ssh host '…'` matches its own command, so the loop
    never ends;
  - macOS `head -n -N` doesn't exist;
  - an unquoted `~` expands on the client;
  - `sync` before driver swaps or crash tests, because a panic loses unflushed
    logs.
