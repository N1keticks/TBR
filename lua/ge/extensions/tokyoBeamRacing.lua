-- TokyoBeamRacing Prototype 0.2.0
-- Detects the player's high-beam activation and reports it to Game Engine Lua.
-- This prototype does not yet select a traffic rival or start a race.

local M = {}

M.VERSION = "0.2.0"

M.config = {
  minDriverLevel = 0,
  minRoadMileageKm = 0,
  maxChallengeDistance = 80,
}

M.state = {
  loaded = false,
  activeChallenge = false,
  lastDecision = nil,
  playerLevel = 0,
  roadMileageKm = 0,
  playerVehicleId = nil,
  watcherAttachAttempts = 0,
  headlightEvents = 0,
  lastHeadlightSource = nil,
}

local WATCHER_EXT = "tbrHeadlightWatcher"

local function logInfo(message)
  log("I", "TokyoBeamRacing", tostring(message))
end

local function logWarn(message)
  log("W", "TokyoBeamRacing", tostring(message))
end

local function showMessage(message)
  if guihooks and guihooks.trigger then
    guihooks.trigger("Message", {
      msg = message,
      ttl = 3.0,
      category = "tokyoBeamRacing",
      icon = "lightbulb",
    })
  end
end

local function attachWatcher(vehicle)
  if not vehicle then return end
  local id = vehicle:getID()
  if not id then return end

  vehicle:queueLuaCommand("extensions.load('" .. WATCHER_EXT .. "')")
  M.state.playerVehicleId = id
  M.state.watcherAttachAttempts = M.state.watcherAttachAttempts + 1
  logInfo("Headlight watcher requested for player vehicle " .. tostring(id))
end

-- Attach the watcher to the current player vehicle. This also handles vehicle swaps.
function M.onUpdate(dt)
  local player = be and be.getPlayerVehicle and be:getPlayerVehicle(0) or nil
  if not player then
    M.state.playerVehicleId = nil
    return
  end

  local id = player:getID()
  if id and id ~= M.state.playerVehicleId then
    attachWatcher(player)
  end
end

-- Called by tbrHeadlightWatcher inside the player's Vehicle Lua VM.
function M.onHeadlightFlash(vehicleId, source)
  vehicleId = tonumber(vehicleId)

  -- Ignore events from any vehicle other than the current player vehicle.
  local player = be and be.getPlayerVehicle and be:getPlayerVehicle(0) or nil
  local playerId = player and player:getID() or nil
  if not playerId or vehicleId ~= playerId then
    return
  end

  M.state.headlightEvents = M.state.headlightEvents + 1
  M.state.lastHeadlightSource = tostring(source or "unknown")

  logInfo(string.format(
    "HEADLIGHT FLASH DETECTED | vehicle=%d | source=%s | count=%d",
    vehicleId,
    M.state.lastHeadlightSource,
    M.state.headlightEvents
  ))
  showMessage("TBR: HEADLIGHT FLASH DETECTED")
end

function M.evaluateChallenge(context)
  context = context or {}

  local level = tonumber(context.playerLevel)
  if level == nil then level = M.state.playerLevel end

  local mileage = tonumber(context.roadMileageKm)
  if mileage == nil then mileage = M.state.roadMileageKm end

  if context.anotherChallengeActive == true or M.state.activeChallenge then
    return false, "RIVAL: BUSY", "another_challenge_active"
  end
  if context.rivalAvailable == false then
    return false, "RIVAL: NOT NOW", "rival_unavailable"
  end
  if level < M.config.minDriverLevel then
    return false, "RIVAL: NOT INTERESTED", "driver_level_too_low"
  end
  if mileage < M.config.minRoadMileageKm then
    return false, "RIVAL: PROVE YOURSELF", "road_mileage_too_low"
  end

  local distance = tonumber(context.distanceMeters)
  if distance and distance > M.config.maxChallengeDistance then
    return false, "RIVAL: OUT OF RANGE", "rival_out_of_range"
  end

  return true, "CHALLENGE ACCEPTED", "eligible"
end

function M.requestChallenge(context)
  local accepted, message, reason = M.evaluateChallenge(context)
  M.state.lastDecision = {
    accepted = accepted,
    message = message,
    reason = reason,
  }

  if accepted then
    logInfo("Challenge eligible: " .. message)
  else
    logInfo("Challenge refused: " .. message .. " (" .. reason .. ")")
  end
  return accepted, message, reason
end

function M.setPlayerProgress(driverLevel, roadMileageKm)
  M.state.playerLevel = math.max(0, tonumber(driverLevel) or 0)
  M.state.roadMileageKm = math.max(0, tonumber(roadMileageKm) or 0)
  logInfo(string.format(
    "Progress updated: level=%d, mileage=%.1f km",
    M.state.playerLevel,
    M.state.roadMileageKm
  ))
end

function M.getStatus()
  return {
    version = M.VERSION,
    loaded = M.state.loaded,
    activeChallenge = M.state.activeChallenge,
    playerLevel = M.state.playerLevel,
    roadMileageKm = M.state.roadMileageKm,
    playerVehicleId = M.state.playerVehicleId,
    headlightEvents = M.state.headlightEvents,
    lastHeadlightSource = M.state.lastHeadlightSource,
    lastDecision = M.state.lastDecision,
  }
end

function M.onExtensionLoaded()
  M.state.loaded = true
  logInfo("TokyoBeamRacing " .. M.VERSION .. " loaded.")
  logInfo("Headlight watcher prototype active; waiting for player vehicle.")
end

function M.onExtensionUnloaded()
  M.state.loaded = false
  M.state.playerVehicleId = nil
  logInfo("Extension unloaded.")
end

return M
