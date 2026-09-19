--[==[badge-app
slug=mini_doom
name=Mini DOOM
icon=DOOM
api=2
heap_kb=96
wake_lock=1
]==]

-- Mini DOOM: a from-scratch first-person raycasting shooter for the
-- Hack the North badge. There is no WAD, no textures, and no audio API
-- on this platform, so the "renderer" below draws shaded wall columns
-- out of reused badge.ui.box widgets instead of real bitmaps.
--
-- Controls: UP/DOWN walk, LEFT/RIGHT turn, A shoot, START begin/retry,
-- HOME exit (default).

-- ---------------------------------------------------------------------
-- Map: 1 = wall, 0 = floor. Border is solid so raycasts always resolve.
-- ---------------------------------------------------------------------
local MAP = {
  "1111111111",
  "1000000001",
  "1011110001",
  "1010000001",
  "1010111101",
  "1000100001",
  "1110100011",
  "1000100001",
  "1000000001",
  "1111111111",
}
local MAP_SIZE = 10

-- ---------------------------------------------------------------------
-- Screen / view layout
-- ---------------------------------------------------------------------
local SCREEN_W = badge.ui.screen_width or 320
local SCREEN_H = badge.ui.screen_height or 240

local NUM_RAYS = 32
local COL_W = math.floor(SCREEN_W / NUM_RAYS)
local HUD_TOP = 26
local HUD_BOTTOM = 34
local VIEW_Y = HUD_TOP
local VIEW_H = SCREEN_H - HUD_TOP - HUD_BOTTOM
local VIEW_CENTER_Y = VIEW_Y + math.floor(VIEW_H / 2)
local CENTER_X = math.floor(SCREEN_W / 2)

local FOV = 1.0
local HALF_FOV = FOV / 2

local MOVE_SPEED = 0.0035 -- map units per ms
local TURN_SPEED = 0.0035 -- radians per ms

-- Per-column ray angle offsets, precomputed once (pure function of the
-- constants above, independent of player state).
local RAY_OFFSET = {}
for i = 1, NUM_RAYS do
  RAY_OFFSET[i] = -HALF_FOV + (i - 0.5) / NUM_RAYS * FOV
end

-- ---------------------------------------------------------------------
-- Game state
-- ---------------------------------------------------------------------
local px, py, angle = 1.5, 1.5, 0
local health, kills, best = 100, 0, 0
local state = "title" -- "title" | "playing" | "dead"
local lastTickMs = 0
local nextShotAt = 0
local ledEventColor, ledEventUntil = nil, 0
local dangerDist = nil
local enemies = {}
local spawnPoints = {}
local wallDist = {}

-- ---------------------------------------------------------------------
-- Widget handles (created once in on_enter, reused every frame)
-- ---------------------------------------------------------------------
local ceilingBox, floorBox
local cols = {}
local enemyBoxes = {}
local crosshair
local healthBar, scoreLabel, hintLabel
local titleBox, titleText, titleHint

local function clamp(n, lo, hi)
  return math.max(lo, math.min(hi, n))
end

-- x, y may be floats (player position) or integers (grid-step position
-- during DDA below); floor() makes both cases resolve to the same cell.
local function is_wall(x, y)
  local gx = math.floor(x) + 1
  local gy = math.floor(y) + 1
  if gx < 1 or gx > MAP_SIZE or gy < 1 or gy > MAP_SIZE then return true end
  return MAP[gy]:sub(gx, gx) == "1"
end

-- Classic grid DDA raycast (Lodev-style): steps cell-by-cell along the
-- ray instead of small-stepping through space, so cost is bounded by the
-- number of grid lines crossed, not by view distance / step size.
-- Returns perpendicular wall distance (already fisheye-corrected) and
-- which axis was hit (0 = x-side, 1 = y-side, used for shading).
local function cast_ray(ang)
  local rdx, rdy = math.cos(ang), math.sin(ang)
  local mapX, mapY = math.floor(px), math.floor(py)
  local deltaDistX = (rdx == 0) and 1e30 or math.abs(1 / rdx)
  local deltaDistY = (rdy == 0) and 1e30 or math.abs(1 / rdy)

  local stepX, sideDistX
  if rdx < 0 then
    stepX, sideDistX = -1, (px - mapX) * deltaDistX
  else
    stepX, sideDistX = 1, (mapX + 1 - px) * deltaDistX
  end
  local stepY, sideDistY
  if rdy < 0 then
    stepY, sideDistY = -1, (py - mapY) * deltaDistY
  else
    stepY, sideDistY = 1, (mapY + 1 - py) * deltaDistY
  end

  local side, hit = 0, false
  for _ = 1, 24 do -- generous bound for a 10x10 map
    if sideDistX < sideDistY then
      sideDistX = sideDistX + deltaDistX
      mapX = mapX + stepX
      side = 0
    else
      sideDistY = sideDistY + deltaDistY
      mapY = mapY + stepY
      side = 1
    end
    if is_wall(mapX, mapY) then hit = true break end
  end

  local dist
  if side == 0 then
    dist = (mapX - px + (1 - stepX) / 2) / rdx
  else
    dist = (mapY - py + (1 - stepY) / 2) / rdy
  end
  if not hit or dist <= 0 then dist = 8 end
  return dist, side
end

-- Continuous movement is polled from held-button state each tick
-- (rather than only on_button press events) so walking/turning feel
-- smooth. Movement is scaled by elapsed time, not tick count, so speed
-- stays consistent even if a tick is delayed. X and Y are moved and
-- collision-checked separately so the player slides along walls
-- instead of sticking at the first blocked axis.
local function update_player(dt)
  local B = badge.input.BUTTON

  if badge.input.is_down(B.LEFT) then angle = angle - TURN_SPEED * dt end
  if badge.input.is_down(B.RIGHT) then angle = angle + TURN_SPEED * dt end
  if angle >= math.pi * 2 then angle = angle - math.pi * 2 end
  if angle < 0 then angle = angle + math.pi * 2 end

  local moveDist = 0
  if badge.input.is_down(B.UP) then moveDist = moveDist + MOVE_SPEED * dt end
  if badge.input.is_down(B.DOWN) then moveDist = moveDist - MOVE_SPEED * dt end

  if moveDist ~= 0 then
    local nx = px + math.cos(angle) * moveDist
    local ny = py + math.sin(angle) * moveDist
    if not is_wall(nx, py) then px = nx end
    if not is_wall(px, ny) then py = ny end
  end
end

-- Distance and view-relative angle from the player to an enemy, angle
-- normalized to (-pi, pi] so it can be compared directly against the
-- view's field of view.
local function enemy_view_info(e)
  local dx, dy = e.x - px, e.y - py
  local dist = math.sqrt(dx * dx + dy * dy)
  local rel = math.atan(dy, dx) - angle
  while rel > math.pi do rel = rel - 2 * math.pi end
  while rel <= -math.pi do rel = rel + 2 * math.pi end
  return dist, rel
end

-- Stage a short LED event (combat hit/kill/damage cue); update_leds
-- renders it and falls back to the ambient display once it expires.
local function trigger_led(kind, now, durationMs)
  ledEventUntil = now + durationMs
  if kind == "kill" then ledEventColor = { 0, 255, 60 }
  elseif kind == "hit" then ledEventColor = { 255, 180, 0 }
  elseif kind == "miss" then ledEventColor = { 40, 40, 40 }
  elseif kind == "hit_player" then ledEventColor = { 255, 0, 0 }
  elseif kind == "dead" then ledEventColor = { 180, 0, 0 }
  end
end

-- Respawns dead imps after their timer, and deals slow melee damage
-- while an alive imp is adjacent (rate-limited per enemy).
local function update_enemies(now)
  for i = 1, #enemies do
    local e = enemies[i]
    if not e.alive and now >= e.respawnAt then
      local sp = spawnPoints[badge.sys.random(#spawnPoints) + 1]
      e.x, e.y, e.alive, e.hp = sp[1], sp[2], true, 2
    end
    if e.alive then
      local dist = enemy_view_info(e)
      if dist < 1.1 and now >= e.nextHit then
        e.nextHit = now + 500
        health = clamp(health - 8, 0, 100)
        trigger_led("hit_player", now, 300)
      end
    end
  end
end

-- Fire in the narrow center cone: closest visible, alive imp within
-- range takes a hit. "Visible" means the wall column nearest the
-- crosshair is not nearer than the imp (so shots can't go through walls).
local function attempt_shoot(now)
  if now < nextShotAt then return end
  nextShotAt = now + 350

  local centerCol = clamp(math.floor(CENTER_X / COL_W) + 1, 1, NUM_RAYS)
  local target, targetDist = nil, nil
  for i = 1, #enemies do
    local e = enemies[i]
    if e.alive then
      local dist, rel = enemy_view_info(e)
      if math.abs(rel) < 0.14 and dist < 7 and dist < (wallDist[centerCol] or 8) + 0.3 then
        if not target or dist < targetDist then target, targetDist = e, dist end
      end
    end
  end

  if target then
    target.hp = target.hp - 1
    if target.hp <= 0 then
      target.alive = false
      target.respawnAt = now + 4000
      kills = kills + 1
      trigger_led("kill", now, 250)
    else
      trigger_led("hit", now, 150)
    end
  else
    trigger_led("miss", now, 80)
  end
end

local function check_death(now)
  if state == "playing" and health <= 0 then
    state = "dead"
    if kills > best then
      best = kills
      badge.store.set_int("best_kills", best)
    end
    set_overlay(true, "YOU DIED",
      "Kills: " .. kills .. "  Best: " .. best .. "\nPress START to retry")
    trigger_led("dead", now, 100000)
  end
end

-- Redraw the 3D view: one shaded box per screen column, reused every
-- frame (never recreated). Distance is stored per column so enemy
-- rendering can occlude sprites behind nearer walls. Imps are drawn as
-- distance-scaled billboards after the walls so they render in front.
local function render_view()
  for i = 1, NUM_RAYS do
    local dist, side = cast_ray(angle + RAY_OFFSET[i])
    wallDist[i] = dist

    local lh = clamp(math.floor(VIEW_H / math.max(dist, 0.05)), 2, VIEW_H * 2)
    local y = VIEW_CENTER_Y - math.floor(lh / 2)
    cols[i]:set_pos((i - 1) * COL_W, y)
    cols[i]:set_size(COL_W, lh)

    local b = clamp(255 - math.floor(dist * 24), 50, 220)
    if side == 1 then b = math.floor(b * 0.7) end
    local r, g, bl = b, math.floor(b * 0.55), math.floor(b * 0.35)
    cols[i]:set_color(r * 65536 + g * 256 + bl)
  end

  dangerDist = nil
  for i = 1, #enemies do
    local e, box = enemies[i], enemyBoxes[i]
    local shown = false
    if e.alive then
      local dist, rel = enemy_view_info(e)
      if dist < 8 and math.abs(rel) < HALF_FOV + 0.1 then
        local screenX = CENTER_X + (rel / HALF_FOV) * (SCREEN_W / 2)
        local colIdx = clamp(math.floor(screenX / COL_W) + 1, 1, NUM_RAYS)
        if dist < (wallDist[colIdx] or 8) + 0.25 then
          local sh = clamp(math.floor(VIEW_H / dist), 6, math.floor(VIEW_H * 1.3))
          local sw = math.floor(sh * 0.55)
          box:set_size(sw, sh)
          box:set_pos(math.floor(screenX - sw / 2), VIEW_CENTER_Y - math.floor(sh / 2))
          box:hidden(false)
          shown = true
          if not dangerDist or dist < dangerDist then dangerDist = dist end
        end
      end
    end
    if not shown then box:hidden(true) end
  end
end

local function set_overlay(visible, title, hint)
  titleBox:hidden(not visible)
  titleText:hidden(not visible)
  titleHint:hidden(not visible)
  if visible then
    titleText:set_text(title)
    titleHint:set_text(hint)
  end
end

local function update_hud()
  healthBar:set_value(clamp(health, 0, 100))
  scoreLabel:set_text(string.format("Kills %d  Best %d", kills, best))
end

local function reset_game()
  px, py, angle = 1.5, 1.5, 0
  health, kills = 100, 0
  nextShotAt = 0
  ledEventColor, ledEventUntil = nil, 0
  enemies = {
    { x = 7.5, y = 2.5, alive = true, hp = 2, respawnAt = 0, nextHit = 0 },
    { x = 6.5, y = 7.5, alive = true, hp = 2, respawnAt = 0, nextHit = 0 },
  }
  spawnPoints = { { 7.5, 2.5 }, { 6.5, 7.5 }, { 2.5, 7.5 }, { 7.5, 7.5 } }
end

function on_enter(root)
  best = badge.store.get_int("best_kills", 0)

  ceilingBox = badge.ui.box(root, SCREEN_W, math.floor(VIEW_H / 2))
  ceilingBox:set_pos(0, VIEW_Y)
  ceilingBox:style({ bg_color = 0x1b2230, radius = 0, border_width = 0 })

  floorBox = badge.ui.box(root, SCREEN_W, VIEW_H - math.floor(VIEW_H / 2))
  floorBox:set_pos(0, VIEW_Y + math.floor(VIEW_H / 2))
  floorBox:style({ bg_color = 0x2b2b26, radius = 0, border_width = 0 })

  for i = 1, NUM_RAYS do
    local b = badge.ui.box(root, COL_W, 2)
    b:set_pos((i - 1) * COL_W, VIEW_CENTER_Y)
    b:style({ radius = 0, border_width = 0 })
    b:set_color(0x333333)
    cols[i] = b
    wallDist[i] = 8
  end

  for i = 1, 2 do
    local eb = badge.ui.box(root, 10, 20)
    eb:style({ radius = 2, border_color = 0x220000, border_width = 1 })
    eb:set_color(0xaa2222)
    eb:hidden(true)
    enemyBoxes[i] = eb
  end

  crosshair = badge.ui.label(root, "+")
  crosshair:style({ text_font = 20, text_color = 0xffffff })
  crosshair:align("center", 0, VIEW_CENTER_Y - math.floor(SCREEN_H / 2))

  healthBar = badge.ui.bar(root, 0, 100, 100)
  healthBar:set_pos(8, 4)
  healthBar:set_size(120, 10)
  healthBar:style({ bg_color = 0x662222 }, "main")
  healthBar:style({ bg_color = 0x33cc55 }, "indicator")

  scoreLabel = badge.ui.label(root, "")
  scoreLabel:style({ text_font = 14 })
  scoreLabel:align("top_right", -8, 4)

  hintLabel = badge.ui.label(root, "UP/DOWN move   L/R turn   A shoot")
  hintLabel:style({ text_font = 14, text_align = "center" })
  hintLabel:align("bottom_mid", 0, -8)

  titleBox = badge.ui.box(root, 260, 150)
  titleBox:align("center", 0, 0)
  titleBox:style({ bg_color = 0x0c0c0c, border_color = 0x882222,
                   border_width = 2, radius = 8 })
  titleText = badge.ui.label(root, "MINI-DOOM")
  titleText:style({ text_font = 24, text_color = 0xff4444, text_align = "center" })
  titleText:align("center", 0, -35)
  titleHint = badge.ui.label(root,
    "Press START to begin\nUP/DOWN move   LEFT/RIGHT turn\nA shoot   HOME exit")
  titleHint:style({ text_font = 14, text_align = "center" })
  titleHint:align("center", 0, 20)

  reset_game()
  state = "title"
  update_hud()
  set_overlay(true, "MINI-DOOM", "Press START to begin")
  lastTickMs = badge.sys.ms()
end

function on_tick()
  local now = badge.sys.ms()
  local dt = clamp(now - lastTickMs, 0, 120) -- clamp guards a stalled tick
  lastTickMs = now

  if state == "playing" then
    update_player(dt)
    update_enemies(now)
    render_view()
    update_hud()
    check_death(now)
  end

  badge.led.clear()
  badge.led.show()
end

function on_button(button, kind)
  if kind ~= badge.input.KIND.PRESSED then return end
  if button == badge.input.BUTTON.START then
    if state == "title" or state == "dead" then
      reset_game()
      state = "playing"
      set_overlay(false)
      update_hud()
    end
  elseif button == badge.input.BUTTON.A then
    if state == "playing" then attempt_shoot(badge.sys.ms()) end
  end
end

function on_exit()
  badge.led.clear()
  badge.led.show()
  if kills > best then
    best = kills
    badge.store.set_int("best_kills", best)
  end
end
