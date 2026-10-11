# Linux Voice Assistant on Raspberry Pi with ReSpeaker 4‑Mic — Installation & Configuration Guide

The ReSpeaker 4‑Mic Pi HAT uses the **AC108** codec, which has **no mainline
kernel driver**. Its audio stack therefore needs the out‑of‑tree
`seeed-voicecard` driver (AC108 codec + platform glue), built **against the
exact running kernel** of the target device. A per‑kernel build on each Pi is
not practical, so this project ships a small **ko‑server**: a container on any
always‑on x86 machine that cross‑compiles the driver once per kernel version
and serves the resulting `.ko` files to the Pi over HTTP.

```
+--------------------------+            +---------------------------------+
| x86 build server (Docker)|            | Raspberry Pi (target)           |
|  /ko-server/ (API, :8000)|            |  respeaker2mic/                  |
|  /opt/kern618  (kernel)  |<-----------|  install-4mic-drivers.sh         |
|  /opt/seed-v614 (driver) |   GET .ko  |  check-driver.sh                 |
|  /opt/ko/modules/<kver>/ |            |  /lib/modules/$(uname -r)/extra/  |
+--------------------------+            +---------------------------------+
```

## Components

| Path | Purpose |
| --- | --- |
| `ko-server/main.py` | FastAPI service: health, module list/download, on‑demand builds. |
| `ko-server/build_module.sh` | Cross‑builds `snd-soc-ac108`, `snd-soc-seeed-voicecard` and `snd-soc-wm8960` against a prepared kernel tree. |
| `ko-server/Dockerfile` | Ubuntu 24.04 image with the aarch64 toolchain + venv (FastAPI/uvicorn). |
| `respeaker2mic/install-4mic-drivers.sh` | Pi‑side installer: i2c probe, download, overlay, ALSA config, live bring‑up. `--uninstall` reverts it. |
| `respeaker2mic/check-driver.sh` | Non‑invasive health check for the 2‑Mic and 4‑Mic stacks (also run automatically by `script/update_lva`). |
| `respeaker2mic/seeed-4mic-voicecard-overlay.dts` | Device‑tree overlay (AC108 at i2c `0x3b`, 4‑channel TDM on the Pi I2S). |
| `respeaker2mic/asound_4mic.conf` | ALSA defaults for the 4‑mic card. |

## 1. The build server (one‑time setup)

### 1.1 Prepare the kernel tree

The server needs the **full source** of the target Raspberry Pi kernel,
configured for `arm64` (the `rpi-v8` flavour) and prepared
(`make olddefconfig && make prepare`), so that out‑of‑tree modules can be
built against it without rebuilding the kernel. The tree's release string
(`uname -r` of the target, e.g. `6.18.50+rpt-rpi-v8`) must match what the Pi
reports — `build_module.sh` refuses to build for a mismatched tree.

```bash
# On the x86 server, as root. Kernel source: the distro's -source package or
# the Raspberry Pi kernel source. Example layout (matches the Dockerfile):
/opt/kern618        # prepared kernel tree (rpi-v8, arm64)
/opt/seed-v614      # seeed-voicecard driver source (patched for the kernel)
```

Checklist for a usable tree:

- `.config` configured for `arm64` (a fresh `rpi-v8` defconfig);
- `Module.symvers` present (extract it from the distro `linux-headers`
  package of the same release — it carries the modpost CRCs);
- `scripts/` generated (`make prepare`);
- the tree's `kernelrelease` equals the target's `uname -r`.

> **Warning:** never run bare `make`/`make -p` in the tree without
> `ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-`. A reconfigured (x86)
> `.config` silently breaks the build with wrong‑arch flags.

### 1.2 Run the server

```bash
cd ko-server
docker build -t lva-ko-server .
docker run -d --name lva-ko-server \
  -p 8000:8000 \
  -v /opt/kern618:/opt/kern618:ro \
  -v /opt/seed-v614:/opt/seed-v614 \
  -v /opt/ko:/opt/ko \
  lva-ko-server
```

Environment variables (all optional, shown defaults):

| Variable | Default | Meaning |
| --- | --- | --- |
| `KO_BASE` | `/opt/ko` | Root for built modules (`<KO_BASE>/modules/<kver>/*.ko`) and build jobs. |
| `KERNEL_SRC` | `/opt/kern618` | Prepared kernel tree. |
| `SEEED_SRC` | `/opt/seed-v614` | seeed-voicecard driver source. |
| `BUILD_SCRIPT` | `/ko-server/build_module.sh` | Build entry point. |

### 1.3 API

| Endpoint | Description |
| --- | --- |
| `GET /health` | Liveness + toolchain presence (cross‑compiler, kernel source, driver source, build script). |
| `GET /modules` | List of built `.ko` files with size and sha256. |
| `GET /modules/{version}.ko` | Download the platform driver (`snd-soc-seeed-voicecard.ko`) for `version`. |
| `GET /modules/{version}/{filename}` | Download any built module, e.g. `snd-soc-ac108.ko`. |
| `POST /build` | `{"kernel_version": "6.18.50+rpt-rpi-v8"}` — queues a build (or answers `cached` if already built). `{"force": true}` rebuilds. |
| `GET /builds/{job_id}` | Job status: `queued` / `done` / `failed`, artifact list, log tail. |

The kernel version may contain `+` (e.g. `6.18.50+rpt-rpi-v8`); it is served
both raw and percent‑encoded (`%2B`).

First build:

```bash
curl -X POST http://192.168.2.225:8000/build \
  -H 'Content-Type: application/json' \
  -d '{"kernel_version": "6.18.50+rpt-rpi-v8"}'
# -> {"job_id": "20261011...", "status": "queued", ...}
curl http://192.168.2.225:8000/builds/<job_id>
```

When the job reports `done`, the Pi can install.

## 2. Install on the Pi

```bash
cd ~/linux-voice-assistant
chmod +x respeaker2mic/install-4mic-drivers.sh
sudo respeaker2mic/install-4mic-drivers.sh
```

Options:

| Option | Meaning |
| --- | --- |
| `--ko-server URL` | Base URL of the ko‑server (default: `http://192.168.2.225:8000`, overridable with the `KO_SERVER_URL` env var). |
| `--allow-local-build` | If the server has no module for `$(uname -r)`, build locally instead of failing. Source locations are auto‑detected or set via `SEEED_SRC` (driver source) and `KERNEL_SRC` (prepared kernel tree). |
| `--uninstall` | Remove everything the installer added. |

What it does:

1. Installs `i2c-tools`, `device-tree-compiler`, `curl`, `alsa-utils`; enables
   i2c for this session and the next boot.
2. Probes i2c bus 1 for the AC108 at `0x3b`; aborts if absent.
3. Downloads `snd-soc-seeed-voicecard.ko` and `snd-soc-ac108.ko` for
   `$(uname -r)` from the ko‑server (or builds them locally with
   `--allow-local-build`).
4. Installs the modules into `/lib/modules/$(uname -r)/extra/seeed-voicecard/`,
   runs `depmod`, and registers both modules in `/etc/modules`.
5. Compiles the overlay with `dtc`, installs the `.dtbo` and appends
   `dtoverlay=seeed-4mic-voicecard`, `dtparam=i2s=on` and
   `dtoverlay=i2s-mmap` to `config.txt`.
6. Installs `/etc/voicecard/asound_4mic.conf` and points `/etc/asound.conf`
   at it — **unless** a 2‑mic install owns it, in which case it leaves the
   2‑mic card as default (see below).
7. Tries to bring the card up live (module load + `dtoverlay`); otherwise it
   asks for one reboot.

The ALSA card ID is **`seeed4micvoicec`**:

```bash
aplay -l | grep seeed4micvoicec
arecord -D plughw:CARD=seeed4micvoicec -f S16_LE -r 48000 -c 4 -d 5 /tmp/t4mic.wav
aplay /tmp/t4mic.wav
```

## 3. Coexistence with the 2‑Mic HAT

Both HATs can be installed on the same Pi (different i2c addresses: 2‑mic at
`0x1a`/`0x18`, 4‑mic at `0x3b`). Ownership rules:

- The **2‑mic installer** owns `/etc/asound.conf` (pointing at
  `asound_2mic.conf`). The **4‑mic installer never overwrites it**; when a
  2‑mic install is detected, LVA must select the 4‑mic card **by name**
  (`seeed4micvoicec`) in its audio configuration.
- The shared boot settings (`dtparam=i2c_arm=on`, `dtparam=i2s=on`,
  `dtoverlay=i2s-mmap`, the `i2c-dev` module entry) are added idempotently by
  both installers.
- **Uninstalling one never breaks the other:**
  - `install-4mic-drivers.sh --uninstall` removes only the 4‑mic dtoverlay,
    `.dtbo`, modules, `asound_4mic.conf` (and the 4‑mic `/etc/asound.conf`
    symlink if present) — the 2‑mic config and shared dtparams are left alone.
  - `install-respeaker-drivers.sh --uninstall` detects a coinstalled 4‑mic
    HAT and, when present, keeps `dtparam=i2c_arm=on`, `dtparam=i2s=on`,
    `dtoverlay=i2s-mmap`, the `i2c-dev` entry and the 4‑mic ALSA files, and
    re‑points `/etc/asound.conf` at the 4‑mic config instead of dropping it.
    Without a 4‑mic HAT it reverts everything to the fresh‑image state.

## 4. Health check

```bash
respeaker2mic/check-driver.sh            # human output
respeaker2mic/check-driver.sh --json     # machine output
respeaker2mic/check-driver.sh --quiet    # exit code only (0 = healthy)
```

It inspects only (no module load/unload): a HAT is "present" when its ALSA
card is registered or its i2c address answers; it is "healthy" when its card
is up. `script/update_lva` runs the quiet check after every update and prints
guidance (without failing the update) if an attached HAT is unhealthy.

## 5. Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| `ko-server has no module for <kver>` on the Pi | Trigger a build on the server (`POST /build` with the Pi's `uname -r`), wait for `done`, re‑run the installer. Or use `--allow-local-build` with `SEEED_SRC`/`KERNEL_SRC` set. |
| `POST /build` → `503 toolchain not ready` | `GET /health` shows which piece is missing: aarch64 cross‑compiler (apt `gcc-aarch64-linux-gnu`), kernel source tree, driver source, or build script mount. |
| Build fails with a wrong‑arch error or `mcount` flags | The kernel tree's `.config` was reconfigured for the wrong arch. Reconfigure with `make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig`, restore `Module.symvers`, `make prepare`, then rebuild. |
| `ERROR: kernel tree release 'X' != requested 'Y'` | The prepared tree does not match the Pi's running kernel. Prepare a tree for the exact `uname -r`. |
| `no AC108 codec at 0x3b on i2c bus 1` | HAT not seated, i2c bus off (reboot after first run adds `dtparam=i2c_arm=on`), or another device occupies `0x3b`. |
| Module loads but `seeed4micvoicec` never appears | Vermagic mismatch — the `.ko` was built for a different kernel than `uname -r`. Rebuild for the exact running version (the server serves per‑version directories, so an old kernel after a distro upgrade simply needs one more build). |
| Card appears as `plughw` but no audio | Check the 4‑mic mixer: `amixer -c seeed4micvoicec` (capture paths must be unmuted). The overlay provides a 24 MHz MCLK; if `aplay -l` shows the card but capture fails, verify the HAT is fully seated. |
| `i2cdetect` shows `UU` at `0x3b` | A driver already claims the address (module loaded from a previous attempt). `modprobe -r snd-soc-ac108` then re‑probe, or simply proceed — the installer treats `UU` as "present". |
| Audio broke after removing the 2‑Mic HAT | A 4‑mic HAT is still installed: the 2‑mic uninstall intentionally kept the shared settings. Remove the 4‑mic HAT too with `install-4mic-drivers.sh --uninstall`, then reboot. |

## 6. Uninstall

```bash
# Remove the 4‑Mic driver (2‑Mic untouched)
sudo ~/linux-voice-assistant/respeaker2mic/install-4mic-drivers.sh --uninstall
reboot

# Remove the 2‑Mic driver (4‑Mic untouched when present)
sudo ~/linux-voice-assistant/respeaker2mic/install-respeaker-drivers.sh --uninstall
reboot
```

## See also

- [2‑Mic install guide](linux-voice-assistant-2mic-install.md)
- [Application installation](install_application.md)
- [Testing guide](testing-guide.md)
