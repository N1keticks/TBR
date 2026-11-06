-- Vehicle Lua: counts high-beam OFF->ON edges, reports a triple flash to GE.
local M = {}

local FLASHES_NEEDED = 3
local WINDOW = 2.5      -- seconds in which all flashes must happen
local MIN_EDGE_GAP = 0.05

local prev = false
local times = {}
local clock = 0
local lastEdge = -10

local function isHigh()
  local e = electrics.values
  if (e.highbeam or 0) > 0.5 then return true end
  if (e.lights_state or 0) == 2 then return true end
  return false
end

local function updateGFX(dt)
  clock = clock + dt
  local cur = isHigh()
  if cur and not prev and (clock - lastEdge) > MIN_EDGE_GAP then
    lastEdge = clock
    times[#times + 1] = clock
    -- drop flashes outside the window
    while #times > 0 and (clock - times[1]) > WINDOW do
      table.remove(times, 1)
    end
    if #times >= FLASHES_NEEDED then
      times = {}
      obj:queueGameEngineLua(
        "if extensions.tbrRace then extensions.tbrRace.onTripleFlash(" .. obj:getID() .. ") end")
    end
  end
  prev = cur
end

M.updateGFX = updateGFX
return M