# Setup: Mini DOOM on the Hack the North badge

## What this actually is

The goal was "port DOOM to the badge." That's not literally possible on this
hardware, and it's worth being upfront about why before you install anything:

- The Lua app sandbox only exposes fixed LVGL widgets (labels, boxes, bars,
  images, etc.) — there is no pixel/framebuffer/canvas API, so nothing can
  blit arbitrary bitmap data the way id Software's renderer does.
- There is no audio API at all.
- Apps are capped at a 48–96 KB Lua heap and a 64 KB source file, and the
  whole filesystem quota per app is 64 KB — a real DOOM WAD is several
  megabytes, so it can't be loaded even if the engine could run.
- The sandbox has no threads/coroutines and callbacks must return well
  under a shared per-tick time budget.

Given that, **`mini_doom.lua` is a real first-person raycasting shooter
written from scratch against the documented APIs** — the same technique
Wolfenstein 3D and DOOM used, adapted to run entirely on reused
`badge.ui.box` widgets instead of a framebuffer. It has a hand-built map,
imp enemies, shooting, health, LEDs, and a score, but it is a homage, not
a port of id Software's engine or assets.

## What the app does

- **View**: a first-person corridor view rendered from 32 shaded vertical
  strips (a grid-DDA raycaster), darkened by distance and by which wall
  face was hit, for a basic depth cue.
- **Enemies**: two "imps" that stand in fixed spots, rendered as
  distance-scaled sprites that hide behind nearer walls. They deal slow
  damage if you stand next to one, and respawn a few seconds after being
  killed.
- **Combat**: shoot with a forward-facing hitscan in a narrow cone; a wall
  between you and an imp blocks the shot.
- **HUD**: health bar (top left), kill count and best-ever kill count
  (top right, saved across sessions), and a control hint at the bottom.
- **Controls**: `UP`/`DOWN` walk forward/back, `LEFT`/`RIGHT` turn, `A`
  shoot, `START` begin or retry after dying, `HOME` exits (default badge
  behavior, no custom override).
- **LEDs** (all six lit together, since these are global game states, not
  positional cues):
  - Green flash — you killed an imp.
  - Amber flash — you hit an imp but it survived.
  - Brief red flash — an imp just hit you.
  - Dim steady red — an imp is visible and close (danger nearby).
  - Slow red breathing pulse — your health is at or below 25%.
  - Deep red heartbeat — you died; press `START` to retry.
  - Dim blue glow — idle/safe, nothing urgent happening.
  - Off — on the title screen, and always on exit (`on_exit` clears them).
- **Saved data**: only your best-ever kill count (`badge.store`, key
  `best_kills`). Nothing else persists between sessions.

## What I checked, and what I didn't

- The Lua file passes a plain syntax check (`luac -p`).
- I wrote a mock of the `badge` API (widgets as no-ops, fake clock, fake
  store) and ran the full lifecycle through it on a desktop Lua interpreter:
  `on_enter`, idle ticks, pressing `START`, walking, turning, repeatedly
  shooting, simulated damage over time, and `on_exit`. It completed with no
  runtime errors.
- **I have not run this on a physical badge.** That mock cannot tell you
  whether 32 raycast columns redrawn every tick, plus two enemy sprites,
  actually finish comfortably inside the real tick time budget on the
  ESP32, or whether the widget count and heap usage behave the same under
  LVGL's real memory allocator. Those are exactly the kinds of failures the
  badge guide warns can't be predicted from source alone.
- If you hit a `Lua execution deadline exceeded` in `on_tick`, or a memory
  error on launch, the fix is almost always to lower `NUM_RAYS` near the
  top of the file (try 24 or 20) and re-push — fewer columns means fewer
  widget updates per tick.

## Installing it

You'll need the [Badge IDE](https://badge.hackthenorth.com/ide/) open in
desktop Chrome or Edge, a USB **data** cable, and your badge. Close any
other tab or tool using the badge's serial port first.

Check which version of the IDE you have — it changes which path below
applies.

### If your IDE has an "Import app" button

1. Open `mini_doom.lua` from this repo and copy its **entire contents**,
   including the `--[==[badge-app ... ]==]` header at the top.
2. In the IDE, save any current work first (Download app, if you want a
   backup of what's already there).
3. Click **Import app**, and paste the whole file (or choose it if the IDE
   lets you pick a `.lua` file directly).
4. Check the slug shown in the preview is `mini_doom`, then click
   **Replace editor files**. This updates your browser workspace only —
   the badge itself hasn't changed yet.
5. Turn the badge off, plug in the USB cable, then turn it on normally.
   **Do not hold Start.**
6. Click **Connect**, and pick **USB JTAG/serial debug unit** (sometimes
   labeled Espressif) in the browser's device picker.
7. Click **Push** and leave the cable connected until it finishes.
8. Open the launcher, find **Mini DOOM**, and press **A** to start it.

### If your IDE only has Connect / Push / Reboot / ^C (no Import app)

1. In the left file list, click **manifest.cfg** and replace its contents
   with just these lines (the part between the header delimiters in
   `mini_doom.lua`, without the delimiters themselves):
   ```
   slug=mini_doom
   name=Mini DOOM
   icon=DOOM
   api=2
   heap_kb=96
   wake_lock=1
   ```
2. Click **main.lua** and replace its contents with everything in
   `mini_doom.lua` **after** the `]==]` line (the actual Lua code, starting
   from the `-- Mini DOOM:` comment).
3. Turn the badge off, connect the USB data cable, then turn it on
   normally without holding Start.
4. Click **Connect**, choose **USB JTAG/serial debug unit** (Espressif),
   then click **Push**, and wait for it to finish.
5. Open **Mini DOOM** from the launcher with **A**.

### If something goes wrong

- **No launcher entry after Push**: check the IDE console for errors, and
  confirm the slug (`mini_doom`) wasn't already taken by another app.
  Try the console command `reload`, then **Reboot** if that doesn't help.
- **An error card appears with a traceback**: note which callback it
  names (`on_enter`, `on_tick`, `on_button`, or `on_exit`) — that tells you
  which part of the game to look at. Three failed ticks in a row, or one
  failed button press, will pause the game; pressing **A** retries from
  where it left off.
- **It runs but feels choppy**: that's a real possibility given the
  raycasting workload — lower `NUM_RAYS` (line ~41) and re-push.
- Full troubleshooting detail lives in `badge-app-guide.md` in this repo,
  under "Help the user troubleshoot in the IDE."
