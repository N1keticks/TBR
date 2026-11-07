-- GE Lua: attaches flash watcher, finds a rival, runs a simple duel.
local M = {}

local CFG = {
  maxDist       = 30,
  minDist       = 4,
  minDot        = 0.85,
  sameDirDot    = 0.7,
  minRivalSpeed = 5,
  countdown     = 3,
  winGap        = 120,   -- m gap needed...
  winHold       = 2.0,   -- ...held for this many seconds
  maxDist_abort = 500,
  timeout       = 90,
  playerStuck   = 3,     -- s standing still = lose
  rivalStuck    = 3,     -- s standing still = win
  aggression    = 1.0,
  cooldown      = 5,
  paceMul       = 1.15,
  paceAdd       = 5,
  minPace       = 20,
  maxPace       = 90,
  laBase        = 15,
  laTime        = 1.6,
  laLateral     = 2,
  laGap         = 8,
  -- lane changing
  laneSign      = 1,     -- flip to -1 if he swerves INTO you instead of away
  laneOffset    = 3.5,   -- m sideways
  laneDist      = 40,    -- m distance over which to change
  laneCooldown  = 2,   -- s between lane changes
  behindRange   = 15,    -- m: player this close behind in same lane triggers a swerve
  sameLane      = 2.2,   -- m lateral = "same lane"
}

local state = "idle"
local rivalId, timer, raceTime, lastMsg, cooldownLeft, tick = nil, 0, 0, 0, 0, 0
local axis, holdTimer, holdSign, pStuck, rStuck, laneCd = nil, 0, 0, 0, 0, 0

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

local function setRivalMode(id, racing)
  local v = be:getObjectByID(id)
  if not v then return end
  if racing then
    v:queueLuaCommand([[
      ai.setMode('random')
      ai.setAggression(]] .. CFG.aggression .. [[)
      ai.driveInLane('on')
      pcall(function() ai.setAvoidCars('on') end)
      ai.setSpeedMode('limit')
      ai.setSpeed(]] .. CFG.minPace .. [[)
    ]])
  else
    v:queueLuaCommand([[
      ai.setMode('traffic')
      ai.setAggression(0.3)
      ai.setSpeedMode('legal')
      ai.driveInLane('on')
    ]])
  end
end

local function setRivalSpeed(id, speed)
  local v = be:getObjectByID(id)
  if v then v:queueLuaCommand("ai.setSpeed(" .. string.format("%.2f", speed) .. ")") end
end

local function rightOf(dir) return dir:cross(vec3(0, 0, 1)) end

-- returns speed limit and the lateral offset (m, + = right of rival) of the blocking car, if any
local function trafficLimit(rival, playerId, wanted)
  local rPos = rival:getPosition()
  local rDir = rival:getDirectionVector():normalized()
  local rRight = rightOf(rDir)
  local rSpeed = rival:getVelocity():length()
  local lookahead = CFG.laBase + rSpeed * CFG.laTime
  local limit, blockerLat = wanted, nil
  local ids = candidateIds(rivalId)
  ids[#ids + 1] = playerId
  for _, id in ipairs(ids) do
    local v = be:getObjectByID(id)
    if v then
      local rel = v:getPosition() - rPos
      local fwd = rel:dot(rDir)
      if fwd > 0 and fwd < lookahead then
        local lat = rel:dot(rRight)
        if math.abs(lat) < CFG.laLateral then
          local theirSpeed = math.max(0, v:getVelocity():dot(rDir))
          local allowed = math.max(theirSpeed + (fwd - CFG.laGap) * 0.6, 0)
          if allowed < limit then limit, blockerLat = allowed, lat end
        end
      end
    end
  end
  return limit, blockerLat
end

local function laneChange(rivalVeh, awayFromLat)
  -- awayFromLat > 0: threat on the right -> go left
  local dir = (awayFromLat > 0) and -1 or 1
  local disp = dir * CFG.laneOffset * CFG.laneSign
  rivalVeh:queueLuaCommand(string.format([[
    if ai.laneChange then
      pcall(ai.laneChange, nil, %.1f, %.1f)
    else
      obj:queueGameEngineLua("log('W','TBR','ai.laneChange missing')")
    end
  ]], CFG.laneDist, disp))
  laneCd = CFG.laneCooldown
end

local function endRace(text)
  if rivalId then setRivalMode(rivalId, false) end
  msg(text, 4)
  state, rivalId, cooldownLeft = "idle", nil, CFG.cooldown
end

local function startChallenge(player, playerId)
  local id = findRival(player, playerId)
  if not id then msg("TBR: no rival ahead", 2) return end
  rivalId, state, timer = id, "countdown", CFG.countdown
  lastMsg = math.ceil(timer) + 1
  axis = player:getDirectionVector():normalized()
  axis = vec3(axis.x, axis.y, 0):normalized()
  holdTimer, holdSign, pStuck, rStuck, laneCd = 0, 0, 0, 0, 0
  msg("TBR: challenge ACCEPTED!", 2)
end

function M.onTripleFlash(vehId)
  if state ~= "idle" or cooldownLeft > 0 then return end
  local player, playerId = playerVeh()
  if not player or playerId ~= vehId then return end
  startChallenge(player, playerId)
end

function M.debugChallenge()
  local p, id = playerVeh()
  if p then startChallenge(p, id) end
end

function M.debugStop() if state ~= "idle" then endRace("TBR: cancelled") end end

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

local function onUpdate(dtReal, dtSim)
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

  -- racing
  raceTime = raceTime + dt
  tick = tick + dt
  laneCd = laneCd - dt

  updateAxis(player, rival)

  if tick > 0.25 then
    local step = tick
    tick = 0
    local pSpeed = player:getVelocity():length()
    local rSpeed = rival:getVelocity():length()

    -- speed limit + traffic
    local pace = math.min(CFG.maxPace, math.max(CFG.minPace, pSpeed * CFG.paceMul + CFG.paceAdd))
    local limit, blockerLat = trafficLimit(rival, playerId, pace)
    setRivalSpeed(rivalId, limit)

    -- lane logic
    if laneCd <= 0 then
      local rDir = rival:getDirectionVector():normalized()
      local rel = player:getPosition() - rival:getPosition()
      local fwd, lat = rel:dot(rDir), rel:dot(rightOf(rDir))
      if fwd < 0 and fwd > -CFG.behindRange and math.abs(lat) < CFG.sameLane then
        laneChange(rival, lat)            -- player behind in my lane: dodge sideways
      elseif blockerLat and limit < pace * 0.7 then
        laneChange(rival, blockerLat)     -- slow car ahead: try around it
      end
    end

    -- stuck rules
    pStuck = (pSpeed < 2) and (pStuck + step) or 0
    rStuck = (rSpeed < 2) and (rStuck + step) or 0
    if pStuck > CFG.playerStuck then endRace("TBR: YOU LOSE (stopped)") return end
    if rStuck > CFG.rivalStuck then endRace("TBR: YOU WIN (rival stopped)") return end
  end

  -- gap along smoothed race axis, must hold for winHold seconds
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

M.onUpdate = onUpdate
M.onVehicleSwitched = function(_, newId) attach(newId) end
M.onVehicleSpawned = function(id) local _, pid = playerVeh() if id == pid then attach(id) end end
M.onExtensionLoaded = function() local _, id = playerVeh() attach(id) end
return M