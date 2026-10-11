# cpupower

Sets the CPU frequency governor at every boot on Proxmox VE / Debian.

## Install

Run on the node, as root:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/jicedtea/misc/main/cpupower/install.sh)"
```

The installer:

1. Installs `linux-cpupower` if `cpupower` is missing
2. Reads the governors the CPU driver supports
   (`/sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors`) and
   lists them with a short description and the current one marked
3. Writes `/etc/systemd/system/cpupower.service`, which runs
   `cpupower frequency-set -g <governor>` at boot
4. Enables the service, runs it right away and checks every CPU switched

Example on an `acpi-cpufreq` CPU:

```
  CPU driver      : acpi-cpufreq
  Current governor: ondemand

? Governor to set at boot
    1) conservative  raises the frequency gradually with load
    2) ondemand      jumps to high frequency as soon as load rises (current)
    3) powersave     always the lowest frequency: least power, slowest
    4) performance   always the highest frequency: lowest latency, most power and heat
    5) schedutil     follows the scheduler's CPU load: balanced (kernel default)
  Choose 1-5 [2]:
```

The list depends on the driver. `intel_pstate` and `amd-pstate` in active mode
usually offer only `performance` and `powersave`. There, `powersave` does not
pin the lowest frequency, the driver still scales with load. `userspace` is
never offered, since it needs a fixed frequency.

Non-interactive:

```bash
bash install.sh install -y --governor performance
```

Running the installer again changes the governor. The previous choice is the
default.

## Uninstall

```bash
bash install.sh uninstall
```

Disables and removes `cpupower.service`. The current governor stays until the
next reboot, and `linux-cpupower` is kept.

## Notes

- Check the result with `cpupower frequency-info`.
- In a VM there is usually no cpufreq. The installer stops with a message
  instead of writing a service that would fail.
- If `power-profiles-daemon` is running it may change the governor again. The
  service starts after it, and the installer warns when it is active.
- `cpupower.sh` is the original standalone script (always `schedutil`).
  `install.sh` replaces it and writes the same service.
