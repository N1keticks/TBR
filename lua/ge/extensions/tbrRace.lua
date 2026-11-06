-- GE Lua: attaches flash watcher, finds a rival, runs a simple duel.
local M = {}

local CFG = {
  maxDist       = 30,    -- m, how far ahead the rival can be
  minDist       = 4,     -- m
  minDot        = 0.85,  -- how "straight ahead" (cos of angle) the rival must be
  sameDirDot    = 0.7,   -- rival must drive roughly the same direction as you
  minRivalSpeed = 5,     -- m/s, must be actually cruising
  countdown     = 3,     -- seconds
  winGap        = 150,   -- m: lead needed to win the duel
  maxDist_abort = 500,   -- m: duel aborted if cars get this far apart
  timeout       = 180,   -- s
  aggression    = 0.95,
  cooldown      = 5,
}

local state = "idle"  -- idle | countdown | racing
local rivalId, timer, raceTime, lastMsg, cooldownLeft, aiTick = nil, 0, 0, 0, 0, 0

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

local function candidateIds(playerId)
  local ids = {}
  if gameplay_traffic and gameplay_traffic.getTrafficList then
    local ok, list = pcall(gameplay_traffic.getTrafficList)
    if ok and list then for _, id in ipairs(list) do ids[#ids + 1] = id end end
  end
  if #ids == 0 then -- fallback: every other vehicle
    for i = 0, be:getObjectCount() - 1 do
      local v = be:getObject(i)
      if v then ids[#ids + 1] = v:getID() end
    end
  end
  local out = {}
  for _, id in ipairs(ids) do if id ~= playerId then out[#out + 1] = id end end
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

local function setRivalAI(id, aggressive)
  local v = be:getObjectByID(id)
  if not v then return end
  if aggressive then
    v:queueLuaCommand([[
      ai.setMode('random')
      ai.setAggression(]] .. CFG.aggression .. [[)
      ai.setSpeedMode('off')
      ai.driveInLane('off')
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

local function endRace(text)
  if rivalId then setRivalAI(rivalId, false) end
  msg(text, 4)
  state, rivalId, cooldownLeft = "idle", nil, CFG.cooldown
end

local function startChallenge(player, playerId)
  local id = findRival(player, playerId)
  if not id then msg("TBR: no rival ahead", 2) return end
  rivalId, state, timer = id, "countdown", CFG.countdown
  lastMsg = math.ceil(timer) + 1
  msg("TBR: challenge ACCEPTED!", 2)
end

-- called from vehicle Lua on 3 flashes
function M.onTripleFlash(vehId)
  if state ~= "idle" or cooldownLeft > 0 then return end
  local player, playerId = playerVeh()
  if not player or playerId ~= vehId then return end
  startChallenge(player, playerId)
end

-- test without flashing: extensions.tbrRace.debugChallenge() in the console
function M.debugChallenge()
  local p, id = playerVeh()
  if p then startChallenge(p, id) end
end

function M.debugStop() if state ~= "idle" then endRace("TBR: cancelled") end end

local function onUpdate(dtReal, dtSim)
  local dt = dtReal
  if cooldownLeft > 0 then cooldownLeft = cooldownLeft - dt end
  if state == "idle" then return end

  local player = playerVeh()
  local rival = rivalId and be:getObjectByID(rivalId)
  if not player or not rival then endRace("TBR: race cancelled") return end

  if state == "countdown" then
    timer = timer - dt
    local n = math.ceil(timer)
    if n ~= lastMsg and n > 0 then lastMsg = n msg(tostring(n), 1) end
    if timer <= 0 then
      state, raceTime, aiTick = "racing", 0, 0
      setRivalAI(rivalId, true)
      msg("GO!", 2)
    end
    return
  end

  -- racing
  raceTime = raceTime + dt
  aiTick = aiTick + dt
  if aiTick > 1 then aiTick = 0 setRivalAI(rivalId, true) end -- keep traffic manager from taking over

  local pDir = player:getDirectionVector():normalized()
  local toRival = rival:getPosition() - player:getPosition()
  local lead = toRival:dot(pDir)   -- >0: rival ahead of you

  if lead < -CFG.winGap then endRace("TBR: YOU WIN!")
  elseif lead > CFG.winGap then endRace("TBR: YOU LOSE")
  elseif toRival:length() > CFG.maxDist_abort then endRace("TBR: rival lost")
  elseif raceTime > CFG.timeout then endRace("TBR: time out - draw")
  end
end

local function onVehicleSwitched(_, newId) attach(newId) end
local function onVehicleSpawned(id) local _, pid = playerVeh() if id == pid then attach(id) end end
local function onExtensionLoaded() local _, id = playerVeh() attach(id) end

M.onUpdate = onUpdate
M.onVehicleSwitched = onVehicleSwitched
M.onVehicleSpawned = onVehicleSpawned
M.onExtensionLoaded = onExtensionLoaded
return M