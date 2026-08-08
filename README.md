# UVA Transit arrivals kiosk image

A self-contained Raspberry Pi image for UVA Transit bus-stop arrival displays. Boots
straight into full-screen Chromium showing the arrivals dashboard for whatever stop
it's deployed at, falls back to showing its own WiFi MAC address (for network
allowlisting) when it can't get online, and carries RustDesk for remote access with a
fixed password. Built with [pi-gen](https://github.com/RPi-Distro/pi-gen), the same
tool the Raspberry Pi Foundation uses for their own images — no manual SD-card/SSH
build process, no physical Pi required to build it.

## 1. One-time setup: install Docker

This only needs to happen once, on the Windows machine you'll use to build images.

1. **Install WSL2** (Windows Subsystem for Linux). Open PowerShell **as Administrator**
   and run:
   ```powershell
   wsl --install
   ```
   This installs WSL2 plus an Ubuntu distribution, and likely asks you to **restart your
   computer**. After restarting, Ubuntu will finish setting up and ask you to create a
   Linux username/password (this is separate from your Windows login — pick anything).

2. **Install Docker Desktop**: download it from docker.com and run the installer, or
   via PowerShell:
   ```powershell
   winget install Docker.DockerDesktop
   ```
   During setup, make sure **"Use WSL 2 instead of Hyper-V"** is enabled (it's the
   default). After install, start Docker Desktop once and let it finish its first-run
   setup — you'll see a whale icon in the system tray when it's ready.

3. In Docker Desktop's Settings → **Resources → WSL Integration**, make sure
   integration is enabled for your Ubuntu distro.

You only need to do this section once. Everything below happens inside the **Ubuntu**
terminal (search for "Ubuntu" in the Start menu), not PowerShell — pi-gen needs real
Linux kernel features (like `binfmt_misc` for ARM emulation) that only exist there.

## 2. Get the project onto WSL2

Clone it into WSL2's own filesystem (not `/mnt/c/...`) — building against a
Windows-mounted path is slower and can hit permission issues:

```bash
git clone --recurse-submodules https://github.com/<your-github-username>/chilipie-kiosk-modern.git ~/chilipie-kiosk-modern
cd ~/chilipie-kiosk-modern
```

## 3. Before your first build

Two placeholder passwords need to be set for real — the build refuses to run until
you do:

- **`config`** — edit `FIRST_USER_PASS` (the maintenance/SSH login).
- **`stage-kiosk/02-rustdesk/files/rustdesk-password`** — the fixed RustDesk
  password you'll use to remote into every device built from this image.

Commit those changes (to your private repo — don't push real passwords to a public
one).

## 4. Build

```bash
./build-local.sh
```

First build takes roughly 30–60+ minutes (it's cross-compiling/emulating an entire
OS). When it finishes, your image is at `deploy/*-kiosk.img.xz`.

## 5. Flash & deploy

1. Flash `deploy/*-kiosk.img.xz` with BalenaEtcher, same as before.
2. Boot the Pi at the deployment site. It joins the hidden, open `wahoo` network
   automatically. Every ~15 seconds it checks in with the ops dashboard (reporting its
   WiFi MAC, hostname, RustDesk ID, and image build), and the dashboard tells it what
   to show:
   - **Not online yet** (MAC not allowlisted on `wahoo`, or no Inseego dongle) —
     shows its WiFi MAC address so it can be allowlisted. Switches over automatically
     once connected, no reboot needed.
   - **Online, but not registered with the dashboard yet** — shows a different
     screen (still with its MAC) telling you to add it to the fleet on the
     dashboard's kiosk-fleet page. Switches over automatically once registered.
   - **Registered** — loads `https://utsopsdashboard.com/arrivalsdisplay?code=<site
     code>` using whatever code the dashboard has assigned to this MAC. Moving a
     device to a different stop later is just an edit on the dashboard — no reflash,
     no SD card pull.
   - **Registered with a URL override** — for the rare non-bus-stop kiosk (e.g. one
     in the training office showing a spreadsheet instead of arrivals), the
     dashboard can assign a full URL instead of a site code, and the kiosk loads
     that directly. This takes priority over a site code if the dashboard ever sets
     both.
3. `site-code.txt` on the boot partition (FAT32, visible from any computer) still
   exists as a **manual override/fallback** — used whenever the dashboard hasn't
   assigned a site code yet (e.g. testing at home before the dashboard knows about
   the device). Once the dashboard has a real assignment for that MAC, the
   dashboard's answer wins.

## Remote access (RustDesk)

Every device built from the same image shares the fixed password you set in step 3.
Each individual Pi still gets its own random RustDesk ID (needed to actually connect
to it). On first boot, the device writes its own ID to `rustdesk-id.txt` on the boot
partition — if you ever need it and haven't connected before, pull the SD card and
read it from any computer.

## Updating the image later

Chromium/RustDesk versions are baked in at build time and won't silently
auto-update on deployed devices (deliberately — no surprise breakage on a public
display). To pick up newer versions: re-run `./build-local.sh` and reflash. The
RustDesk install step always grabs whatever is currently "latest" on GitHub at
build time.

## Testing checklist (on the Pi 3B+ you have on hand)

- [ ] Boots directly to full-screen Chromium, no console/login screen visible
- [ ] Joins the `wahoo` network automatically (hidden, open SSID)
- [ ] With WiFi unavailable/unregistered on `wahoo`: shows the "not connected"
      MAC-address fallback page
- [ ] Once the MAC is allowlisted but not yet registered on the dashboard: switches
      to the distinct "not registered" page (still shows the MAC, different
      messaging/color from the not-connected page)
- [ ] Once the MAC is assigned a site code on the dashboard's kiosk-fleet page:
      switches to the real arrivals dashboard on its own, no reboot
- [ ] Reassigning the site code on the dashboard while the kiosk is running updates
      the display live, no reboot
- [ ] With no dashboard assignment but a test `site-code.txt` set: loads that code's
      dashboard URL as the fallback
- [ ] The device shows up on the dashboard's kiosk-fleet page with correct hostname,
      RustDesk ID, and image build timestamp
- [ ] RustDesk connects remotely using the fixed password
- [ ] Inseego USB cellular dongle still "just works" as a fallback connection
- [ ] Survives an overnight unattended run (nightly reboot at 3:30am shouldn't
      disrupt normal operation)

## Project layout

- `pi-gen/` — official upstream image builder (git submodule, `arm64` branch)
- `config` — pi-gen build settings (hostname, user, WiFi country, etc.)
- `stage-kiosk/` — our custom pi-gen stage, inserted after the stock "Lite" stage:
  - `00-packages` — Chromium, X11, matchbox, NetworkManager, etc.
  - `01-kiosk-app/` — the kiosk launch script, systemd service, MAC-fallback page,
    `wahoo` WiFi profile, nightly-reboot cron entry
  - `02-rustdesk/` — RustDesk install + fixed-password provisioning
- `build-local.sh` — copies `stage-kiosk/` into `pi-gen/` and runs the Docker build
