# Deploying a kiosk

A field runbook for taking a built image from `deploy/*-kiosk.img.xz` to a working
display at a bus stop (or anywhere else). If you're building the image itself, see
[README.md](README.md) instead — this doc assumes that part's already done.

## 1. Flash

1. Open **BalenaEtcher**.
2. Select the image: `*-kiosk.img.xz` (not the `-lite` one — that's a build
   byproduct, not something to flash).
3. Select the target SD card. **Double-check you've picked the right drive** —
   Etcher will happily overwrite whatever you point it at.
4. Flash and verify (Etcher does this automatically).

## 2. First boot

1. Put the SD card in the Pi, connect power (and HDMI if you want to watch it
   boot), and power on.
2. It boots quiet — no rainbow splash, no boot text, just black screen until
   Chromium starts. This is intentional, not a hang.
3. Once Chromium launches, it's checking in with the ops dashboard every ~15
   seconds and showing you one of three things:

   | Screen | Means | What to do |
   |---|---|---|
   | Red — **"Not connected to network"**, shows a MAC address | Can't reach the internet at all | Get it on `wahoo` (see step 3) or plug in the Inseego dongle |
   | Amber — **"Connected, but not registered"**, shows a MAC address | Online, but the dashboard doesn't know this device yet | Register it (see step 4) |
   | The actual arrivals board (or whatever URL was assigned) | Done | Nothing — you're deployed |

   Both fallback screens auto-recover on their own once the underlying problem
   is fixed — no reboot needed either way.

## 3. Get it on the network

The device auto-joins **`wahoo`** (hidden, open SSID) the moment its WiFi MAC is
allowlisted on that network. The MAC is on-screen on the red fallback page — that
network-level allowlisting is managed separately from the ops dashboard (talk to
whoever administers the `wahoo` access point).

No WiFi available at this location at all? Plug in the **Inseego USB cellular
dongle** instead — it works automatically, no configuration needed.

## 4. Register it on the dashboard

Once the device is online, it'll show the amber "not registered" screen with its
MAC address. Go to the ops dashboard's **kiosk-fleet** page
(`https://utsopsdashboard.com/kiosk-fleet`, dispatcher login required) and find
that MAC in the list — it should already be there as a check-in with no site
assigned, since the device has been reporting itself every 15 seconds.

Assign it one of:
- **Site code** (e.g. `EIGSB`) — the normal case, for a device at an actual bus
  stop. Loads that stop's arrivals board.
- **URL override** — for anything that isn't a bus stop (e.g. a training-office
  display showing a spreadsheet). If both are set on a device, the URL wins.

The screen updates on its own within ~15 seconds — no reboot, no re-flash.

**Moving a device to a different stop later** is the same step: just edit its
site code on the fleet page. It'll switch over live.

## 5. Confirm it's actually working

- The dashboard's arrivals board (or your assigned URL) is on screen.
- The device shows up on the kiosk-fleet page with the right hostname, a
  RustDesk ID, and a recent "last seen" timestamp.
- Remote in with **RustDesk** using the fleet-wide password to confirm you can
  actually reach it (ask whoever set up the image for the current password — it's
  not written anywhere in this repo).

If you ever need a device's RustDesk ID without remoting in first (e.g. it's not
online yet), pull the SD card and read `rustdesk-id.txt` off the small FAT32 boot
partition on any computer.

## Manual override (testing at home, before the dashboard knows about it)

The FAT32 boot partition also has a `site-code.txt` file. If you put a site code
in it, the kiosk uses that as a **fallback** whenever the dashboard hasn't
assigned anything yet — handy for testing a build at your desk before deploying
it. Once the dashboard has a real assignment for that device's MAC, the
dashboard's answer takes over and `site-code.txt` stops mattering.

---

## Troubleshooting

**Screen is completely black, nothing ever appears**
Not the same as the intentional quiet-boot black screen (which resolves in well
under a minute). If it's been black for several minutes: check the SD card is
fully seated, check the power supply is adequate (a flaky supply is the single
most common cause of a Pi that won't boot), and try the card in another Pi if you
have one, to rule out a bad flash.

**Stuck on the red "not connected" screen and the MAC is definitely allowlisted**
- Double-check the MAC on screen matches what was actually allowlisted (typos
  happen).
- `wahoo` is a hidden SSID — some WiFi adapters are slower to find hidden
  networks; give it a few minutes.
- If there's no WiFi at this site at all, confirm the Inseego dongle is actually
  plugged in and has signal (check its own status LEDs).
- As a sanity check, RustDesk needs the same network — if you can't remote in
  either, that confirms it's genuinely offline, not a display-layer bug.

**Stuck on the amber "not registered" screen and you did assign it a site code**
- Give it up to ~15 seconds — that's the poll interval, it's not instant.
- Double-check the MAC you assigned it on the fleet page matches the MAC on the
  device's screen exactly.
- Confirm the device is actually still checking in (its "last seen" timestamp on
  the fleet page should be recent, updating roughly every 15s).

**It's showing the dashboard, but the wrong stop**
- Check the site code assigned to that MAC on the fleet page — someone may have
  assigned the wrong one, or two devices' MACs got mixed up during registration.
- If a URL override is set on that device, it always wins over the site code —
  check for one on the fleet page.

**RustDesk won't connect**
- Confirm you're on the current password (it's changed per-image-build; ask
  whoever built the image you flashed).
- Pull the SD card and check `rustdesk-id.txt` on the boot partition — if it's
  empty/missing, RustDesk hadn't finished provisioning itself yet by the time you
  checked (this happens automatically on first boot, but needs the network up
  first).
- RustDesk needs the same connectivity as everything else — if the kiosk itself
  shows the red not-connected screen, that's why RustDesk can't reach it either.

**Chromium looks frozen or crashed**
It's supervised and set to auto-restart on crash. If it's genuinely frozen
(not crashed) rather than just slow, it can take up to the next 15-second check-in
cycle to notice and recover. If it's still stuck after a few minutes, that's worth
reporting — it likely means the crash-restart watchdog isn't catching a hang, only
an outright crash, which is a known gap.

**Everything reboots on its own around 3:30am**
That's intentional — a nightly reboot keeps the device fresh over long unattended
runs. It should come back up in well under a minute; if it doesn't, treat it like
any other boot failure above.
