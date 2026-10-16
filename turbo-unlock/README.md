# turbo-unlock

Clears the BIOS turbo lock at every boot on Debian / Ubuntu / Proxmox VE.

Made for the **Dell Wyse 5070** (Celeron J4105 / Pentium Silver J5005), whose
BIOS sets bit 38 ("turbo disable") of `IA32_MISC_ENABLE` (MSR `0x1a0`). The CPU
then never goes above its base clock of 1.5 GHz. It works on other Intel
machines with the same lock too.

## Install

Run on the machine (the Proxmox host, not a VM), as root:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/jicedtea/misc/main/turbo-unlock/install.sh)"
```

The installer:

1. Checks the CPU is Intel, it is not a VM, and kernel lockdown (Secure Boot)
   does not block MSR writes
2. Installs `msr-tools` if missing and loads the `msr` module
3. Shows the current state: max frequency, how many CPUs have the lock bit set,
   and whether the cpufreq driver has turbo on
4. Writes `/usr/local/sbin/turbo-unlock.sh`, which on every CPU clears bit 38 of
   MSR `0x1a0`, then sets `intel_pstate/no_turbo` to `0` (or
   `cpufreq/boost` to `1` with `acpi-cpufreq`)
5. Writes `/etc/systemd/system/turbo-unlock.service` (oneshot at boot), enables
   it, runs it right away and checks the result

Example on a Wyse 5070:

```
  Machine     : Wyse 5070 Thin Client
  CPU         : Intel(R) Pentium(R) Silver J5005 CPU @ 1.50GHz
  CPU driver  : intel_pstate
  Max freq    : 1500 MHz (now 1500 MHz allowed)
  BIOS lock   : on 4 of 4 CPUs (MSR 0x1a0 bit 38)
  Driver turbo: off
```

Non-interactive:

```bash
bash install.sh install -y
```

## Uninstall

```bash
bash install.sh uninstall
```

Disables and removes the service and the script. Turbo stays on until the next
reboot, and `msr-tools` is kept.

## Notes

- Check the lock bit with `rdmsr -a -f 38:38 0x1a0` (`0` = unlocked) and the
  clock under load with `grep MHz /proc/cpuinfo`.
- With Secure Boot on, kernel lockdown blocks writes to `/dev/cpu/*/msr`.
  Disable Secure Boot in the BIOS first.
- If `intel_pstate` refuses `no_turbo=0` ("turbo disabled by BIOS"), the
  script restarts the driver (`passive` -> `active`) so it reads the MSR
  again, then retries.
- The kernel logs a warning that a tool wrote an unknown MSR. That is expected.
- After suspend / resume the BIOS may set the bit again. Run
  `systemctl restart turbo-unlock` then.
- Turbo makes the CPU hotter. The Wyse 5070 is fanless, so keep the vents free
  and watch the temperature with `sensors`.
- Works together with [cpupower](../cpupower/): the governor decides how often
  the CPU uses the higher clocks.
