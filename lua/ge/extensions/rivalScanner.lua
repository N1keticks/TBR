-- TBR TrafficScanner
-- Поиск ближайшей машины впереди игрока в заданном конусе.
-- Использование:
--   local TrafficScanner = require('tokyobeamracing/trafficScanner')
--   local rival = TrafficScanner.findRivalAhead(playerVeh, 30.0, 30.0)
--   if rival then ... end

local M = {}

local DEFAULT_MAX_DISTANCE = 30.0   -- метров
local DEFAULT_MAX_ANGLE_DEG = 30.0  -- градусов от направления "вперёд"

-- Безопасное получение списка машин.
-- Пробуем несколько известных API, чтобы не падать на разных версиях игры.
local function getVehicleList()
    -- 1) Современный API (0.3x)
    if core_vehicles and core_vehicles.getCurrentVehicles then
        local ok, list = pcall(core_vehicles.getCurrentVehicles)
        if ok and type(list) == "table" then
            return list
        end
    end

    -- 2) Старый/альтернативный API
    if be and be.getObjectList then
        local ok, list = pcall(be.getObjectList)
        if ok and type(list) == "table" then
            local vehicles = {}
            for _, obj in ipairs(list) do
                -- У машин есть метод getPosition и getID; отфильтруем по наличию getPosition
                if obj and type(obj.getPosition) == "function" and type(obj.getID) == "function" then
                    table.insert(vehicles, obj)
                end
            end
            return vehicles
        end
    end

    return {}
end

-- Безопасное получение ID машины (на случай, если метод недоступен)
local function safeGetId(veh)
    if not veh then return nil end
    if type(veh.getID) == "function" then
        local ok, id = pcall(veh.getID, veh)
        if ok then return id end
    end
    return nil
end

-- Безопасное получение позиции
local function safeGetPosition(veh)
    if not veh or type(veh.getPosition) ~= "function" then return nil end
    local ok, pos = pcall(veh.getPosition, veh)
    if ok then return pos end
    return nil
end

-- Безопасное получение вектора "вперёд"
local function safeGetDirection(veh)
    if not veh then return nil end
    if type(veh.getDirectionVector) == "function" then
        local ok, dir = pcall(veh.getDirectionVector, veh)
        if ok then return dir end
    end
    return nil
end

-- Основная функция поиска.
-- playerVeh   : объект машины игрока (обязательно)
-- maxDistance : максимальная дистанция в метрах (по умолчанию 30)
-- maxAngleDeg : максимальный угол от направления "вперёд" в градусах (по умолчанию 30)
-- Возвращает: объект машины-соперника или nil
function M.findRivalAhead(playerVeh, maxDistance, maxAngleDeg)
    if not playerVeh then
        log("W", "TBR", "TrafficScanner: playerVeh is nil")
        return nil
    end

    maxDistance = maxDistance or DEFAULT_MAX_DISTANCE
    maxAngleDeg = maxAngleDeg or DEFAULT_MAX_ANGLE_DEG

    local playerPos = safeGetPosition(playerVeh)
    local playerDir = safeGetDirection(playerVeh)
    if not playerPos or not playerDir then
        log("W", "TBR", "TrafficScanner: cannot get player position/direction")
        return nil
    end

    local playerId = safeGetId(playerVeh)
    local vehicles = getVehicleList()

    local bestVeh = nil
    local bestDist = maxDistance

    for _, veh in ipairs(vehicles) do
        if veh and veh ~= playerVeh then
            local vehId = safeGetId(veh)
            if vehId and vehId ~= playerId then
                local vehPos = safeGetPosition(veh)
                if vehPos then
                    local delta = vehPos - playerPos
                    local dist = delta:length()

                    -- Дистанция должна быть ненулевой и меньше текущей лучшей
                    if dist > 0.1 and dist < bestDist then
                        -- Проверка направления: косинус угла между delta и playerDir
                        local dot = delta:dot(playerDir) / dist
                        -- Ограничиваем из-за погрешностей float
                        dot = math.max(-1.0, math.min(1.0, dot))
                        local angleDeg = math.deg(math.acos(dot))

                        if angleDeg <= maxAngleDeg then
                            bestDist = dist
                            bestVeh = veh
                        end
                    end
                end
            end
        end
    end

    return bestVeh
end

-- Удобная обёртка: найти и залогировать.
-- Возвращает: rival (или nil), dist (или nil)
function M.findAndLog(playerVeh, maxDistance, maxAngleDeg)
    local rival = M.findRivalAhead(playerVeh, maxDistance, maxAngleDeg)
    if rival then
        local playerPos = safeGetPosition(playerVeh)
        local rivalPos = safeGetPosition(rival)
        local dist = (playerPos and rivalPos) and (rivalPos - playerPos):length() or -1
        local rivalName = "unknown"
        if type(rival.getJBeamFilename) == "function" then
            local ok, name = pcall(rival.getJBeamFilename, rival)
            if ok and name then rivalName = name end
        end
        log("I", "TBR", string.format(
            "Rival found | id=%s | name=%s | dist=%.1f m",
            tostring(safeGetId(rival)), rivalName, dist
        ))
        return rival, dist
    else
        log("I", "TBR", "Rival not found ahead")
        return nil, nil
    end
end

return M