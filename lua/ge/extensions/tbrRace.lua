-- GE Lua: TBR duel. Rollback + simplification build.
local M = {}

local CFG = {
  -- switches (live: extensions.tbrRace.set('name', value); driveInLane applies on next challenge)
  enableLanes   = true,
  driveInLane   = false,  -- false = free driving (the fast setup from test 2)
  allowLeftPass = true,   -- false = only pass on the right

  -- finding the rival / race rules
  maxDist = 60, minDist = 4, minDot = 0.85, sameDirDot = 0.7, minRivalSpeed = 5,
  countdown = 3, winGap = 120, winHold = 2.0, maxDist_abort = 500, timeout = 180,
  playerStuck = 6, rivalStuck = 8, cooldown = 5,

  -- full send
  aggression = 1.0,
  topSpeed   = 100,       -- m/s, effectively no limit

  -- swerve brain
  tick         = 0.25,    -- s between decisions
  lookTime     = 3.5,     -- s: blocker counts if closer than closingSpeed * lookTime
  lookMin      = 30,      -- m
  lookMax      = 180,     -- m
  minClosing   = 1.0,     -- m/s: must be catching the car for it to block him
  gapAfter     = 6,       -- m: how close he lets himself get to the blocker
  laneTimeSpan = 2.8,     -- s of travel for one lane change (bigger = smoother)
  laneCooldown = 1.5,     -- s after a shift before the next decision
  zoneBase     = 7,       -- m: longitudinal safety zone around a car in the target lane
  zoneTime     = 0.35,    -- s * closing speed added to the zone
  margin       = 0.25,    -- m sideways clearance (profile later: rookie bigger, ace smaller)
  minRunway    = 45,      -- m free ahead in the target lane after the shift
  runCap       = 120,     -- m, runway above this counts the same
  waitCost     = 10,      -- scoring: m of runway given up per second of waiting
  leftPenalty  = 15,      -- scoring: m of runway given up for passing on the left
  laneSign     = 1,       -- set to -1 if he steers the wrong way (check with testShift)
  minLaneDist  = 40,
  maxLaneDist  = 260,

  -- road
  laneWidth = 3.5, minRoadW = 5.5, gridTolerance = 0.3, selfWidth = 1.85,

  logEvery = 2,           -- s, periodic race log line (0 = off)
}

local state = "idle"
local rivalId, timer, raceTime, lastMsg, cooldownLeft, tick = nil, 0, 0, 0, 0, 0
local axis, holdTimer, holdSign, pStuck, rStuck = nil, 0, 0, 0, 0
local shiftUntil, shiftCheckAt, shiftTarget, lastKind, logT = 0, nil, nil, "", 0
local warnedNoRoad, warnedOff = false, false

local function msg(text, ttl)
  guihooks.message(text, ttl or 2, "tbr")
  log('I', 'TBR', text)
end

local function playerVeh()
  local id = be:getPlayerVehicleID(0)
  if id and id >= 0 then return be:getObjectByID(id), id end
end

local function attach(id)
  local v = id and be:getObjectByID(id)
  if v then v:queueLuaCommand("extensions.load('tbrFlash')") end
end

local function widthOf(v)
  local ok, w = pcall(function() return v:getInitialWidth() end)
  if ok and type(w) == "number" and w > 0.8 and w < 4 then return w end
  return CFG.selfWidth
end

local function rightOf(dir)
  local r = dir:cross(vec3(0, 0, 1))
  local l = r:length()
  if l < 1e-6 then return vec3(1, 0, 0) end
  return r * (1 / l)
end

local function candidateIds(excludeId)
  local ids = {}
  if gameplay_traffic and gameplay_traffic.getTrafficList then
    local ok, list = pcall(gameplay_traffic.getTrafficList)
    if ok and list then for _, id in ipairs(list) do ids[#ids + 1] = id end end
  end
  if #ids == 0 then
    for i = 0, be:getObjectCount() - 1 do
      local v = be:getObject(i)
      if v then ids[#ids + 1] = v:getID() end
    end
  end
  local out = {}
  for _, id in ipairs(ids) do if id ~= excludeId then out[#out + 1] = id end end
  return out
end

----------------------------------------------------------------------
-- Rival search
----------------------------------------------------------------------
local function findRival(player, playerId)
  local pPos, pDir = player:getPosition(), player:getDirectionVector():normalized()
  local best, bestDist
  for _, id in ipairs(candidateIds(playerId)) do
    local v = be:getObjectByID(id)
    if v then
      local toV = v:getPosition() - pPos
      local dist = toV:length()
      if dist > CFG.minDist and dist < CFG.maxDist then
        local ahead = toV:normalized():dot(pDir)
        local sameDir = v:getDirectionVector():normalized():dot(pDir)
        local speed = v:getVelocity():length()
        if ahead > CFG.minDot and sameDir > CFG.sameDirDot and speed > CFG.minRivalSpeed then
          if not bestDist or dist < bestDist then best, bestDist = id, dist end
        end
      end
    end
  end
  return best
end

----------------------------------------------------------------------
-- Rival AI mode (set ONCE at GO, never re-sent)
----------------------------------------------------------------------
local function setRivalMode(id, racing)
  local v = be:getObjectByID(id)
  if not v then return end
  if racing then
    v:queueLuaCommand(string.format([[
      ai.setMode('random')
      ai.setAggression(%.2f)
      ai.driveInLane('%s')
      pcall(function() ai.setAvoidCars('on') end)
      ai.setSpeedMode('limit')
      ai.setSpeed(%.1f)
    ]], CFG.aggression, CFG.driveInLane and "on" or "off", CFG.topSpeed))
  else
    v:queueLuaCommand([[
      ai.setMode('traffic')
      ai.setAggression(0.3)
      ai.setSpeedMode('legal')
      ai.driveInLane('on')
    ]])
  end
end

----------------------------------------------------------------------
-- Road info (lat = sideways position from road center, + = right)
----------------------------------------------------------------------
local function getRoadInfo(veh)
  if not (map and map.findClosestRoad and map.getMap) then return nil end
  local okm, m = pcall(map.getMap)
  if not okm or not m or not m.nodes then return nil end

  local pos = veh:getPosition()
  local a, b = map.findClosestRoad(pos)
  if not a or not b then return nil end
  local na, nb = m.nodes[a], m.nodes[b]
  if not na or not nb or not na.pos or not nb.pos then return nil end

  local pa, pb = na.pos, nb.pos
  local ab = pb - pa
  local len2 = ab:dot(ab)
  if len2 < 1e-6 then return nil end
  local t = math.max(0, math.min(1, (pos - pa):dot(ab) / len2))
  local cp = pa + ab * t
  local rad = (na.radius or 0) + ((nb.radius or 0) - (na.radius or 0)) * t
  local W = rad * 2
  if W < 2.5 then return nil end

  local f = vec3(ab.x, ab.y, 0):normalized()
  if f:dot(veh:getDirectionVector()) < 0 then f = f * -1 end
  local right = rightOf(f)

  local count = math.max(1, math.min(6, math.floor(W / CFG.laneWidth + 0.5)))
  local laneW = W / count
  local centers = {}
  for i = 0, count - 1 do centers[i] = -W / 2 + (i + 0.5) * laneW end
  local lat = (pos - cp):dot(right)
  local idx = math.max(0, math.min(count - 1, math.floor((lat + W / 2) / laneW)))

  return {
    W = W, count = count, laneW = laneW, lat = lat, idx = idx, centers = centers,
    fwd = f, right = right, a = a, b = b,
    offGrid = math.abs(lat) > W / 2 + CFG.gridTolerance,
  }
end

----------------------------------------------------------------------
-- Swerve brain
----------------------------------------------------------------------
local function lookahead(closing)
  return math.max(CFG.lookMin, math.min(CFG.lookMax, closing * CFG.lookTime))
end

-- every relevant car in road coordinates: s = ahead (m), l = lateral (m), dv = speed minus rival's
local function collectCars(rival, info, playerId)
  local rPos = rival:getPosition()
  local rv = rival:getVelocity():dot(info.fwd)
  local cars, seen = {}, {}
  local ids = candidateIds(rivalId)
  ids[#ids + 1] = playerId
  for _, id in ipairs(ids) do
    if id ~= rivalId and not seen[id] then
      seen[id] = true
      local v = be:getObjectByID(id)
      if v then
        local rel = v:getPosition() - rPos
        local s = rel:dot(info.fwd)
        if s > -50 and s < CFG.lookMax + 80 then
          cars[#cars + 1] = {
            id = id, s = s, l = info.lat + rel:dot(info.right),
            dv = v:getVelocity():dot(info.fwd) - rv,
            hw = widthOf(v) / 2, player = (id == playerId),
          }
        end
      end
    end
  end
  return cars
end

-- step 1: nearest car in his lane that he is catching and that is close enough to matter
local function findBlocker(cars, info, rw)
  local best
  for _, c in ipairs(cars) do
    if c.s > 0 and math.abs(c.l - info.lat) < rw / 2 + c.hw + CFG.margin then
      local closing = -c.dv
      if closing > CFG.minClosing and c.s < lookahead(closing) then
        if not best or c.s < best.s then best = c end
      end
    end
  end
  return best
end

-- step 2: earliest start time ts (s) at which lane centre L is clear for the whole shift.
-- Returns ts and the free runway ahead (m) after the shift, or nil if no moment works in time.
local function evalLane(cars, L, rw, tb)
  local T = CFG.laneTimeSpan
  local tmax = math.max(0, tb - 0.6 * T)
  local mine = {}
  for _, c in ipairs(cars) do
    if math.abs(c.l - L) < rw / 2 + c.hw + CFG.margin then mine[#mine + 1] = c end
  end
  local ts = 0
  while ts <= tmax + 1e-6 do
    local ok = true
    for _, c in ipairs(mine) do
      local zone = CFG.zoneBase + math.abs(c.dv) * CFG.zoneTime
      local tau = ts
      while tau <= ts + T + 1e-6 do
        local s = c.s + c.dv * tau
        if s > -zone and s < zone then ok = false break end
        tau = tau + 0.5
      end
      if not ok then break end
    end
    if ok then
      local run = math.huge
      for _, c in ipairs(mine) do
        local s = c.s + c.dv * (ts + T)
        if s > 0 and s < run then run = s end
      end
      return ts, math.min(run, CFG.runCap)
    end
    ts = ts + 0.25
  end
  return nil
end

-- returns blocker, bestChoice, timeToBlocker. blocker == nil means nothing to do.
local function planSwerve(rival, info, playerId, dry)
  local cars = collectCars(rival, info, playerId)
  local rw = widthOf(rival)
  if dry then
    for _, c in ipairs(cars) do
      log('I', 'TBR', string.format("  car %s%s ahead=%.1f lat=%.2f dv=%.1f m/s",
        tostring(c.id), c.player and "(player)" or "", c.s, c.l, c.dv))
    end
  end

  local blocker = findBlocker(cars, info, rw)
  if not blocker then
    if dry then log('I', 'TBR', "  no blocker in his lane") end
    return nil
  end
  local closing = -blocker.dv
  local tb = (blocker.s - CFG.gapAfter) / closing
  if dry then
    log('I', 'TBR', string.format("  blocker %s: ahead=%.1f closing=%.1f m/s lookahead=%.0f m, reaches it in %.1f s",
      tostring(blocker.id), blocker.s, closing, lookahead(closing), tb))
  end

  local best
  for _, dir in ipairs({ 1, -1 }) do -- +1 right, -1 left
    local k = info.idx + dir
    if k >= 0 and k <= info.count - 1 and (dir == 1 or CFG.allowLeftPass) then
      local ts, run = evalLane(cars, info.centers[k], rw, tb)
      if dry then
        log('I', 'TBR', string.format("  lane %d (%s): %s", k + 1, dir == 1 and "right" or "left",
          ts and string.format("free from t=%.2fs, runway %.0f m%s", ts, run,
            run >= CFG.minRunway and "" or " (too short)") or "not free in time"))
      end
      if ts and run >= CFG.minRunway then
        local score = run - ts * CFG.waitCost - (dir == -1 and CFG.leftPenalty or 0)
        if not best or score > best.score then
          best = { score = score, ts = ts, run = run, lane = k, L = info.centers[k] }
        end
      end
    end
  end
  return blocker, best, tb
end

local function doShift(rival, info, best, rSpeed)
  local disp = best.L - info.lat
  local dist = math.max(CFG.minLaneDist, math.min(CFG.maxLaneDist, math.max(rSpeed, 12) * CFG.laneTimeSpan))
  rival:queueLuaCommand(string.format(
    "if ai.laneChange then pcall(ai.laneChange, nil, %.1f, %.2f) end", dist, disp * CFG.laneSign))
  shiftUntil = raceTime + CFG.laneTimeSpan + CFG.laneCooldown
  shiftCheckAt = raceTime + CFG.laneTimeSpan + 0.5
  shiftTarget = best.L
end

----------------------------------------------------------------------
-- Race flow
----------------------------------------------------------------------
local function endRace(text)
  if rivalId then setRivalMode(rivalId, false) end
  msg(text, 4)
  state, rivalId, cooldownLeft = "idle", nil, CFG.cooldown
  shiftCheckAt = nil
end

local function startChallenge(player, playerId)
  local id = findRival(player, playerId)
  if not id then msg("TBR: no rival ahead", 2) return end
  rivalId, state, timer = id, "countdown", CFG.countdown
  lastMsg = math.ceil(timer) + 1
  axis = player:getDirectionVector():normalized()
  axis = vec3(axis.x, axis.y, 0):normalized()
  holdTimer, holdSign, pStuck, rStuck = 0, 0, 0, 0
  shiftUntil, shiftCheckAt, shiftTarget, lastKind, logT = 0, nil, nil, "", 0
  warnedNoRoad, warnedOff = false, false
  msg("TBR: challenge ACCEPTED!", 2)
end

function M.onTripleFlash(vehId)
  if state ~= "idle" or cooldownLeft > 0 then return end
  local player, playerId = playerVeh()
  if not player or playerId ~= vehId then return end
  startChallenge(player, playerId)
end

local function updateAxis(player, rival)
  local sum = vec3(0, 0, 0)
  local pv, rv = player:getVelocity(), rival:getVelocity()
  if pv:length() > 8 then sum = sum + pv:normalized() end
  if rv:length() > 8 then sum = sum + rv:normalized() end
  sum = vec3(sum.x, sum.y, 0)
  if sum:length() > 0.3 then
    axis = vec3(0, 0, 0) + axis * 0.9 + sum:normalized() * 0.1
    axis = vec3(axis.x, axis.y, 0):normalized()
  end
end

local function onUpdate(dtReal)
  local dt = dtReal
  if cooldownLeft > 0 then cooldownLeft = cooldownLeft - dt end
  if state == "idle" then return end

  local player, playerId = playerVeh()
  local rival = rivalId and be:getObjectByID(rivalId)
  if not player or not rival then endRace("TBR: race cancelled") return end

  if state == "countdown" then
    timer = timer - dt
    local n = math.ceil(timer)
    if n ~= lastMsg and n > 0 then lastMsg = n msg(tostring(n), 1) end
    if timer <= 0 then
      state, raceTime, tick = "racing", 0, 0
      setRivalMode(rivalId, true)
      msg("GO!", 2)
    end
    return
  end

  raceTime = raceTime + dt
  tick = tick + dt
  logT = logT + dt
  updateAxis(player, rival)

  if tick >= CFG.tick then
    local step = tick
    tick = 0
    local pSpeed = player:getVelocity():length()
    local rSpeed = rival:getVelocity():length()

    -- swerve
    if CFG.enableLanes and raceTime >= shiftUntil then
      local info = getRoadInfo(rival)
      if not info then
        if not warnedNoRoad then warnedNoRoad = true log('W', 'TBR', "no road data at rival position") end
      elseif info.offGrid then
        if not warnedOff then warnedOff = true log('W', 'TBR', "rival off the lane grid, swerve logic skipped") end
      elseif info.W >= CFG.minRoadW and info.count > 1 then
        local blocker, best, tb = planSwerve(rival, info, playerId, false)
        local kind = (not blocker) and "clear" or (not best) and "nolane" or (best.ts < 0.3) and "shift" or "wait"
        if kind ~= lastKind then
          lastKind = kind
          if kind == "nolane" then
            log('I', 'TBR', string.format("blocked by %s at %.0f m, no safe lane -> native AI handles it", tostring(blocker.id), blocker.s))
          elseif kind == "wait" then
            log('I', 'TBR', string.format("blocker at %.0f m, lane %d not free yet, waiting %.1f s", blocker.s, best.lane + 1, best.ts))
          end
        end
        if kind == "shift" then
          log('I', 'TBR', string.format("SHIFT lane %d -> %d (blocker %s at %.0f m, runway %.0f m, %.0f km/h)",
            info.idx + 1, best.lane + 1, tostring(blocker.id), blocker.s, best.run, rSpeed * 3.6))
          doShift(rival, info, best, rSpeed)
        end
      end
    end

    -- result check of the last shift
    if shiftCheckAt and raceTime >= shiftCheckAt then
      shiftCheckAt = nil
      local info = getRoadInfo(rival)
      if info then
        log('I', 'TBR', string.format("shift result: wanted lat %.2f, got %.2f", shiftTarget or 0, info.lat))
      end
    end

    -- periodic state line
    if CFG.logEvery > 0 and logT >= CFG.logEvery then
      logT = 0
      local info = getRoadInfo(rival)
      log('I', 'TBR', string.format("race: rival %.0f km/h, player %.0f km/h, road=%s lane=%s lat=%s gap=%.0f m",
        rSpeed * 3.6, pSpeed * 3.6,
        info and (tostring(info.a) .. "-" .. tostring(info.b)) or "?",
        info and (info.idx + 1) .. "/" .. info.count or "?",
        info and string.format("%.1f", info.lat) or "?",
        (rival:getPosition() - player:getPosition()):dot(axis)))
    end

    -- stuck rules
    pStuck = (pSpeed < 2) and (pStuck + step) or 0
    rStuck = (rSpeed < 2) and (rStuck + step) or 0
    if pStuck > CFG.playerStuck then endRace("TBR: YOU LOSE (stopped)") return end
    if rStuck > CFG.rivalStuck then endRace("TBR: YOU WIN (rival stopped)") return end
  end

  -- gap rule (unchanged): gap along smoothed axis, must hold for winHold seconds
  local toRival = rival:getPosition() - player:getPosition()
  local lead = toRival:dot(axis)
  local sign = (lead > CFG.winGap and 1) or (lead < -CFG.winGap and -1) or 0
  if sign ~= 0 and sign == holdSign then
    holdTimer = holdTimer + dt
  else
    holdSign, holdTimer = sign, 0
  end
  if holdSign ~= 0 and holdTimer >= CFG.winHold then
    endRace(holdSign > 0 and "TBR: YOU LOSE" or "TBR: YOU WIN!")
  elseif toRival:length() > CFG.maxDist_abort then endRace("TBR: rival lost")
  elseif raceTime > CFG.timeout then endRace("TBR: time out - draw")
  end
end

----------------------------------------------------------------------
-- Debug commands (type in the console, prefix extensions.tbrRace.)
----------------------------------------------------------------------
function M.debugChallenge()
  local p, id = playerVeh()
  if p then startChallenge(p, id) end
end

function M.debugStop() if state ~= "idle" then endRace("TBR: cancelled") end end

function M.set(key, value)
  if CFG[key] == nil then log('W', 'TBR', "set: unknown setting " .. tostring(key)) return end
  CFG[key] = value
  log('I', 'TBR', "set " .. tostring(key) .. " = " .. tostring(value))
end

function M.show()
  local keys = {}
  for k in pairs(CFG) do keys[#keys + 1] = k end
  table.sort(keys)
  for _, k in ipairs(keys) do log('I', 'TBR', k .. " = " .. tostring(CFG[k])) end
end

-- tests the rival search: every nearby car with the numbers behind the decision
function M.debugFind()
  local p, pid = playerVeh()
  if not p then return end
  local pPos, pDir = p:getPosition(), p:getDirectionVector():normalized()
  for _, id in ipairs(candidateIds(pid)) do
    local v = be:getObjectByID(id)
    if v then
      local toV = v:getPosition() - pPos
      local dist = toV:length()
      local ahead = dist > 0 and toV:normalized():dot(pDir) or 0
      local sameDir = v:getDirectionVector():normalized():dot(pDir)
      local speed = v:getVelocity():length()
      local ok = dist > CFG.minDist and dist < CFG.maxDist and ahead > CFG.minDot
        and sameDir > CFG.sameDirDot and speed > CFG.minRivalSpeed
      log('I', 'TBR', string.format("car %s: dist=%.0f straightAhead=%.2f sameDir=%.2f speed=%.0f km/h -> %s",
        tostring(id), dist, ahead, sameDir, speed * 3.6, ok and "CANDIDATE" or "no"))
    end
  end
  log('I', 'TBR', "findRival would pick: " .. tostring(findRival(p, pid)))
end

-- tests road/lane reading for you and the rival
function M.debugLane()
  local function dump(name, v)
    local i = getRoadInfo(v)
    if not i then log('W', 'TBR', name .. ": no road info") return end
    log('I', 'TBR', string.format("%s: road %s-%s W=%.2f lanes=%d lane=%d lat=%.2f offGrid=%s",
      name, tostring(i.a), tostring(i.b), i.W, i.count, i.idx + 1, i.lat, tostring(i.offGrid)))
    return i
  end
  local p = playerVeh()
  if p then
    local i = dump("player", p)
    if i then msg(string.format("lane %d of %d%s", i.idx + 1, i.count, i.offGrid and " OFF GRID" or ""), 3) end
  end
  local r = rivalId and be:getObjectByID(rivalId)
  if r then dump("rival", r) end
end

-- tests the swerve brain: prints cars, blocker and lane evaluation WITHOUT moving him
function M.debugScan()
  local _, pid = playerVeh()
  local r = rivalId and be:getObjectByID(rivalId)
  if not r then log('W', 'TBR', "debugScan: no rival (start a challenge first)") return end
  local info = getRoadInfo(r)
  if not info then log('W', 'TBR', "debugScan: no road info") return end
  log('I', 'TBR', string.format("debugScan: rival lane %d/%d lat=%.2f offGrid=%s",
    info.idx + 1, info.count, info.lat, tostring(info.offGrid)))
  local blocker, best = planSwerve(r, info, pid, true)
  if blocker and best then
    log('I', 'TBR', string.format("  DECISION: lane %d, start in %.2f s, runway %.0f m", best.lane + 1, best.ts, best.run))
  elseif blocker then
    log('I', 'TBR', "  DECISION: no safe lane, stay (native AI brakes)")
  end
end

-- tests the lane change call itself (and its direction). + = right, - = left. Use after GO.
function M.testShift(offset)
  local r = rivalId and be:getObjectByID(rivalId)
  if not r then log('W', 'TBR', "testShift: no rival") return end
  local sp = math.max(r:getVelocity():length(), 12)
  local dist = math.max(CFG.minLaneDist, math.min(CFG.maxLaneDist, sp * CFG.laneTimeSpan))
  log('I', 'TBR', string.format("testShift: %.1f m over %.0f m", offset, dist))
  r:queueLuaCommand(string.format(
    "if ai.laneChange then pcall(ai.laneChange, nil, %.1f, %.2f) end", dist, offset * CFG.laneSign))
end

-- the rival's full state
function M.debugState()
  log('I', 'TBR', string.format("state=%s raceTime=%.1f cooldown=%.1f rival=%s",
    state, raceTime, math.max(cooldownLeft, 0), tostring(rivalId)))
  local p = playerVeh()
  local r = rivalId and be:getObjectByID(rivalId)
  if p then log('I', 'TBR', string.format("player: %.0f km/h", p:getVelocity():length() * 3.6)) end
  if r then
    local i = getRoadInfo(r)
    log('I', 'TBR', string.format("rival: %.0f km/h road=%s lane=%s lat=%s offGrid=%s",
      r:getVelocity():length() * 3.6,
      i and (tostring(i.a) .. "-" .. tostring(i.b)) or "?",
      i and (i.idx + 1) .. "/" .. i.count or "?",
      i and string.format("%.2f", i.lat) or "?", i and tostring(i.offGrid) or "?"))
    log('I', 'TBR', string.format("shift: %s, last decision: %s, stuck p=%.1fs r=%.1fs",
      raceTime < shiftUntil and string.format("active %.1fs", shiftUntil - raceTime) or "none",
      lastKind ~= "" and lastKind or "-", pStuck, rStuck))
    if p and axis then
      log('I', 'TBR', string.format("gap along axis: %.0f m (win/lose at +-%d for %.1fs, hold %.1fs)",
        (r:getPosition() - p:getPosition()):dot(axis), CFG.winGap, CFG.winHold, holdTimer))
    end
  end
end

M.onUpdate = onUpdate
M.onVehicleSwitched = function(_, newId) attach(newId) end
M.onVehicleSpawned = function(id) local _, pid = playerVeh() if id == pid then attach(id) end end
M.onExtensionLoaded = function() local _, id = playerVeh() attach(id) end
return M