# ffmpeg-static

Downloads a static build of `ffmpeg` and `ffprobe` and puts it in
`/usr/local/bin`. That directory comes before `/usr/bin` in `PATH`, so the
static build is used instead of the apt `ffmpeg`, which is left installed.
Runs on any Linux (Debian / Ubuntu / Proxmox VE / OpenMediaVault and others).

## Install

Run as root:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/jicedtea/misc/main/ffmpeg-static/install.sh)"
```

The wizard asks for the build and the version, then:

1. Downloads the checksum list and the archive, and checks the SHA-256
   (FFmpeg-Builds) or MD5 (johnvansickle.com)
2. Unpacks it and runs `ffmpeg -version` / `ffprobe -version` before touching
   anything, so a build that does not run here is never installed
3. Copies `ffmpeg` and `ffprobe` to `/usr/local/bin` (copy, then rename: an
   `ffmpeg` that is running keeps working)
4. Writes `/var/lib/ffmpeg-static/state` (source, version, checksum, files),
   used for updates, `check` and `uninstall`

```
  Static FFmpeg for x86_64 (glibc 2.41)

? Which build?
    1) FFmpeg-Builds (BtbN): VA-API, QSV, NVENC / NVDEC, Vulkan (recommended)
    2) johnvansickle.com: fully static, no hardware acceleration, rarely updated
  Choose 1-2 [1]:
? Which version?
    1) Latest release (now 9.0), follows new releases
    2) Git master, daily build: newest features and fixes, less tested
    3) Release branch 8.1 only
  Choose 1-3 [1]:
  Install to [/usr/local/bin]:
```

### Builds

| Source | Architectures | Needs | Hardware acceleration |
|---|---|---|---|
| `btbn`: [FFmpeg-Builds](https://github.com/FFmpeg-Builds/FFmpeg-Builds) (formerly BtbN) | x86_64, aarch64 | glibc 2.28+ (Debian 10+, Ubuntu 20.04+) | VA-API, QSV (libvpl), CUDA / NVENC / NVDEC, Vulkan, OpenCL, AMF |
| `johnvansickle`: [johnvansickle.com/ffmpeg](https://johnvansickle.com/ffmpeg/) | x86_64, i686, aarch64, armhf, armel | nothing (fully static) | none |

`auto` (the default without the wizard) takes FFmpeg-Builds where it runs and
johnvansickle.com otherwise. The FFmpeg-Builds binaries link only against glibc,
so the VA-API / QSV drivers and the NVIDIA libraries of the host are loaded at
run time: install them first (for example with [gpu-drivers](../gpu-drivers/)).
Both are GPL builds (libx264, libx265 and so on included).

johnvansickle.com builds are updated rarely (at the time of writing: release
7.0.2, git master from 2024-06). Use them on 32-bit ARM / x86 or with an old glibc.

### Versions

| `--channel` | Build |
|---|---|
| `release` (default) | Latest FFmpeg release. Moves to the next release branch (9.0 → 9.1) when it comes out |
| `git` | Daily build of the master branch |
| `X.Y`, e.g. `8.1` | Latest build of that release branch only (FFmpeg-Builds, the branches it still builds) |

### Non-interactive

```bash
bash install.sh install -y                          # latest release, auto source
bash install.sh install -y --channel git
bash install.sh install -y --source btbn --channel 8.1
bash install.sh install -y --source johnvansickle
bash install.sh install -y --bin-dir /opt/ffmpeg/bin
```

If `ffmpeg` or `ffprobe` already exists in the bin directory and was not put
there by this script, the wizard asks before replacing it; with `-y` it stops
unless `--force` is given.

## Update

Run the installer again. It keeps the previous source, channel and directory,
compares the checksum of the newest build with the installed one, and only
downloads when it changed (`--force` installs it again anyway).

For a weekly update from cron:

```bash
echo '0 4 * * 1 root bash /path/to/ffmpeg-static/install.sh install -y >/dev/null' > /etc/cron.d/ffmpeg-static
```

## Check

```bash
bash install.sh check
```

Shows the installed build, which `ffmpeg` `PATH` finds (and other copies such
as `/usr/bin/ffmpeg` or Jellyfin's), the hwaccels it was built with and whether
a newer build is out. Changes nothing.

## Uninstall

```bash
bash install.sh uninstall
```

Removes the `ffmpeg` and `ffprobe` this script installed and its state file.
The apt `ffmpeg` (if any) is used again.

## Notes

- Shells that ran `ffmpeg` before the install may keep the old path cached:
  run `hash -r` or open a new shell.
- `ffplay` is not installed: these are headless machines.
