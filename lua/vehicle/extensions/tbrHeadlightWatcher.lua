-- TokyoBeamRacing - Vehicle Lua headlight watcher
-- Runs inside the player's vehicle Lua VM.
-- Detects the rising edge of the standard highbeam electrics signal.

local M = {}

local initialized = false
local wasHighBeamDown = false
local debounceRemaining = 0
local DEBOUNCE_SECONDS = 0.30

local function getHighBeamState()
  if not electrics or not electrics.values then
    return false, "unavailable"
  end

  local values = electrics.values

  -- Standard BeamNG vehicle electrics channel.
  if values.highbeam ~= nil then
    return tonumber(values.highbeam) ~= nil and tonumber(values.highbeam) > 0.5, "highbeam"
  end

  -- Fallback for vehicles exposing only the light-mode state.
  local lightsState = tonumber(values.lights_state or values.lights)
  if lightsState ~= nil then
    return lightsState >= 2, "lights_state"
  end

  return false, "unavailable"
end

local function updateGFX(dt)
  dt = tonumber(dt) or 0
  if debounceRemaining > 0 then
    debounceRemaining = math.max(0, debounceRemaining - dt)
  end

  local isHighBeamOn, source = getHighBeamState()

  -- Establish the initial state without generating a false event at spawn.
  if not initialized then
    initialized = true
    wasHighBeamDown = isHighBeamOn
    return
  end

  -- Rising edge: off -> on. Holding high beams does not repeatedly trigger.
  if isHighBeamOn and not wasHighBeamDown and debounceRemaining <= 0 then
    debounceRemaining = DEBOUNCE_SECONDS
    if obj and obj.queueGameEngineLua then
      obj:queueGameEngineLua(
        "tokyobeamracing.onHeadlightFlash(" ..
        tostring(obj:getID()) .. ", '" .. tostring(source) .. "')"
      )
    end
  end

  wasHighBeamDown = isHighBeamOn
end

M.updateGFX = updateGFX
return M
