-- Talk Talk Talk — Kokoro TTS hotkeys, status pill and silent reader
-- Installed by install.sh (which fills in the kokoro directory below),
-- then loaded from ~/.hammerspoon/init.lua via: require("talk_talk_talk")
--
-- Two switches govern what happens, both in the menu bar:
--   TLDR         summarise the text first
--   Reader mode  show it in the full-screen reader instead of speaking it
--
-- Hotkeys:
--   ⌃⌥S  read selection            ⌃⌥P  read the reply / pause / resume
--   ⌃⌥←  rewind 10s                ⌃⌥X  dismiss / stop
--   ⌃⌥A  auto-read on/off          ⌃⌥T  TLDR on/off
--   ⌃⌥R  reader mode on/off

local KOKORO_DIR = "@@KOKORO_DIR@@"
local KTTS = KOKORO_DIR .. "/ktts"

local function ktts(...)
  hs.task.new(KTTS, nil, { ... }):start()
end

-- Speak the current selection: copy it via ⌘C, read the clipboard,
-- then restore whatever was on the clipboard before.
local function speakSelection()
  local previous = hs.pasteboard.getContents()
  local changeCount = hs.pasteboard.changeCount()
  hs.eventtap.keyStroke({ "cmd" }, "c")
  hs.timer.doAfter(0.25, function()
    local selection = nil
    if hs.pasteboard.changeCount() ~= changeCount then
      selection = hs.pasteboard.getContents()
      if previous then hs.pasteboard.setContents(previous) end
    end
    if selection and #selection > 0 then
      ktts("say", selection)
    else
      hs.alert.show("No text selected")
    end
  end)
end

-- ---------------------------------------------------------------------------
-- Floating status pill: shows loading/synthesizing/speaking/paused state
-- with clickable pause/resume and stop buttons. Driven by the daemon writing
-- the state file on every transition (no polling).
-- ---------------------------------------------------------------------------

local STATE_FILE = KOKORO_DIR .. "/state"

local COLORS = {
  loading      = { red = 0.95, green = 0.60, blue = 0.10, alpha = 1 },
  synthesizing = { red = 0.95, green = 0.60, blue = 0.10, alpha = 1 },
  playing      = { red = 0.25, green = 0.80, blue = 0.35, alpha = 1 },
  paused       = { red = 0.95, green = 0.85, blue = 0.20, alpha = 1 },
  ready        = { red = 0.35, green = 0.55, blue = 0.95, alpha = 1 },
}
local LABELS = {
  loading      = "Loading model…",
  synthesizing = "Preparing…",
  playing      = "Speaking",
  paused       = "Paused",
  ready        = "Agent replied",
}

local PENDING_FILE = KOKORO_DIR .. "/pending.txt"
local pill = nil
local currentState = "idle"
local readyTimer = nil
local autoRead = hs.settings.get("tttAutoRead") or false
local autoPlayFired = false
local fnHeld = false        -- Fn key currently down (Wispr Flow dictation)
local fnAutoPaused = false  -- we paused because of Fn, so we may auto-resume
local pillHidden = false    -- ✕ clicked: stay hidden until the next event
local lastSeenState = "idle"
local rsvpOn = hs.settings.get("tttRsvp") or false
-- Reader mode: send text to the full-screen reader instead of speaking it.
-- Orthogonal to TLDR mode (summarise first), which lives in config.json.
local readerMode = hs.settings.get("tttReaderMode") or false
local WORD_FILE = KOKORO_DIR .. "/word"
local PILL_H, DRAWER_H = 36, 92
-- ORP (optimal recognition point): the letter the eye fixates on. Held at
-- a fixed x so the anchor never moves between words — that is what makes
-- RSVP readable at speed.
local ORP_X_FRACTION = 0.42
local RSVP_FONT = "Helvetica-Bold"
local RSVP_SIZE = 26
local ORP_COLOR = { red = 1, green = 0.36, blue = 0.30, alpha = 1 }
local drawerLeft, drawerRight, drawerY = 10, 262, 46
local TLDR_SCRIPT = KOKORO_DIR .. "/tldr.py"
local CONFIG_FILE_EARLY = KOKORO_DIR .. "/config.json"

local function readCfg()
  local f = io.open(CONFIG_FILE_EARLY, "r")
  if not f then return {} end
  local raw = f:read("*a") or ""
  f:close()
  local ok, cfg = pcall(hs.json.decode, raw)
  return (ok and type(cfg) == "table") and cfg or {}
end

local function writeCfg(cfg)
  local f = io.open(CONFIG_FILE_EARLY, "w")
  if f then f:write(hs.json.encode(cfg)) f:close() end
end

-- forward declared: defined once deliverFile exists below
local playPending

local function dismissReady()
  local f = io.open(STATE_FILE, "w")
  if f then f:write("idle") f:close() end
end

local tldrRunning = false
local SELECTION_FILE = KOKORO_DIR .. "/selection.txt"

local function tldrEnabled()
  return readCfg().tldr_replies == true
end

-- Deliver text according to the two switches: TLDR mode decides whether it
-- is summarised first, reader mode decides whether it is shown or spoken.
local function deliver(text)
  if not text or #text == 0 then return end
  if readerMode then
    if tttReadText then tttReadText(text) end
  else
    ktts("say", text)
  end
end

local function deliverFile(path)
  if not tldrEnabled() then
    hs.task.new("/bin/sh", function(code, stdout)
      deliver((stdout or ""):gsub("%s+$", ""))
    end, { "-c", "cat '" .. path .. "'" }):start()
    return
  end
  if tldrRunning then
    hs.alert.show("Already summarising…", 1)
    return
  end
  tldrRunning = true
  hs.alert.show("Summarising…", 1.5)
  hs.task.new("/bin/sh", function(code, stdout, stderr)
    tldrRunning = false
    local summary = (stdout or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if code ~= 0 or #summary == 0 then
      hs.alert.show("TLDR failed: " .. ((stderr or ""):gsub("%s+$", "")), 4)
      return
    end
    deliver(summary)
  end, { "-c", "'" .. TLDR_SCRIPT .. "' < '" .. path .. "'" }):start()
end

playPending = function()
  deliverFile(PENDING_FILE)
end

-- Exposed for scripts and tests.
tttReadReply = function() deliverFile(PENDING_FILE) end
tttSetModes = function(tldr, reader)
  local c = readCfg(); c.tldr_replies = tldr; writeCfg(c)
  readerMode = reader
  hs.settings.set("tttReaderMode", reader)
end

-- Read whatever is selected, through the same two switches.
local function readSelection()
  local previous = hs.pasteboard.getContents()
  local changeCount = hs.pasteboard.changeCount()
  hs.eventtap.keyStroke({ "cmd" }, "c")
  hs.timer.doAfter(0.25, function()
    local selection = nil
    if hs.pasteboard.changeCount() ~= changeCount then
      selection = hs.pasteboard.getContents()
      if previous then hs.pasteboard.setContents(previous) end
    end
    if not selection or #selection == 0 then
      hs.alert.show("No text selected")
      return
    end
    local f = io.open(SELECTION_FILE, "w")
    if not f then hs.alert.show("Could not stage the selection") return end
    f:write(selection)
    f:close()
    deliverFile(SELECTION_FILE)
  end)
end

local AUTO_ON  = { red = 0.25, green = 0.80, blue = 0.35, alpha = 0.95 }
local AUTO_OFF = { red = 1, green = 1, blue = 1, alpha = 0.30 }

local function toggleAutoRead()
  autoRead = not autoRead
  hs.settings.set("tttAutoRead", autoRead)
  hs.alert.show(autoRead and "Auto-read: ON" or "Auto-read: OFF")
  if pill then pill[6].textColor = autoRead and AUTO_ON or AUTO_OFF end
  if autoRead and currentState == "ready" then playPending() end
end

local updatePillRef = nil  -- set once updatePill is defined below
local updateMenubarRef = nil  -- set once the menu bar item exists below
local updateWordRef = nil  -- set once updateWord is defined below
local wordTimer = nil
local lastWord = nil

local function toggleTldr()
  local c = readCfg()
  c.tldr_replies = not (c.tldr_replies == true)
  writeCfg(c)
  hs.alert.show(c.tldr_replies and "TLDR: ON" or "TLDR: OFF")
  if pill then
    pill[18].textColor = c.tldr_replies and AUTO_ON or AUTO_OFF
  end
end

local function toggleReaderMode()
  readerMode = not readerMode
  hs.settings.set("tttReaderMode", readerMode)
  hs.alert.show(readerMode and "Reader mode: ON (shows instead of speaking)"
                            or "Reader mode: OFF (speaks)")
end

local function toggleRsvp()
  rsvpOn = not rsvpOn
  hs.settings.set("tttRsvp", rsvpOn)
  hs.alert.show(rsvpOn and "Read-along: ON" or "Read-along: OFF")
  if pill then pill[14].textColor = rsvpOn and AUTO_ON or AUTO_OFF end
  if updatePillRef then updatePillRef() end
end

local WAVE_BARS = 5
local waveTimer = nil
local dragTap = nil

local function buildPill()
  local screen = hs.screen.mainScreen():frame()
  local w, h = 272, 36
  local pos = hs.settings.get("tttPillPos")
  local x, y
  if pos and pos.x and pos.y then
    -- clamp a remembered position back onto the current screen
    x = math.max(screen.x, math.min(pos.x, screen.x + screen.w - w))
    y = math.max(screen.y, math.min(pos.y, screen.y + screen.h - h))
  else
    x, y = screen.x + screen.w - w - 14, screen.y + 10
  end
  pill = hs.canvas.new({ x = x, y = y, w = w, h = h })
  pill:level(hs.canvas.windowLevels.overlay)
  pill:behavior({ "canJoinAllSpaces", "stationary" })
  pill:clickActivating(false)
  pill[1] = { type = "rectangle", action = "fill",
              roundedRectRadii = { xRadius = 18, yRadius = 18 },
              fillColor = { red = 0.08, green = 0.08, blue = 0.10, alpha = 0.92 },
              trackMouseDown = true, id = "bg" }
  pill[2] = { type = "circle", action = "fill", center = { x = 21, y = h / 2 },
              radius = 5.5, fillColor = COLORS.playing }
  pill[3] = { type = "text", frame = { x = 36, y = 8, w = 112, h = 20 },
              text = "", textSize = 13,
              textColor = { red = 1, green = 1, blue = 1, alpha = 0.95 } }
  pill[4] = { type = "text", frame = { x = 198, y = 5, w = 34, h = 26 },
              text = "⏸", textSize = 18, textAlignment = "center",
              textColor = { red = 1, green = 1, blue = 1, alpha = 0.95 },
              trackMouseDown = true, id = "toggle" }
  pill[5] = { type = "text", frame = { x = 232, y = 5, w = 34, h = 26 },
              text = "⏹", textSize = 18, textAlignment = "center",
              textColor = { red = 1, green = 1, blue = 1, alpha = 0.95 },
              trackMouseDown = true, id = "stop" }
  pill[6] = { type = "text", frame = { x = 150, y = 11, w = 42, h = 16 },
              text = "AUTO", textSize = 11, textAlignment = "center",
              textColor = autoRead and AUTO_ON or AUTO_OFF,
              trackMouseDown = true, id = "auto" }
  -- waveform bars (elements 7..11), hidden unless speaking
  for i = 0, WAVE_BARS - 1 do
    pill[7 + i] = { type = "rectangle", action = "skip",
                    roundedRectRadii = { xRadius = 2, yRadius = 2 },
                    frame = { x = 40 + i * 8, y = 14, w = 4.5, h = 8 },
                    fillColor = { red = 0.25, green = 0.80, blue = 0.35, alpha = 0.95 } }
  end
  pill[12] = { type = "text", frame = { x = 0, y = 5, w = 32, h = 26 },
               text = "⏪\u{FE0E}", textSize = 18, textAlignment = "center",
               textColor = { red = 1, green = 1, blue = 1, alpha = 0.95 },
               trackMouseDown = true, id = "back" }
  pill[13] = { type = "text", frame = { x = 0, y = 8, w = 22, h = 20 },
               text = "✕", textSize = 13, textAlignment = "center",
               textColor = { red = 1, green = 1, blue = 1, alpha = 0.45 },
               trackMouseDown = true, id = "close" }
  pill[14] = { type = "text", frame = { x = 0, y = 7, w = 22, h = 22 },
               text = "▾", textSize = 15, textAlignment = "center",
               textColor = rsvpOn and AUTO_ON or AUTO_OFF,
               trackMouseDown = true, id = "rsvp" }
  -- RSVP drawer: the currently-spoken word, positioned by updateWord so
  -- its ORP letter stays pinned; hence left alignment, not centred.
  pill[15] = { type = "text", action = "skip",
               frame = { x = 10, y = 46, w = 252, h = 38 },
               text = "", textAlignment = "left" }
  -- faint guide ticks marking the fixation point
  for i = 16, 17 do
    pill[i] = { type = "rectangle", action = "skip",
                frame = { x = 0, y = 0, w = 1.5, h = 6 },
                fillColor = { red = 1, green = 1, blue = 1, alpha = 0.25 } }
  end
  pill[18] = { type = "text", frame = { x = 0, y = 11, w = 44, h = 16 },
               text = "TL;DR", textSize = 10, textAlignment = "center",
               textColor = tldrEnabled() and AUTO_ON or AUTO_OFF,
               trackMouseDown = true, id = "tldr" }
  pill:mouseCallback(function(_, event, id)
    if event ~= "mouseDown" then return end
    if id == "auto" then
      toggleAutoRead()
    elseif id == "rsvp" then
      toggleRsvp()
    elseif id == "close" then
      pillHidden = true
      pill:hide(0.15)
    elseif id == "tldr" then
      toggleTldr()
    elseif id == "back" then
      ktts("back")
    elseif id == "toggle" then
      if currentState == "ready" then playPending() else ktts("toggle") end
    elseif id == "stop" then
      if currentState == "ready" then dismissReady() else ktts("stop") end
    elseif id == "bg" then
      -- drag to reposition; remember where it lands
      local mouse = hs.mouse.absolutePosition()
      local tl = pill:topLeft()
      local off = { x = mouse.x - tl.x, y = mouse.y - tl.y }
      if dragTap then dragTap:stop() end
      dragTap = hs.eventtap.new(
        { hs.eventtap.event.types.leftMouseDragged,
          hs.eventtap.event.types.leftMouseUp },
        function(e)
          if e:getType() == hs.eventtap.event.types.leftMouseDragged then
            local m = hs.mouse.absolutePosition()
            pill:topLeft({ x = m.x - off.x, y = m.y - off.y })
          else
            dragTap:stop()
            dragTap = nil
            local p = pill:topLeft()
            hs.settings.set("tttPillPos", { x = p.x, y = p.y })
          end
          return false
        end)
      dragTap:start()
    end
  end)
end

-- Re-fit the pill to its current content: the waveform is narrow, the text
-- labels vary in width. Buttons pack up against the content and the pill
-- keeps its right edge fixed while resizing.
local function layoutPill(st)
  local cw
  if st == "playing" then
    cw = 46
  else
    cw = math.floor(#(LABELS[st] or st) * 7.2) + 8
  end
  local autoX  = 36 + cw + 4
  local tldrX  = autoX + 46
  local backX  = tldrX + 48
  local togX   = backX + 30
  local stopX  = togX + 32
  local rsvpX  = stopX + 30
  local closeX = rsvpX + 22
  local w      = closeX + 22 + 8
  pill[3].frame  = { x = 36, y = 8, w = cw, h = 20 }
  pill[6].frame  = { x = autoX, y = 11, w = 42, h = 16 }
  pill[18].frame = { x = tldrX, y = 11, w = 44, h = 16 }
  pill[12].frame = { x = backX, y = 6, w = 30, h = 26 }
  pill[4].frame  = { x = togX, y = 5, w = 32, h = 26 }
  pill[5].frame  = { x = stopX, y = 5, w = 32, h = 26 }
  pill[14].frame = { x = rsvpX, y = 7, w = 22, h = 22 }
  pill[13].frame = { x = closeX, y = 8, w = 22, h = 20 }
  -- the drawer drops downward, so the control row never moves
  local drawerOpen = rsvpOn and (st == "playing" or st == "paused")
  local h = drawerOpen and DRAWER_H or PILL_H
  -- poll the word file while the drawer is open: pathwatcher coalesces
  -- events with ~300ms latency, which is a visible lag at speech pace
  if drawerOpen and not wordTimer then
    wordTimer = hs.timer.doEvery(0.06, updateWordRef)
  elseif not drawerOpen and wordTimer then
    wordTimer:stop()
    wordTimer = nil
    lastWord = nil
  end
  drawerLeft, drawerRight, drawerY = 14, w - 14, 46
  pill[15].action = drawerOpen and "fill" or "skip"
  pill[16].action = drawerOpen and "fill" or "skip"
  pill[17].action = drawerOpen and "fill" or "skip"
  lastWord = nil  -- geometry may have changed: force a re-lay-out
  local f = pill:frame()
  pill:frame({ x = f.x + (f.w - w), y = f.y, w = w, h = h })
end

local function readWord()
  local f = io.open(WORD_FILE, "r")
  if not f then return "" end
  local w = f:read("*a") or ""
  f:close()
  return (w:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Which letter the eye should land on (Spritz-style pivot), 1-indexed.
local function orpIndex(len)
  if len <= 1 then return 1
  elseif len <= 5 then return 2
  elseif len <= 9 then return 3
  elseif len <= 13 then return 4
  else return 5 end
end

local function measure(str, size)
  if str == "" then return 0 end
  local s = hs.styledtext.new(str, { font = { name = RSVP_FONT, size = size } })
  return hs.drawing.getTextDrawingSize(s).w
end

-- Render the current word with its ORP letter pinned to a fixed x, so the
-- eye never has to travel. Long words shrink to fit around that anchor.
local function updateWord()
  if not pill or not rsvpOn then return end
  if currentState ~= "playing" and currentState ~= "paused" then return end
  local word = readWord()
  if word == lastWord then return end
  lastWord = word
  if word == "" then
    pill[15].text = ""
    return
  end

  local anchorX = drawerLeft + (drawerRight - drawerLeft) * ORP_X_FRACTION
  local orp = orpIndex(#word)
  local pre, anchor = word:sub(1, orp - 1), word:sub(orp, orp)

  -- shrink only as much as needed for the word to fit around the anchor
  local size = RSVP_SIZE
  local leftNeed = measure(pre, size) + measure(anchor, size) / 2
  local rightNeed = measure(word, size) - leftNeed
  local leftRoom = anchorX - drawerLeft
  local rightRoom = drawerRight - anchorX
  local scale = math.min(1,
    leftNeed > 0 and leftRoom / leftNeed or 1,
    rightNeed > 0 and rightRoom / rightNeed or 1)
  if scale < 1 then size = math.max(12, math.floor(size * scale)) end

  local dim = (currentState == "paused")
  local color = { red = 1, green = 1, blue = 1, alpha = dim and 0.5 or 0.95 }
  local anchorColor = { red = ORP_COLOR.red, green = ORP_COLOR.green,
                        blue = ORP_COLOR.blue, alpha = dim and 0.5 or 1 }
  local styled = hs.styledtext.new(word,
    { font = { name = RSVP_FONT, size = size }, color = color })
  styled = styled:setStyle({ color = anchorColor }, orp, orp)

  -- position so the anchor letter's centre sits exactly on anchorX
  local offset = measure(pre, size) + measure(anchor, size) / 2
  pill[15].text = styled
  pill[15].frame = { x = anchorX - offset, y = drawerY,
                     w = drawerRight - drawerLeft + 60, h = 38 }
  pill[16].frame = { x = anchorX - 0.75, y = drawerY - 7, w = 1.5, h = 6 }
  pill[17].frame = { x = anchorX - 0.75, y = drawerY + 36, w = 1.5, h = 6 }
end

local function readState()
  local f = io.open(STATE_FILE, "r")
  if not f then return "idle" end
  local s = f:read("*a") or ""
  f:close()
  return (s:gsub("%s+", ""))
end

local function updatePill()
  local st = readState()
  currentState = (st == "") and "idle" or st
  -- a genuinely new event (fresh reply or new speech) un-hides the pill
  if pillHidden and st ~= lastSeenState
     and (st == "ready" or st == "synthesizing") then
    pillHidden = false
  end
  lastSeenState = currentState
  if readyTimer then readyTimer:stop() readyTimer = nil end
  if updateMenubarRef then updateMenubarRef() end
  if currentState == "idle" then
    pillHidden = false
    if waveTimer then waveTimer:stop() waveTimer = nil end
    if pill then pill:hide(0.2) end
    return
  end
  if pillHidden then
    if waveTimer then waveTimer:stop() waveTimer = nil end
    if pill then pill:hide(0.15) end
    return
  end
  if not pill then buildPill() end
  pill[2].fillColor = COLORS[st] or COLORS.playing
  layoutPill(st)

  -- while speaking, show an animated waveform instead of a text label
  if st == "playing" then
    -- dictation in progress: keep quiet until Fn is released
    if fnHeld and not fnAutoPaused then
      fnAutoPaused = true
      ktts("pause")
    end
    pill[3].text = ""
    for i = 0, WAVE_BARS - 1 do pill[7 + i].action = "fill" end
    if not waveTimer then
      waveTimer = hs.timer.doEvery(0.12, function()
        for i = 0, WAVE_BARS - 1 do
          local bh = math.random(5, 24)
          pill[7 + i].frame = { x = 40 + i * 8, y = 18 - bh / 2, w = 4.5, h = bh }
        end
      end)
    end
  else
    if waveTimer then waveTimer:stop() waveTimer = nil end
    for i = 0, WAVE_BARS - 1 do pill[7 + i].action = "skip" end
    pill[3].text = LABELS[st] or st
  end

  pill[4].text = (st == "paused" or st == "ready") and "▶" or "⏸"
  local controls = (st == "playing" or st == "paused" or st == "ready")
  pill[4].textColor.alpha = controls and 0.95 or 0.25
  pill[5].textColor.alpha = (st ~= "loading") and 0.95 or 0.25
  pill[6].textColor = autoRead and AUTO_ON or AUTO_OFF
  pill[12].textColor.alpha = (st == "playing" or st == "paused") and 0.95 or 0.25
  pill[18].textColor = tldrEnabled() and AUTO_ON or AUTO_OFF
  pill[14].textColor = rsvpOn and AUTO_ON or AUTO_OFF
  updateWord()
  pill:show(0.2)
  if st == "ready" then
    if autoRead then
      -- play staged reply immediately; guard against duplicate fs events
      if not autoPlayFired then
        autoPlayFired = true
        playPending()
      end
    else
      readyTimer = hs.timer.doAfter(60, dismissReady)
    end
  else
    autoPlayFired = false
  end
end

updatePillRef = updatePill
updateWordRef = updateWord

tttPathWatcher = hs.pathwatcher.new(KOKORO_DIR, function(files)
  for _, f in ipairs(files) do
    if f:sub(-6) == "/state" or f:sub(-5) == "state" then
      updatePill()
      return
    end
  end
end):start()

updatePill()

-- ---------------------------------------------------------------------------
-- Silent RSVP reader — no speech at all. ⌃⌥R takes the selection and dims
-- the screen down to a single centred word; hold R to advance. Speed and
-- key reference live in the menu bar, so nothing competes with the word.
-- ---------------------------------------------------------------------------

local reader = nil          -- canvas on the reading screen
local dimmers = {}          -- one per other screen, so focus is total
local readerWords = {}
local readerIndex = 1
local readerTimer = nil
local readerTap = nil
local rHeld = false
local rHoldStart = 0
local readerWpm = hs.settings.get("tttReaderWpm") or 350

local chipHold = nil        -- timer: how long the speed chip stays solid
local chipFade = nil        -- timer: the fade itself
local R_ORP_X = 0.42        -- fixation point, as a fraction of screen width
local R_SIZE = 64
local DIM = { red = 0.02, green = 0.02, blue = 0.03, alpha = 0.94 }

local function closeReader()
  if chipHold then chipHold:stop() chipHold = nil end
  if chipFade then chipFade:stop() chipFade = nil end
  if readerTimer then readerTimer:stop() readerTimer = nil end
  if readerTap then readerTap:stop() readerTap = nil end
  if reader then reader:delete() reader = nil end
  for _, d in ipairs(dimmers) do d:delete() end
  dimmers = {}
  rHeld = false
end

-- Per-word dwell. Longer words need longer, and punctuation earns a beat;
-- the factors average out near 1 so the stated WPM stays roughly honest.
local function wordDelay(word)
  local base = 60.0 / readerWpm
  local lengthFactor = math.max(0.7, math.min(1.8, 0.7 + #word / 12))
  local punctFactor = 1.0
  if word:match("[.!?][\'\"]?$") then punctFactor = 2.0
  elseif word:match("[,;:]$") then punctFactor = 1.4 end
  return base * lengthFactor * punctFactor
end

local function renderReaderWord()
  if not reader then return end
  local word = readerWords[readerIndex]
  if not word then return end
  local f = reader:frame()
  local anchorX = f.w * R_ORP_X
  local midY = f.h / 2
  local orp = orpIndex(#word)
  local pre, anchor = word:sub(1, orp - 1), word:sub(orp, orp)

  local size = R_SIZE
  local leftNeed = measure(pre, size) + measure(anchor, size) / 2
  local rightNeed = measure(word, size) - leftNeed
  local scale = math.min(1,
    leftNeed > 0 and (anchorX - 40) / leftNeed or 1,
    rightNeed > 0 and (f.w - anchorX - 40) / rightNeed or 1)
  if scale < 1 then size = math.max(20, math.floor(size * scale)) end

  local styled = hs.styledtext.new(word, {
    font = { name = RSVP_FONT, size = size },
    color = { white = 1, alpha = 0.97 },
  }):setStyle({ color = ORP_COLOR }, orp, orp)

  local offset = measure(pre, size) + measure(anchor, size) / 2
  reader[4].text = styled
  reader[4].frame = { x = anchorX - offset, y = midY - size * 0.72,
                      w = f.w, h = size * 1.5 }
  -- guides hug the line wherever it sits
  reader[2].frame = { x = anchorX - 1, y = midY - size * 0.95, w = 2, h = 14 }
  reader[3].frame = { x = anchorX - 1, y = midY + size * 0.62, w = 2, h = 14 }
  reader[5].frame = { x = 0, y = f.h - 3,
                      w = f.w * (readerIndex / math.max(#readerWords, 1)), h = 3 }
end

local CHIP_BG = { red = 0.13, green = 0.13, blue = 0.15 }

local function showSpeedChip()
  if not reader then return end
  local f = reader:frame()
  local w, h = 116, 34
  local x, y = (f.w - w) / 2, f.h - 110
  reader[6].frame = { x = x, y = y, w = w, h = h }
  reader[6].action = "fill"
  reader[6].fillColor = { red = CHIP_BG.red, green = CHIP_BG.green,
                          blue = CHIP_BG.blue, alpha = 0.85 }
  reader[7].frame = { x = x, y = y + 8, w = w, h = 20 }
  reader[7].action = "fill"
  reader[7].text = readerWpm .. " wpm"
  reader[7].textColor = { white = 1, alpha = 0.85 }

  if chipHold then chipHold:stop() end
  if chipFade then chipFade:stop() chipFade = nil end
  chipHold = hs.timer.doAfter(0.9, function()
    chipHold = nil
    local step = 0
    chipFade = hs.timer.doEvery(0.035, function()
      step = step + 1
      local a = 1 - step / 12
      if not reader or a <= 0 then
        if chipFade then chipFade:stop() chipFade = nil end
        if reader then
          reader[6].action = "skip"
          reader[7].action = "skip"
        end
        return
      end
      reader[6].fillColor = { red = CHIP_BG.red, green = CHIP_BG.green,
                              blue = CHIP_BG.blue, alpha = 0.85 * a }
      reader[7].textColor = { white = 1, alpha = 0.85 * a }
    end)
  end)
end

local function advance()
  readerTimer = nil
  if not reader then return end
  if rHeld and (os.time() - rHoldStart) > 20 then
    rHeld = false  -- missed key-up; do not hold the keyboard hostage
  end
  if readerIndex >= #readerWords then return end
  readerIndex = readerIndex + 1
  renderReaderWord()
  if rHeld then
    readerTimer = hs.timer.doAfter(wordDelay(readerWords[readerIndex]), advance)
  end
end

local function startAdvancing()
  if readerTimer or not reader then return end
  rHoldStart = os.time()
  if readerIndex >= #readerWords then return end
  readerTimer = hs.timer.doAfter(wordDelay(readerWords[readerIndex]), advance)
end

local function stopAdvancing()
  if readerTimer then readerTimer:stop() readerTimer = nil end
end

local function buildReader()
  local active = hs.mouse.getCurrentScreen() or hs.screen.mainScreen()
  -- dim every other screen too, so nothing bright pulls the eye away
  for _, scr in ipairs(hs.screen.allScreens()) do
    if scr:id() ~= active:id() then
      local sf = scr:fullFrame()
      local d = hs.canvas.new(sf)
      d:level(hs.canvas.windowLevels.modalPanel)
      d:behavior({ "canJoinAllSpaces", "stationary" })
      d:clickActivating(false)
      d[1] = { type = "rectangle", action = "fill", frame = { x = 0, y = 0, w = sf.w, h = sf.h },
               fillColor = DIM }
      d:show(0.12)
      dimmers[#dimmers + 1] = d
    end
  end

  local f = active:fullFrame()
  reader = hs.canvas.new(f)
  reader:level(hs.canvas.windowLevels.modalPanel)
  reader:behavior({ "canJoinAllSpaces", "stationary" })
  reader:clickActivating(false)
  reader[1] = { type = "rectangle", action = "fill",
                frame = { x = 0, y = 0, w = f.w, h = f.h }, fillColor = DIM }
  reader[2] = { type = "rectangle", action = "fill",
                frame = { x = 0, y = 0, w = 2, h = 14 },
                fillColor = { white = 1, alpha = 0.3 } }
  reader[3] = { type = "rectangle", action = "fill",
                frame = { x = 0, y = 0, w = 2, h = 14 },
                fillColor = { white = 1, alpha = 0.3 } }
  reader[4] = { type = "text", text = "", frame = { x = 0, y = 0, w = f.w, h = 100 },
                textAlignment = "left" }
  reader[5] = { type = "rectangle", action = "fill",
                frame = { x = 0, y = f.h - 3, w = 0, h = 3 },
                fillColor = { red = 1, green = 0.36, blue = 0.30, alpha = 0.85 } }
  -- speed chip: hidden until a speed key is pressed, then fades out again
  reader[6] = { type = "rectangle", action = "skip",
                roundedRectRadii = { xRadius = 17, yRadius = 17 },
                frame = { x = 0, y = 0, w = 116, h = 34 },
                fillColor = { red = 0.13, green = 0.13, blue = 0.15, alpha = 0 } }
  reader[7] = { type = "text", action = "skip", text = "", textSize = 14,
                frame = { x = 0, y = 0, w = 116, h = 20 },
                textAlignment = "center", textColor = { white = 1, alpha = 0 } }
  reader:show(0.12)
end

-- While the panel is open it owns R, the arrows and escape; everything else
-- passes through untouched so the machine is still usable.
local function startReaderTap()
  readerTap = hs.eventtap.new(
    { hs.eventtap.event.types.keyDown, hs.eventtap.event.types.keyUp },
    function(e)
      if not reader then return false end
      local down = (e:getType() == hs.eventtap.event.types.keyDown)
      local key = hs.keycodes.map[e:getKeyCode()]
      if key == "r" then
        if down then
          if not rHeld then rHeld = true startAdvancing() end
        else
          rHeld = false
          stopAdvancing()
        end
        return true
      elseif key == "escape" and down then
        closeReader()
        return true
      elseif (key == "up" or key == "=") and down then
        readerWpm = math.min(1200, readerWpm + 25)
        hs.settings.set("tttReaderWpm", readerWpm)
        showSpeedChip()
        return true
      elseif (key == "down" or key == "-") and down then
        readerWpm = math.max(100, readerWpm - 25)
        hs.settings.set("tttReaderWpm", readerWpm)
        showSpeedChip()
        return true
      elseif key == "left" and down then
        readerIndex = math.max(1, readerIndex - 1)
        renderReaderWord()
        return true
      elseif key == "right" and down then
        readerIndex = math.min(#readerWords, readerIndex + 1)
        renderReaderWord()
        return true
      end
      return false
    end)
  readerTap:start()
end

local function openReaderWith(text)
  readerWords = {}
  for w in text:gmatch("%S+") do readerWords[#readerWords + 1] = w end
  if #readerWords == 0 then
    hs.alert.show("Nothing to read")
    return
  end
  closeReader()
  readerIndex = 1
  buildReader()
  renderReaderWord()
  startReaderTap()
end

-- Exposed so scripts (and `hs -c`) can drive or dismiss the reader.
tttReadText = openReaderWith
tttCloseReader = closeReader
-- queryable so scripts (and tests) can tell whether the reader is up
tttReaderStatus = function()
  if not reader then return "closed" end
  return string.format("open %d/%d: %s", readerIndex, #readerWords,
                       tostring(readerWords[readerIndex]))
end

local function openReaderFromSelection()
  if reader then closeReader() return end
  local previous = hs.pasteboard.getContents()
  local changeCount = hs.pasteboard.changeCount()
  hs.eventtap.keyStroke({ "cmd" }, "c")
  hs.timer.doAfter(0.25, function()
    local selection = nil
    if hs.pasteboard.changeCount() ~= changeCount then
      selection = hs.pasteboard.getContents()
      if previous then hs.pasteboard.setContents(previous) end
    end
    if selection and #selection > 0 then
      openReaderWith(selection)
    else
      hs.alert.show("No text selected")
    end
  end)
end

-- ---------------------------------------------------------------------------
-- Menu bar item: always present next to the clock, so the controls and
-- options are reachable whether or not anything is currently speaking.
-- ---------------------------------------------------------------------------

local CONFIG_FILE = KOKORO_DIR .. "/config.json"

local VOICES = {
  { "American female", { "af_heart", "af_bella", "af_nicole", "af_sarah",
                         "af_sky", "af_nova", "af_alloy", "af_aoede",
                         "af_jessica", "af_kore", "af_river" }, "en-us" },
  { "American male",   { "am_michael", "am_adam", "am_puck", "am_echo",
                         "am_eric", "am_fenrir", "am_liam", "am_onyx" }, "en-us" },
  { "British female",  { "bf_emma", "bf_isabella", "bf_alice", "bf_lily" }, "en-gb" },
  { "British male",    { "bm_george", "bm_fable", "bm_daniel", "bm_lewis" }, "en-gb" },
}
local SPEEDS = { 0.8, 0.9, 1.0, 1.1, 1.25, 1.5 }

local function readConfig()
  local f = io.open(CONFIG_FILE, "r")
  if not f then return { voice = "af_heart", speed = 1.1, lang = "en-us" } end
  local raw = f:read("*a") or ""
  f:close()
  local ok, cfg = pcall(hs.json.decode, raw)
  if not ok or type(cfg) ~= "table" then
    return { voice = "af_heart", speed = 1.1, lang = "en-us" }
  end
  cfg.voice = cfg.voice or "af_heart"
  cfg.speed = cfg.speed or 1.1
  cfg.lang = cfg.lang or "en-us"
  return cfg
end

local function writeConfig(cfg)
  local f = io.open(CONFIG_FILE, "w")
  if f then f:write(hs.json.encode(cfg)) f:close() end
end

local menubar = nil

local MENU_COLORS = {
  idle         = { white = 0.55, alpha = 1 },
  loading      = { red = 0.95, green = 0.60, blue = 0.10, alpha = 1 },
  synthesizing = { red = 0.95, green = 0.60, blue = 0.10, alpha = 1 },
  playing      = { red = 0.20, green = 0.72, blue = 0.32, alpha = 1 },
  paused       = { red = 0.90, green = 0.75, blue = 0.10, alpha = 1 },
  ready        = { red = 0.30, green = 0.50, blue = 0.95, alpha = 1 },
}
local MENU_GLYPH = {
  idle = "◍", loading = "◐", synthesizing = "◐",
  playing = "◉", paused = "◑", ready = "◈",
}

local function updateMenubar()
  if not menubar then return end
  local st = currentState
  menubar:setTitle(hs.styledtext.new(MENU_GLYPH[st] or "◍", {
    font = { name = "Helvetica", size = 14 },
    color = MENU_COLORS[st] or MENU_COLORS.idle,
  }))
end

local function buildMenu()
  local cfg = readConfig()
  local st = currentState
  local speaking = (st == "playing" or st == "paused")
  local items = {}

  local statusText = ({ idle = "Idle", loading = "Loading model…",
                        synthesizing = "Preparing…", playing = "Speaking",
                        paused = "Paused", ready = "Reply ready" })[st] or st
  table.insert(items, { title = statusText, disabled = true })
  table.insert(items, { title = "-" })

  if st == "ready" then
    table.insert(items, { title = "Play reply", fn = playPending })
    table.insert(items, { title = "Dismiss reply", fn = dismissReady })
  else
    table.insert(items, {
      title = (st == "paused") and "Resume" or "Pause",
      disabled = not speaking,
      fn = function() ktts("toggle") end,
    })
    table.insert(items, { title = "Rewind 10s", disabled = not speaking,
                          fn = function() ktts("back") end })
    table.insert(items, { title = "Stop", disabled = not speaking,
                          fn = function() ktts("stop") end })
  end
  table.insert(items, { title = "-" })
  table.insert(items, { title = "Read selection", fn = readSelection })
  table.insert(items, { title = "Read clipboard", fn = function()
    local clip = hs.pasteboard.getContents()
    if not clip or #clip == 0 then hs.alert.show("Clipboard is empty") return end
    local f = io.open(SELECTION_FILE, "w")
    if f then f:write(clip) f:close() deliverFile(SELECTION_FILE) end
  end })
  table.insert(items, { title = "-" })
  table.insert(items, { title = "Read selection silently (RSVP)…",
                        fn = openReaderFromSelection })
  if reader then
    table.insert(items, { title = "Close reader", fn = closeReader })
  end
  table.insert(items, { title = "Read clipboard silently (RSVP)…",
                        fn = function()
                          openReaderWith(hs.pasteboard.getContents() or "")
                        end })

  local wpmMenu = {}
  for _, wpm in ipairs({ 200, 250, 300, 350, 400, 500, 600, 800 }) do
    table.insert(wpmMenu, {
      title = wpm .. " wpm",
      checked = (readerWpm == wpm),
      fn = function()
        readerWpm = wpm
        hs.settings.set("tttReaderWpm", wpm)
      end,
    })
  end
  table.insert(items, {
    title = "Reader speed (" .. readerWpm .. " wpm)",
    menu = wpmMenu,
  })
  if reader then
    table.insert(items, {
      title = string.format("Reader position: %d / %d", readerIndex, #readerWords),
      disabled = true,
    })
  end
  table.insert(items, { title = "-" })
  local cfg2 = readCfg()
  table.insert(items, { title = "Auto-read replies", checked = autoRead,
                        fn = toggleAutoRead })
  table.insert(items, {
    title = "TLDR — summarise before reading",
    checked = cfg2.tldr_replies == true,
    fn = toggleTldr,
  })
  table.insert(items, {
    title = "Reader mode — show instead of speaking",
    checked = readerMode,
    fn = toggleReaderMode,
  })
  table.insert(items, {
    title = "Read the last reply",
    disabled = tldrRunning or currentState ~= "ready",
    fn = playPending,
  })

  local PROVIDERS = {
    { "claude-cli", "Claude Code CLI (no key, uses your plan)" },
    { "anthropic",  "Claude API (needs key)" },
    { "openai",     "ChatGPT API (needs key)" },
    { "extractive", "Local, no AI (free, instant)" },
  }
  local MODELS = {
    ["claude-cli"] = { "haiku", "sonnet", "opus" },
    ["anthropic"]  = { "claude-haiku-4-5-20251001", "claude-sonnet-5", "claude-opus-5" },
    ["openai"]     = { "gpt-4o-mini", "gpt-4o" },
    ["extractive"] = {},
  }
  local current = cfg2.tldr_provider or "claude-cli"

  local provMenu = {}
  for _, pr in ipairs(PROVIDERS) do
    table.insert(provMenu, {
      title = pr[2],
      checked = (current == pr[1]),
      fn = function()
        local c = readCfg()
        c.tldr_provider = pr[1]
        c.tldr_model = nil  -- fall back to that provider's default
        writeCfg(c)
        hs.alert.show("TLDR via " .. pr[2])
      end,
    })
  end
  table.insert(provMenu, { title = "-" })
  table.insert(provMenu, { title = "Store Claude API key…", fn = function()
    hs.pasteboard.setContents("ttt-set-key anthropic")
    hs.alert.show("Command copied — paste it in Terminal.\nYour key is typed straight into the Keychain.", 5)
  end })
  table.insert(provMenu, { title = "Set Claude workspace id…", fn = function()
    local c = readCfg()
    local btn, val = hs.dialog.textPrompt("Claude workspace id",
      "Identity-linked API keys must name a workspace.\n"
      .. "Find it in console.anthropic.com → Settings → Workspaces (wrkspc_…):",
      c.anthropic_workspace_id or "", "Save", "Cancel")
    if btn == "Save" and val then
      val = val:gsub("^%s+", ""):gsub("%s+$", "")
      c.anthropic_workspace_id = (#val > 0) and val or nil
      writeCfg(c)
      hs.alert.show(#val > 0 and ("Workspace: " .. val) or "Workspace id cleared")
    end
  end })
  table.insert(provMenu, { title = "Store ChatGPT API key…", fn = function()
    hs.pasteboard.setContents("ttt-set-key openai")
    hs.alert.show("Command copied — paste it in Terminal.\nYour key is typed straight into the Keychain.", 5)
  end })
  table.insert(items, { title = "TLDR provider", menu = provMenu })

  local mdl = MODELS[current] or {}
  if #mdl > 0 then
    local modelMenu = {}
    local chosen = cfg2.tldr_model or mdl[1]
    for _, m in ipairs(mdl) do
      table.insert(modelMenu, {
        title = m,
        checked = (chosen == m),
        fn = function()
          local c = readCfg()
          c.tldr_model = m
          writeCfg(c)
        end,
      })
    end
    table.insert(modelMenu, { title = "-" })
    table.insert(modelMenu, { title = "Custom model…", fn = function()
      local ok, val = hs.dialog.textPrompt("TLDR model",
        "Model identifier to send to the " .. current .. " API:",
        cfg2.tldr_model or "", "Use", "Cancel")
      if ok == "Use" and val and #val > 0 then
        local c = readCfg()
        c.tldr_model = val
        writeCfg(c)
      end
    end })
    table.insert(items, { title = "TLDR model", menu = modelMenu })
  end

  local lenMenu = {}
  for _, n in ipairs({ 1, 2, 3, 5 }) do
    table.insert(lenMenu, {
      title = n .. (n == 1 and " sentence" or " sentences"),
      checked = ((cfg2.tldr_sentences or 3) == n),
      fn = function()
        local c = readCfg()
        c.tldr_sentences = n
        writeCfg(c)
      end,
    })
  end
  table.insert(items, { title = "TLDR length", menu = lenMenu })
  table.insert(items, { title = "Read-along words", checked = rsvpOn,
                        fn = toggleRsvp })

  local voiceMenu = {}
  for _, group in ipairs(VOICES) do
    local groupName, ids, lang = group[1], group[2], group[3]
    local sub = {}
    for _, id in ipairs(ids) do
      local label = id:gsub("^%a+_", "")
      table.insert(sub, {
        title = label:sub(1, 1):upper() .. label:sub(2),
        checked = (cfg.voice == id),
        fn = function()
          local c = readConfig()
          c.voice, c.lang = id, lang
          writeConfig(c)
          hs.alert.show("Voice: " .. id)
        end,
      })
    end
    table.insert(voiceMenu, { title = groupName, menu = sub })
  end
  table.insert(items, { title = "Voice", menu = voiceMenu })

  local speedMenu = {}
  for _, sp in ipairs(SPEEDS) do
    table.insert(speedMenu, {
      title = string.format("%.2gx", sp),
      checked = (math.abs((cfg.speed or 1.1) - sp) < 0.001),
      fn = function()
        local c = readConfig()
        c.speed = sp
        writeConfig(c)
        hs.alert.show(string.format("Speed: %.2gx", sp))
      end,
    })
  end
  table.insert(items, { title = "Speed", menu = speedMenu })

  table.insert(items, { title = "-" })
  table.insert(items, { title = "Hotkeys…", fn = function()
    hs.alert.show("⌃⌥S read selection\n⌃⌥P read reply / pause\n"
      .. "⌃⌥← rewind 10s\n⌃⌥X stop\n⌃⌥A auto-read\n"
      .. "⌃⌥T TLDR on/off · ⌃⌥R reader mode on/off\n"
      .. "   in the reader: hold R to read · ↑↓ speed\n"
      .. "   ←→ step a word · esc close", 6)
  end })
  table.insert(items, { title = "Reset pill position", fn = function()
    hs.settings.clear("tttPillPos")
    hs.alert.show("Pill returns to the top right")
  end })
  table.insert(items, { title = "Restart speech engine", fn = function()
    ktts("quit")
    hs.alert.show("Engine will reload on next use")
  end })
  return items
end

menubar = hs.menubar.new()
if menubar then
  menubar:setMenu(buildMenu)  -- rebuilt on every click, so it is never stale
  updateMenubarRef = updateMenubar
  updateMenubar()
end

-- Hotkeys (bound last so they can see the pill state helpers above)
hs.hotkey.bind({ "ctrl", "alt" }, "s", readSelection)
hs.hotkey.bind({ "ctrl", "alt" }, "p", function()
  if currentState == "ready" then playPending() else ktts("toggle") end
end)
hs.hotkey.bind({ "ctrl", "alt" }, "x", function()
  if currentState == "ready" then dismissReady() else ktts("stop") end
end)
hs.hotkey.bind({ "ctrl", "alt" }, "a", toggleAutoRead)
hs.hotkey.bind({ "ctrl", "alt" }, "left", function() ktts("back") end)
hs.hotkey.bind({ "ctrl", "alt" }, "r", toggleReaderMode)
hs.hotkey.bind({ "ctrl", "alt" }, "t", toggleTldr)

-- Auto-pause while dictating with Wispr Flow (hold-Fn): pause speech when
-- the Fn key goes down, resume where it left off when it is released.
-- Kept global so the eventtap is never garbage-collected.
tttFnDictationWatcher = hs.eventtap.new(
  { hs.eventtap.event.types.flagsChanged },
  function(e)
    local fn = e:getFlags().fn or false
    if fn == fnHeld then return false end
    fnHeld = fn
    if fn then
      if currentState == "playing" then
        fnAutoPaused = true
        ktts("pause")
      end
    else
      if fnAutoPaused then
        fnAutoPaused = false
        if currentState == "paused" then ktts("resume") end
      end
    end
    return false
  end):start()

hs.alert.show("Talk Talk Talk loaded")
