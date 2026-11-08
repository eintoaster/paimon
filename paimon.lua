--[[
    paimon.lua  -  Paimon companion for lmaobox (TF2)
    https://github.com/eintoaster/paimon

    - Animated Paimon (53 frames) in the corner of your screen
    - Drag her anywhere while the lmaobox menu is open (her spot is remembered)
    - Genshin-style speech bubble: hit logs ("You hit Heavy for 54 damage! 246 HP left!"),
      lines when you get a kill or die, and a random voice line on kills
    - Installs her files by itself the first time (pictures, font and voice lines from GitHub):
        Team Fortress 2\destiny_files\paimon\frames\frame_N.png + Genshin_Impact.ttf
        Team Fortress 2\tf\sound\destiny_paimon\N.wav      (TF2 only plays sounds from its sound folder)

    (destiny.lua has Paimon built in too: don't load both, or you get two Paimons.)
]]

---------------------------------------------------------------------------
-- Settings: change these to your liking
---------------------------------------------------------------------------
local SIZE          = 1.0     -- 1.0 = normal, 0.5 = half, 2.0 = double
local VOICE_ON_KILL = true    -- play a random voice line when you get a kill
local HIT_LOGS      = true    -- bubble on every hit: who, how much damage, HP left
local HIT_LOG_TIME  = 4       -- seconds a hit log stays
local KILL_LINES    = true    -- bubble lines on kills and deaths
local GENSHIN_FONT  = true    -- use the Genshin font in her bubble

---------------------------------------------------------------------------
-- Files
---------------------------------------------------------------------------
local FRAMES, VOICES = 53, 57
local W0, H0 = 397, 465                                     -- size of one frame
local floor, min, max = math.floor, math.min, math.max

local function exists(path)
    local ok, f = pcall(io.open, path, "rb")
    if ok and f then f:close(); return true end
    return false
end

local function installed()
    return exists("destiny_files/paimon/frames/frame_52.png") and exists("destiny_files/paimon/Genshin_Impact.ttf")
        and exists("tf/sound/destiny_paimon/57.wav")
end

-- installer: lmaobox's http library can't carry binary files (the data stops at the first zero byte), so the
-- files are downloaded as base64 text copies (paimon_frames_b64/, paimon_voice_b64/, Genshin_Impact.b64) and
-- turned back into the real files a little every frame. Small files first, the 15 MB font last. Requests are
-- started from the frame loop only (starting one inside a download's callback made lmaobox answer
-- "ERROR READ Network read"), and a failed file is tried again from a second server.
local MIRRORS = { "https://cdn.jsdelivr.net/gh/eintoaster/paimon@main/", "https://raw.githubusercontent.com/eintoaster/paimon/main/" }
local inst = { state = "idle", idx = 0, done = 0, failed = 0, current = "", list = nil, job = nil, why = nil,
               waiting = false, result = nil, try = 1, startNext = false }

local function fileList()
    if inst.list then return inst.list end
    local l = {}
    for i = 0, FRAMES - 1 do l[#l + 1] = { "paimon_frames_b64/frame_" .. i .. ".b64", "destiny_files/paimon/frames/frame_" .. i .. ".png", "png" } end
    for i = 1, VOICES do l[#l + 1] = { "paimon_voice_b64/" .. i .. ".b64", "tf/sound/destiny_paimon/" .. i .. ".wav", "wav" } end
    l[#l + 1] = { "Genshin_Impact.b64", "destiny_files/paimon/Genshin_Impact.ttf", "ttf" }
    inst.list = l
    return l
end

-- base64 -> bytes for the text between positions i and j
local B64 = {}
do
    local a = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    for i = 1, 64 do B64[a:byte(i)] = i - 1 end
end
local b64buf = {}
local function b64(s, i, j)
    local out, bn = {}, 0
    for k = i, j, 4 do
        local a, b, c, d = string.byte(s, k, k + 3)
        local va, vb = B64[a], B64[b]
        if not va or not vb then break end
        local vc, vd = B64[c], B64[d]
        local v = va * 262144 + vb * 4096 + (vc or 0) * 64 + (vd or 0)
        bn = bn + 1; b64buf[bn] = v >> 16
        if vc then bn = bn + 1; b64buf[bn] = (v >> 8) & 255 end
        if vd then bn = bn + 1; b64buf[bn] = v & 255 end
        if bn >= 3000 then out[#out + 1] = string.char(table.unpack(b64buf, 1, bn)); bn = 0 end
    end
    if bn > 0 then out[#out + 1] = string.char(table.unpack(b64buf, 1, bn)) end
    return table.concat(out)
end

local SIG = { png = function(h) return h:sub(2, 4) == "PNG" end, wav = function(h) return h:sub(1, 4) == "RIFF" end,
              ttf = function(h) return h:sub(1, 4) == "\0\1\0\0" or h:sub(1, 4) == "OTTO" or h:sub(1, 4) == "true" end }

local function check(f, data)
    if type(data) ~= "string" or #data < 16 then return nil, "got " .. (type(data) == "string" and #data or 0) .. " bytes" end
    if data:sub(1, 5) == "ERROR" then return nil, data:sub(1, 40) end
    if #data % 4 ~= 0 or data:find("[^%w%+/=]") then data = data:gsub("[^%w%+/=]", "") end
    if not SIG[f[3]](b64(data, 1, 16)) then return nil, "not a " .. f[3] end
    return data
end

-- the callback only hands the answer over; everything else happens in the frame loop
local function request(f)
    inst.waiting, inst.result = true, nil
    -- (waits for the answer: lmaobox's background downloads fail above ~20 KB with "WinINet Error Code: 6",
    --  the waiting one works. The game pauses for a moment per file, only while installing.)
    local ok, data = pcall(http.Get, MIRRORS[inst.try] .. f[1])
    inst.result = { f = f, data = ok and data or nil }
end

local clock = (os and os.clock) or function() return 0 end

-- runs every frame while installing: start the next download, take an answer, decode about 3 ms worth
local function installWork()
    if inst.state ~= "downloading" then return end
    if inst.startNext and not inst.waiting and not inst.job then
        inst.startNext = false
        inst.idx, inst.try = inst.idx + 1, 1
        local f = fileList()[inst.idx]
        if not f then
            inst.state = (inst.failed == 0) and "done" or "failed"
            print("[paimon] install finished: " .. inst.done .. " files, " .. inst.failed .. " failed"
                  .. (inst.why and (" (last: " .. inst.why .. ")") or ""))
            return
        end
        inst.current = f[2]:match("[^/]+$")
        request(f)
        return
    end
    if inst.waiting and inst.result then
        local f, data = inst.result.f, inst.result.data
        inst.waiting, inst.result = false, nil
        local text, why = check(f, data)
        if not text then
            if inst.try < #MIRRORS then inst.try = inst.try + 1; request(f); return end
            inst.failed, inst.why, inst.startNext = inst.failed + 1, inst.current .. ": " .. why, true
            return
        end
        local ok, fh = pcall(io.open, f[2], "wb")
        if not ok or not fh then
            inst.failed, inst.why, inst.startNext = inst.failed + 1, "can't write " .. f[2], true
            return
        end
        inst.job = { data = text, pos = 1, fh = fh }
    end
    local job = inst.job
    if job then
        local t0, n = clock(), #job.data
        repeat
            local j = math.min(n, job.pos + 49151)
            job.fh:write(b64(job.data, job.pos, j))
            job.pos = j + 1
        until job.pos > n or (clock() - t0) > 0.003
        if job.pos > n then
            job.fh:close()
            inst.job = nil
            inst.done = inst.done + 1
            inst.startNext = true
        end
    end
end

local function install()
    if inst.state == "downloading" then return end
    if not http or not io then print("[paimon] can't install: lmaobox blocks downloads or files"); return end
    for _, d in ipairs({ "destiny_files", "destiny_files/paimon", "destiny_files/paimon/frames", "tf/sound", "tf/sound/destiny_paimon" }) do
        pcall(filesystem.CreateDirectory, d)
    end
    inst.state, inst.idx, inst.done, inst.failed, inst.why = "downloading", 0, 0, 0, nil
    inst.job, inst.waiting, inst.result, inst.try, inst.startNext = nil, false, nil, 1, true
end

---------------------------------------------------------------------------
-- Drawing helpers
---------------------------------------------------------------------------
local function round(v) return floor(v + 0.5) end
local function clamp(v, a, b) return max(a, min(b, v)) end
local function now() return globals.RealTime() end

local WHITE = draw.CreateTextureRGBA(string.rep(string.char(255), 16), 2, 2)
local CIRCLE                                                   -- a smooth 64 px circle picture
do
    local px = {}
    for y = 0, 63 do
        for x = 0, 63 do
            local d = math.sqrt((x + 0.5 - 32) ^ 2 + (y + 0.5 - 32) ^ 2)
            px[#px + 1] = string.char(255, 255, 255, round(clamp(31.5 - d, 0, 1) * 255))
        end
    end
    CIRCLE = draw.CreateTextureRGBA(table.concat(px), 64, 64)
end

local function setColor(c, a) draw.Color(c[1], c[2], c[3], clamp(round(a or 255), 1, 255)) end

-- a pill: a rectangle with a half circle on each end
local function pill(x, y, w, h, c, a)
    setColor(c, a)
    local r = h / 2
    draw.FilledRect(round(x + r), round(y), round(x + w - r), round(y + h))
    draw.TexturedRect(CIRCLE, round(x), round(y), round(x + h), round(y + h))
    draw.TexturedRect(CIRCLE, round(x + w - h), round(y), round(x + w), round(y + h))
end

local fontSmall = draw.CreateFont("Segoe UI", 16, 600, FONTFLAG_ANTIALIAS)
local fontGenshin = nil
local function bubbleFont()
    if not GENSHIN_FONT then return fontSmall end
    if fontGenshin == nil then
        fontGenshin = false
        if installed() then
            pcall(draw.AddFontResource, "destiny_files/paimon/Genshin_Impact.ttf")
            local ok, id = pcall(draw.CreateFont, "Default_SC", 17, 600, FONTFLAG_ANTIALIAS)   -- (the font's own name)
            if ok and id then fontGenshin = id end
        end
    end
    return fontGenshin or fontSmall
end

---------------------------------------------------------------------------
-- Paimon
---------------------------------------------------------------------------
local tex, loaded = {}, 0
local frame, frameAt = 0, 0
local pos = nil                                                -- {x, y}, nil = bottom right
local drag = nil
local wasDown = false
local bubble = { text = nil, t0 = -99, dur = 3.2 }
local voiceUntil, lastVoice = -99, 0

-- where she was dragged to last time
local function loadPos()
    local ok, f = pcall(io.open, "destiny_files/paimon/position.txt", "r")
    if ok and f then
        local s = f:read("*a") or ""
        f:close()
        local x, y = s:match("(-?%d+),(-?%d+)")
        if x then pos = { tonumber(x), tonumber(y) } end
    end
end
local function savePos()
    if not pos then return end
    local ok, f = pcall(io.open, "destiny_files/paimon/position.txt", "w")
    if ok and f then f:write(floor(pos[1]) .. "," .. floor(pos[2])); f:close() end
end
loadPos()

local frameDir
local function framePath(i)
    if not frameDir then
        local ok, gd = pcall(engine.GetGameDir)
        gd = (ok and gd) and tostring(gd) or ""
        frameDir = gd:gsub("[\\/]tf[\\/]?$", "") .. "\\destiny_files\\paimon\\frames\\frame_"
    end
    return frameDir .. i .. ".png"
end

local function loadSome()                                       -- a few pictures per frame, no hitch
    local n = 0
    while loaded < FRAMES and n < 4 do
        local ok, id = pcall(draw.CreateTexture, framePath(loaded))
        tex[loaded] = ok and id or false
        loaded = loaded + 1
        n = n + 1
    end
end

-- her lines (%c = class, %w = weapon)
local LINES = {
    kill      = { "Paimon saw that! Nice one!", "Another one down~ Ehe!", "Too easy! Paimon could do that too... probably.",
                  "Woohoo! Paimon is cheering for you!", "That's how it's done, traveler!" },
    killClass = { "Bye bye, %c! Hehe~", "That %c is toast!", "Paimon gives that %c a zero out of ten!", "One %c down! Who's next?" },
    headshot  = { "Right in the head! Paimon is impressed!", "Headshot! Paimon didn't even blink!", "Boom! Perfect aim!" },
    backstab  = { "So sneaky! Paimon didn't even see you!", "Right in the back! Hehe~" },
    death     = { "Hey! That's not fair!", "Ouch... Paimon felt that one.", "Get up! We're not done yet!" },
    deathBy   = { "That %c is so mean! Paimon gives them an ugly nickname!", "Grr, that %c again!" },
}
local CLASSES = { "Scout", "Sniper", "Soldier", "Demoman", "Medic", "Heavy", "Pyro", "Spy", "Engineer" }

local function say(text, dur) bubble.text, bubble.t0, bubble.dur = text, now(), dur or 3.2 end
local function sayLine(kind, class)
    local list = LINES[kind]
    local s = list[math.random(#list)]
    if s:find("%%c") then
        if not class then s = LINES.kill[math.random(#LINES.kill)] else s = s:gsub("%%c", class) end
    end
    say(s)
end

local function voiceLength(i)
    local ok, f = pcall(io.open, "tf/sound/destiny_paimon/" .. i .. ".wav", "rb")
    if not ok or not f then return 2 end
    local size = f:seek("end")
    f:close()
    return (size or 0) / (44100 * 4)                          -- 16-bit stereo 44.1 kHz
end

local function speak()
    if now() < voiceUntil or not installed() then return end
    local i
    repeat i = math.random(1, VOICES) until i ~= lastVoice
    lastVoice = i
    pcall(engine.PlaySound, "destiny_paimon/" .. i .. ".wav")
    voiceUntil = now() + voiceLength(i)
end

local BG, EDGE, TXT = { 236, 229, 216 }, { 196, 186, 166 }, { 73, 83, 102 }

local function drawBubble(cx, bottomY, s, alpha)
    local font = bubbleFont()
    draw.SetFont(font)
    local tw, th = draw.GetTextSize(s)
    local w, h = tw + 30, 30
    local x, y = cx - w / 2, bottomY - h - 8
    pill(x - 1, y - 1, w + 2, h + 2, EDGE, 200 * alpha)
    pill(x, y, w, h, BG, 245 * alpha)
    setColor(BG, 245 * alpha)
    draw.TexturedPolygon(WHITE, { { cx - 7, y + h - 1, 0.5, 0.5 }, { cx + 7, y + h - 1, 0.5, 0.5 }, { cx, y + h + 7, 0.5, 0.5 } }, false)
    setColor(TXT, 255 * alpha)
    draw.Text(round(cx - tw / 2), round(y + (h - th) / 2), s)
end

local function onDraw()
    if engine.IsTakingScreenshot() then return end
    local sw, sh = draw.GetScreenSize()

    if not installed() then
        if inst.state == "idle" then install() end                 -- installs by itself the first time
        installWork()
        draw.SetFont(fontSmall)
        draw.Color(255, 255, 255, 230)
        local msg = (inst.state == "downloading")
            and string.format("Installing Paimon... %d / %d  (%s)", inst.done + inst.failed, #fileList(), inst.current)
            or ("Paimon: install failed (" .. tostring(inst.why) .. ") - reload the script to try again")
        draw.Text(20, sh - 40, msg)
        return
    end

    loadSome()
    local t = now()
    local steps = floor((t - frameAt) / 0.03)                       -- 30 ms per frame, like before
    if steps > 0 then
        frame = (frame + steps) % FRAMES
        frameAt = (steps > 10) and t or (frameAt + steps * 0.03)
    end

    local W, H = W0 / 2.8 * SIZE, H0 / 2.8 * SIZE
    local x = pos and pos[1] or (sw - W - 20)
    local y = pos and pos[2] or (sh - H - 20)

    -- drag her while the lmaobox menu is open
    local menuOpen = gui.IsMenuOpen()
    local down = input.IsButtonDown(MOUSE_LEFT)
    local ok, m = pcall(input.GetMousePos)
    local mx, my = (ok and type(m) == "table") and m[1] or 0, (ok and type(m) == "table") and m[2] or 0
    if menuOpen and down and not wasDown and mx >= x and mx < x + W and my >= y and my < y + H then
        drag = { mx - x, my - y }
    end
    if drag then
        if down and menuOpen then
            x, y = clamp(mx - drag[1], 0, sw - W), clamp(my - drag[2], 0, sh - H)
            pos = { x, y }
        else
            drag = nil
            savePos()
        end
    end
    wasDown = down

    local id = tex[frame] or tex[0]
    if id then
        draw.Color(255, 255, 255, 255)
        draw.TexturedRect(id, round(x), round(y), round(x + W), round(y + H))
    end

    if bubble.text and t - bubble.t0 < bubble.dur then
        local a = clamp((t - bubble.t0) / 0.2, 0, 1) * clamp((bubble.dur - (t - bubble.t0)) / 0.3, 0, 1)
        drawBubble(x + W / 2, y + H * 0.06, bubble.text, a)
    end
end

---------------------------------------------------------------------------
-- Game events
---------------------------------------------------------------------------
local function myUserID()
    local lp = entities.GetLocalPlayer()
    if not lp then return nil end
    local info = client.GetPlayerInfo(lp:GetIndex())
    return info and info.UserID
end

local function classOf(uid)
    local ent = entities.GetByUserID(uid)
    if not ent then return nil end
    local ok, c = pcall(ent.GetPropInt, ent, "m_PlayerClass", "m_iClass")
    return ok and CLASSES[c] or nil
end

local function nameOf(uid)
    local ok, n = pcall(client.GetPlayerNameByUserID, uid)
    return (ok and n and n ~= "") and n or "someone"
end

local function onEvent(e)
    local name = e:GetName()
    if name ~= "player_death" and name ~= "player_hurt" then return end
    local mine = myUserID()
    if not mine then return end
    local victim, attacker = e:GetInt("userid"), e:GetInt("attacker")

    if name == "player_hurt" then
        if HIT_LOGS and attacker == mine and victim ~= mine then
            local class = classOf(victim)
            local who = nameOf(victim) .. (class and (" (" .. class .. ")") or "")
            local hp = e:GetInt("health")
            local crit = e:GetInt("crit") == 1 and "Crit! " or ""
            if hp > 0 then say(string.format("%sYou hit %s for %d damage! %d HP left!", crit, who, e:GetInt("damageamount"), hp), HIT_LOG_TIME)
            else say(string.format("%sYou hit %s for %d damage!", crit, who, e:GetInt("damageamount")), HIT_LOG_TIME) end
        end
        return
    end

    if attacker == mine and victim ~= mine then
        local custom = e:GetInt("customkill")
        if KILL_LINES then
            if custom == 1 then sayLine("headshot")
            elseif custom == 2 then sayLine("backstab")
            elseif math.random() < 0.5 then sayLine("killClass", classOf(victim))
            else sayLine("kill") end
        end
        if VOICE_ON_KILL then speak() end
    elseif victim == mine and KILL_LINES then
        if attacker ~= mine and attacker ~= 0 and math.random() < 0.6 then sayLine("deathBy", classOf(attacker))
        else sayLine("death") end
    end
end

callbacks.Register("Draw", "paimon_draw", function()
    local ok, err = pcall(onDraw)
    if not ok and not inst.reported then inst.reported = true; print("[paimon] " .. tostring(err)) end
end)
callbacks.Register("FireGameEvent", "paimon_events", function(e) pcall(onEvent, e) end)
callbacks.Register("Unload", "paimon_unload", function()
    savePos()
    for _, id in pairs(tex) do if id then pcall(draw.DeleteTexture, id) end end
    pcall(draw.DeleteTexture, WHITE)
    pcall(draw.DeleteTexture, CIRCLE)
    callbacks.Unregister("Draw", "paimon_draw")
    callbacks.Unregister("FireGameEvent", "paimon_events")
end)

print("[paimon] loaded" .. (installed() and "" or " - installing her files from GitHub..."))
