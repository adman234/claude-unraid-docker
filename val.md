# MOVA P10 Pro Ultra + Valetudo — random factory resets

Research notes, 2026-09-21/22. Robot: **MOVA P10 Pro Ultra = `dreame.vacuum.r2491`**
(Allwinner MR813 "gen3", NAND, A/B partitions, secure boot).

**Symptom:** robot wipes itself — Valetudo binary, config, map, room names, voice pack all
gone — multiple times per week, often during or around cleaning cycles.

---

## 1. Research caveat, read this first

Nearly every search result circled back to **`adman234/valetudo-restore`** (this user's own
repo). Search engines were paraphrasing that README back as if it were independent
corroboration. Treat the findings below as:

- one well-documented first-party analysis (the repo), plus
- a separate, older, widely-repeated maintainer explanation (Hypfer), plus
- a set of adjacent cases from Valetudo GitHub discussions.

There is **no independent public write-up of the `monitor.sh` two-strike ladder**. As far as
the open web goes, this repo is the only documentation of it.

Domains blocked by the session egress proxy (worked from search excerpts / GitHub mirrors
instead): `valetudo.cloud`, `builder.dontvacuum.me`, `dustbuilder.dontvacuum.me`,
`nimbus.cleaning`, `deepwiki.com`, `forum.dreametech.com`, `us.forum.mova-tech.com`,
`vacuumwars.com`, `manuals.plus`.

---

## 2. Two competing mechanisms

### Mechanism A — the `ava` watchdog ladder (fits the symptoms)

From reverse-engineering in `valetudo-restore`:

`/etc/rc.d/monitor.sh` runs `check_ava_alive()`.

| Step | Condition | Action |
|---|---|---|
| Strike 1 | `/data/ava_reboot_cnt` reaches 3, `/data/sys_auto_reboot.mark` **absent** | touch mark, reboot |
| Strike 2 | counter reaches 3 again, mark **present** | `factory_reset.sh monitor_rescue_brick` → `rm -rf /data/*` |

The mark is cleared **only** by a 03:00 cron (`/usr/bin/check_restart_ava.sh`), and **only if
the robot is idle and responsive at that moment**. Busy or unhealthy at 03:00 → the mark
survives indefinitely. That is why wipes look random.

`factory_reset.sh` does:

```sh
rm -rf /data/*  /data/.common  /mnt/misc/config.tar.bz2
tar -xjf ${FACTORY_RESET_PKG} -C /data/
```

`monitor_rescue_brick` is a literal argument in the firmware, not a description of disk damage.

**Why it lands "during cleaning":** the wipe isn't triggered by cleaning. It's triggered by the
strike-2 reboot, which lands whenever `ava` next fails — and `ava` is most loaded during a
clean. Observed wipe times of 17:17 and 12:15 confirm it isn't tied to the nightly window.

Rootfs is read-only squashfs, so `monitor.sh` and `factory_reset.sh` cannot be edited in place.

### Mechanism B — ext4 corruption on `/data` (the publicly documented one)

Hypfer's standing explanation across several threads: on NAND/eMMC Dreames the ext4 fs on
`/data` corrupts, the firmware fails to mount it during the daily 03:00–05:00 reboot, recreates
the filesystem, and Valetudo (which lives on `/data`) vanishes with it. Explicitly *not*
Valetudo's fault — happens on stock firmware and with read-only mounts. Partially mitigated in
DustBuilder images since ~Aug 2022.

### Telling them apart

After a wipe, run `tune2fs -l` on the `/data` device:

- low mount count + fresh "Filesystem created" timestamp → **Mechanism B** (new fs)
- unchanged creation date, data gone → **Mechanism A** (`rm -rf` on an intact fs)

Presence of `/data/log/factory_reset.log` also points at A.

---

## 3. Why `ava` keeps crashing — candidates, ranked

1. **Bad state inside `/data` itself.** Strongest evidence: the 2026-08-31 wipe cleared a crash
   loop *instantly*. The poison was in `/data`, not hardware or rootfs. Prime suspects: the
   persistent map set (`/data/ri`, `/data/map`, `/data/DivideMap`,
   `/data/config/ava/mult_map.json`) or vendor config under `/data/config/ava`.

2. **MCU firmware mismatch.** Documented cause of crash-on-clean on the D9 (discussion #1556):
   robot dies within 5–30 s of starting a clean, unreachable. Fix sequence was
   `install-manual.sh` → reboot → `install.sh` → reboot → `install-mcufw.sh` → reboot. There is
   no way to read the MCU version from Linux, so this is test-by-applying.

3. **Filesystem / flash-level trouble.** Feeds both mechanisms. `/data` full, inode exhaustion,
   or bad blocks will make `ava` fail health checks. Discussion #1995 had `df -h` at 100% and
   "file system is not writeable".

4. **Memory pressure.** Probably *not* the cause: Valetudo sets its own OOM score high so the
   kernel kills **it** before `ava`, and self-terminates above 1/3 of system RAM (both added in
   2021.07.0 for the low-RAM D9). If `ava` is the thing dying, Valetudo is likely innocent.

5. **Hardware.** On #2303 (L10 Pro crash-on-clean) Hypfer concluded hardware/battery age from
   UART logs showing `sunxi verify rootfs fail, reboot` and `Item0 (Map) magic is bad`. A
   degrading battery browning out under vacuum+mop load mid-clean fits the pattern. This robot
   family isn't clean either — the X40 Ultra (not Master) had a known line-laser defect.

6. **Firmware version.** Newer builds for X/L40 Ultra/Master + MOVA P10 Pro Ultra are on
   DustBuilder, with obstacle-avoidance model updates and "probably logic changes".

### ⚠ The feedback loop

If a wipe fixes the crash and the restore puts the poisoned map/config straight back, the next
wipe is re-armed. **A weekly cadence is exactly what that loop looks like.**

**Test:** next wipe, restore identity + config but **not the map**. Run a week on a freshly
built map. If the wipes stop, the backup set contains the bug.

---

## 4. Diagnostics

### Early warning — converts "random" into "predictable"

```sh
ls -la /data/sys_auto_reboot.mark /data/ava_reboot_cnt
cat /data/ava_reboot_cnt 2>/dev/null
```

If the mark file exists, **you are one `ava` failure away from a wipe.** Poll every few minutes
and ship the result off-robot.

### After a wipe

```sh
cat /data/log/factory_reset.log        # only the latest entry survives
tune2fs -l $(findmnt -no SOURCE /data) # Mount count + Filesystem created
```

### Ongoing health

```sh
df -h /data; df -i /data
free -m
dmesg | grep -iE 'ext4|oom|mmc|nand|ubi|error'
uptime                                 # catch silent strike-1 reboots
ls -la /data/log/
```

Strike-1 reboots are silent and are the leading indicator. If `uptime` keeps resetting, strikes
are accumulating.

### Boot / slot logging (ship off-robot — anything in `/data` dies with the wipe)

```sh
date; cat /proc/cmdline; uptime
cat /data/ava_reboot_cnt 2>/dev/null
ls -la /data/sys_auto_reboot.mark 2>/dev/null
```

---

## 5. Mitigations

### The recommended one — periodic mark clearing

The rejected directory-guard failed because making the mark a directory makes
`[ ! -f $SYS_AUTO_REBOOT ]` always true, so the firmware takes the reboot branch forever
(observed: reboot every ~194 s for days).

Better: **don't break the test, clear the mark.** Cron on the robot, every 5–15 min:

```sh
rm -f /data/sys_auto_reboot.mark
```

Same thing the 03:00 job does, minus the idle-and-responsive precondition that keeps failing.

- **Intermittent case** (two unrelated `ava` hiccups days apart compounding into a wipe — what
  "works fine, wipes weekly" looks like): prevents the wipe outright; strike-1 reboots still
  work normally. Strictly better than 03:00-only clearing.
- **Genuine crash loop**: degrades to the same reboot loop as the directory guard. Pair with a
  kill-switch — stop clearing if the mark is seen N times in an hour — and let the wipe happen,
  per the repo's own conclusion.

The cron lives in `/data`, so it dies with each wipe. Reinstall it from `_root_postboot.sh`
(which the restore already rebuilds from `/misc/_root_postboot.sh.tpl` on the read-only rootfs).

### Also worth doing

- Run the MCU firmware update sequence — cheap, and it's the one confirmed fix for crash-on-clean.
- Rebuild on the newest DustBuilder image for the P10 Pro Ultra.
- **Selective restore**: split into "identity + config" (always) and "map" (opt-in), so the
  poisoned-map loop can be broken without giving up the rest.
- Check battery health in the vendor app before more rooting-side theories.

---

## 6. Reflash procedure — fresh DustBuilder firmware with Valetudo prepackaged, over SSH

Hypfer's "just flash a fresh dustbuilder firmware with valetudo prepackaged via ssh".

**Scope:** reflashes **kernel + rootfs only**. `install.sh` does not touch `/data`. If the
trigger is poisoned `/data` state, this alone won't stop the wipes — but it's where an `ava`
bug fix would live.

### 6.0 Pre-flight (on the robot, over SSH)

```sh
# Device identity — IRREPLACEABLE. Verify before anything else.
ls -la /mnt/private/          # expect: did, key, sn, mac, cpuid

# Current slot, and free space
cat /proc/cmdline
df -h /mnt/data /data /tmp
```

Pull a **fresh** `/mnt/private` + `/mnt/misc` backup to the workstation — run `valetudo-restore`
manually now, don't trust last night's. Note the current firmware version
(Valetudo UI → System Information).

### 6.1 Build the image

On `dustbuilder.dontvacuum.me`, target `dreame.vacuum.r2491`, select:

- **"Build for manual installation (requires SSH to install)"**
- **Prepackage Valetudo** ✅
- **Patch DNS** ✅

A `.tar.gz` link arrives by email. **The email also links a howto generated for the exact model
and build — that is authoritative, follow it over these notes if they disagree.**

### 6.2 Install — first pass (robot docked)

```sh
cd /mnt/data
rm -f rootfs.img boot.img *_fw.tar.gz
wget '<url from the dustbuilder email>'
tar -xzvf dreame.vacuum.r2491_fw.tar.gz
./install.sh
```

Writes the **passive** slot, marks it active, reboots itself. Do not cut power.

### 6.3 Install — second pass

```sh
cd /mnt/data
./install.sh
```

No re-download — the extracted images are still in `/mnt/data`.

### 6.4 Clean up

```sh
cd /mnt/data
rm -f rootfs.img boot.img *_fw.tar.gz
```

### 6.5 Verify

```sh
uptime
cat /proc/cmdline                 # confirm the slot flipped
ls -la /data/_root_postboot.sh    # the ONLY thing that starts Valetudo
```

Then restore — **skipping the map** on this pass, per §3.

### Fallbacks and risks

- **`install.sh` refuses the image** (vendor OTA tool rejecting rooted firmware, reported on
  several Dreames) → use the `dd`-based `./install-manual.sh` from the same tarball. Two-pass
  rule still applies.
- **Recovery path:** on gen3 secure-boot hardware a failed flash needs Breakout PCB + FEL. Have
  the PCB to hand before starting.
- **Don't factory-reset first.** Buys nothing, costs Valetudo + Wi-Fi.

> The verbatim A/B + `/mnt/data` + `install.sh` sequence was read from
> `dgiese/dustbuilder-howto` → `nand/installer/_howto.html` on GitHub. **That specific file is
> the Roborock NAND howto** — its Valetudo section (`valetudo-armv7-lowmem`,
> `/mnt/reserve/_root.sh`) is Roborock-specific and **wrong for Dreame**, so it was dropped. The
> Dreame steps are corroborated via search excerpts of the Valetudo firmware-updates and Dreame
> installation pages.

---

## 7. A/B slots — what they are, and whether a missed second pass matters

The robot carries **two complete copies of the OS** (kernel + rootfs), slots A and B. One is
booted, the other idle. The installer never writes the live slot — you can't safely overwrite a
running rootfs, and a power cut mid-write would leave no working copy. So it writes the **idle**
slot, flips the bootloader pointer, and reboots.

| | slot A | slot B |
|---|---|---|
| Before | **active**, old fw | passive, old fw |
| After pass 1 | passive, old fw | **active**, new fw |
| After pass 2 | passive, new fw ✅ | **active**, new fw ✅ |

### Does it matter if pass 2 was never run?

**Day to day, no.** The passive slot is inert; nothing reads it in normal operation. Plenty of
people root once, never run pass 2, never notice.

The risk is conditional:

- **Bootloader fallback.** If the active slot fails enough boot attempts, the bootloader flips
  to the other one — silently, no error. Most people never hit this. **This robot reboots under
  a watchdog repeatedly**, which is exactly the boot churn that can walk a bootloader into
  fallback. If the stale slot holds stock firmware, Valetudo simply doesn't start (nothing on
  stock executes `/data/_root_postboot.sh`) and the robot goes looking for the vendor cloud —
  presenting as "Valetudo vanished", indistinguishable at a glance from the wipe.
- **The next update.** `install.sh` writes whatever is passive. If that's still the stale slot,
  you keep updating the copy you aren't using and never converge.

### Version-skew hypothesis (speculative, testable)

If the slots hold different firmware versions, flipping swaps the `ava` binary while `/data`
stays put. Newer `ava` writes the map → fallback → older `ava` reads a format it doesn't fully
understand → health checks fail → `ava_reboot_cnt` hits 3 → mark set → one strike from
`rm -rf /data`.

**Limit, stated plainly: a slot rollback by itself does not wipe `/data`.** The
`factory_reset.log`, missing voice pack and gone map are the watchdog's `rm -rf`, not a
rollback. So this can't be the whole story — it's a confound that might be *feeding* the crash
loop, and it's cheap to eliminate.

### What to do

Just run the second pass — one reboot, and the question becomes moot. First, check whether
rollbacks have been happening:

```sh
cat /proc/cmdline
cat /proc/partitions
ls -la /dev/block/by-name/ 2>/dev/null
```

Don't assume partition names — discover them from those three. Then log the slot every boot
(see §4) off-robot. Slot value changing between boots = rollback caught in the act. Never
changing across weeks of watchdog reboots = drop this line, go back to the map-poisoning theory,
which the 2026-08-31 evidence supports best.

---

## 8. Sources

| Source | Relevance |
|---|---|
| [adman234/valetudo-restore](https://github.com/adman234/valetudo-restore) | The `monitor.sh` two-strike analysis, backup/restore tool, diagnostics capture |
| [#1556 — D9 crashing when starting a clean](https://github.com/Hypfer/Valetudo/discussions/1556) | Closest symptom match; MCU firmware too old; full fix sequence |
| [#2303 — L10 Pro "crashes" when attempting to clean/map](https://github.com/Hypfer/Valetudo/discussions/2303) | Crash-on-clean diagnosed as hardware via UART logs |
| [#1995 — Dreame L10 not accessible](https://github.com/Hypfer/Valetudo/discussions/1995) | Mechanism B; `/data` 100% full; SSH + DustBuilder recovery |
| [#2410 — Valetudo uninstalled itself](https://github.com/Hypfer/Valetudo/discussions/2410) | Z10 Pro; Hypfer's canonical ext4-corruption explanation |
| [#1165 — Cleaning seems to crash with D9](https://github.com/Hypfer/Valetudo/issues/1165) | Bogus "wheel blocked"/"brush blocked" on crash; closed unresolved |
| [#2504 — X40 Ultra reboot loop](https://github.com/Hypfer/Valetudo/discussions/2504) | Same generation; turned out to be a botched flash |
| [#2484 — Persistent maps suddenly not working](https://github.com/Hypfer/Valetudo/discussions/2484) | Map-state corruption; disable/re-enable persistent maps |
| [pkoehlers/maploader](https://github.com/pkoehlers/maploader) | Swaps the full map set and restarts `ava` — useful for testing map-as-poison |
| [SisyphusMD/dreame-valetudo](https://github.com/SisyphusMD/dreame-valetudo) | Model table confirming **Mova P10 Pro Ultra = R2491**, gen3/MR813 fastboot |
| [dgiese/dustbuilder-howto](https://github.com/dgiese/dustbuilder-howto) | A/B installer howto (Roborock NAND variant — see §6 caveat) |
| [Dreame forum: "Setzt sich selbst in Werkseinstellung zurück"](https://forum.dreametech.com/de/forum.php?mod=viewthread&tid=3369) | X50 Ultra self-reset on **stock** firmware — evidence this isn't Valetudo-caused |
| [MOVA forum: P10 Pro Ultra mapping confusion since update](https://us.forum.mova-tech.com/forum.php?mod=viewthread&tid=1592) | Exact model, stock firmware, map instability after an update |
| [Valetudo firmware updates](https://valetudo.cloud/pages/usage/firmware-updates/) · [Dreame installation](https://valetudo.cloud/pages/installation/dreame/) | Official SSH-reinstall path (read via search excerpts) |

**Best place to ask:** the `dust_announce` Telegram channel is where dgiese/Hypfer actually do
support for this generation; GitHub Discussions second. With `monitor.sh` reverse-engineered, a
Valetudo discussion documenting the two-strike ladder would likely draw out other P10/X40 owners
seeing the same thing — right now there is nothing public for them to find.
