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
  lastTickMs = now
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
