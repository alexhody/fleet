---
name: saturn
description: Use when provisioning, reprovisioning or fixing saturn, the MacBookPro11,5 (2015, i7-4870HQ, 16 GB) Ubuntu 24.04 worker. Runs the generic setup/linux-worker skill, then scripts/hardware.sh for this Mac's quirks (SSD write cap, dGPU off through the gmux, mbpfan, thermald off, battery charge limit, CPU undervolt, Bluetooth/camera/SD reader/Thunderbolt off) and scripts/verify.sh. Trigger on "set up saturn", "reprovision saturn", "saturn broke", "saturn won't boot", "saturn disk errors", "saturn undervolt", "saturn battery".
---

# saturn — MacBookPro11,5 Ubuntu worker

Target: MacBookPro11,5, Ubuntu 24.04 with the HWE kernel, user `saturn`, name
`saturn-mbp`, on the personal tailnet. Always on, for long unattended work
(see `FLEET.md`).

Provisioning follows `setup/linux-worker/SKILL.md` (step 0 first) with
`U=saturn H=saturn`.
This file covers only what differs. Hardware problems are in
`TROUBLESHOOTING.md` here; everything else is in
`setup/linux-worker/TROUBLESHOOTING.md`.

## 1. At the MacBook (once)

Generic step 1. The Wi-Fi interface is `wlp4s0`, so the LAN IP is
`ip -brief addr show wlp4s0`.

## 2. Run setup (from the control laptop)

Generic step 2, then the hardware script, both before the first reboot:

```bash
IP=192.168.x.y                                    # LAN IP from step 1
ssh-copy-id -i ~/.ssh/id_ed25519.pub saturn@$IP
scp setup/linux-worker/scripts/setup.sh setup/saturn/scripts/hardware.sh saturn@$IP:
ssh -t saturn@$IP 'sudo COUNTRY=<cc> bash ~/setup.sh && sudo bash ~/hardware.sh'
```

`hardware.sh` refuses to run on anything but a MacBookPro11,x. It is safe to re-run.

| Option | Effect |
| --- | --- |
| `CHARGE_LIMIT=80` | battery stops charging at this % (default 80, `100` for no limit) |
| `UNDERVOLT_MV=-65` | CPU voltage offset (default -65, `0` for stock) |
| `SKIP_GRUB`, `SKIP_DGPU`, `SKIP_DEVICES` | skip that part |

What it adds on top of the generic setup:

| Area | Result | Files |
| --- | --- | --- |
| Boot | `libata.force=max_sec=2560 intel_iommu=off` added to the cmdline, `noncq-fallback` GRUB entry | `/etc/default/grub`, `/etc/grub.d/40_custom` |
| SSD | I/O capped at 1280 KiB, NCQ on | `/etc/udev/rules.d/60-apple-ssd-max-sectors.rules` |
| dGPU | powered off through the gmux at boot, hidden from GNOME | `/etc/modprobe.d/blacklist-amdgpu.conf`, `/usr/local/sbin/dgpu-off`, `dgpu-off.service`, `/etc/udev/rules.d/72-dgpu-ignore.rules` |
| Thermal/power | mbpfan, `thermald` masked (~18 % faster sustained builds), CPU undervolted 65 mV (skipped for one boot after a crash), battery stops charging at 80 % (set again on every boot) | `/usr/local/sbin/{bclm,undervolt}`, `{battery-limit,undervolt}.service`, `/etc/modprobe.d/msr-writes.conf` |
| Off | Bluetooth (radio and USB controller), camera, SD reader, Thunderbolt (powered down; internal USB devices autosuspend) | `/etc/modprobe.d/{disable-camera,thunderbolt-off}.conf`, `/etc/udev/rules.d/70-{cardreader,bluetooth}-off.rules`, `/etc/udev/rules.d/71-idle-power.rules` |

## 3–6. Tailscale, verify, logins, T3 Connect

Generic steps 3 to 6. The SSH config entry on jupiter:

```
Host saturn
    HostName saturn-mbp.<tailnet>.ts.net
    User saturn
    IdentityFile ~/.ssh/id_ed25519
    UseKeychain yes
    AddKeysToAgent yes
```

Verify with both scripts. Every line must read `ok`:

```bash
ssh saturn bash -s < setup/linux-worker/scripts/verify.sh
ssh saturn bash -s < setup/saturn/scripts/verify.sh
```

Git commits with the personal email from `fleet.local.md`.

## Daily use

Generic step 7, plus:

- On the same LAN, `ssh saturn@saturn-mbp.local` skips Tailscale.
- `doff` turns the panel off through `gmux_backlight`.
- UFW also has a hand-added `OpenSSH ALLOW Anywhere` rule, kept on purpose.
  SSH is key-only, so it's harmless, and the setup scripts don't manage it.
- Under sustained all-core load it throttles, so split work by wall-clock time,
  not compute (see `FLEET.md`).

## What the tuning did (i7-4870HQ, 2015)

Method and dead ends: `setup/linux-worker/TUNING.md`.

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
