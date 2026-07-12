local widget = widget ---@type Widget

function widget:GetInfo()
    return {
        name = "BuildWatch",
        desc = "Displays organized icons for all units under construction, showing build progress and estimated completion times. Factory-built units appear on the left, field constructions on the right.",
        author = "2Bit",
        date = "2025",
        license = "GNU GPL, v2 or later",
        layer = 2,
        enabled = true,
    }
end

local spGetTeamUnits = Spring.GetTeamUnits
local spGetUnitDefID = Spring.GetUnitDefID
local spGetUnitIsBuilding = Spring.GetUnitIsBuilding
local spGetUnitIsBeingBuilt = Spring.GetUnitIsBeingBuilt
local spGetGameSeconds = Spring.GetGameSeconds
local spGetGameFrame = Spring.GetGameFrame
local spSetCameraTarget = Spring.SetCameraTarget
local spGetUnitPosition = Spring.GetUnitPosition
local glColor = gl.Color
local glTexture = gl.Texture
local glTexRect = gl.TexRect
local glBlending = gl.Blending
local glRect = gl.Rect
local GL_SRC_ALPHA = GL.SRC_ALPHA
local GL_ONE = GL.ONE
local GL_ONE_MINUS_SRC_ALPHA = GL.ONE_MINUS_SRC_ALPHA
local floor = math.floor
local ceil = math.ceil
local max = math.max
local min = math.min

local myTeamID
local factoryUnits = {}
local otherUnits = {}
local iconSize = 48
local font
local etaState = {}
local updateInterval = 0.2  -- Update ETA calculations
local lastUpdateTime = 0
local iconAreas = {}  -- To track clickable areas for each icon

-- Cache UI drawing functions
local RectRound = WG.FlowUI and WG.FlowUI.Draw and WG.FlowUI.Draw.RectRound
local RectRoundProgress = WG.FlowUI and WG.FlowUI.Draw and WG.FlowUI.Draw.RectRoundProgress
local UiUnit = WG.FlowUI and WG.FlowUI.Draw and WG.FlowUI.Draw.Unit
local UiElement = WG.FlowUI and WG.FlowUI.Draw and WG.FlowUI.Draw.Element

-- Adjust for more square-like corners
local elementCorner = 6

-- Keep track of active unit IDs to clean up old entries
local activeUnitIDs = {}

-- Reusable tables to avoid allocations
local factoryBuiltIDs = {}

-- Optimized ETA state update function
local function updateETAState(unitID, buildProgress)
    local gs = spGetGameSeconds()
    local state = etaState[unitID]
    if not state then
        state = {
            firstSet = true,
            lastTime = gs,
            lastProg = buildProgress,
            rate = nil,
            timeLeft = nil,
            prevTimeLeft = nil,
            decaying = false,
            decayTime = nil,
        }
    end

    -- Track active units
    activeUnitIDs[unitID] = true

    local dp = buildProgress - (state.lastProg or buildProgress)
    local dt = gs - (state.lastTime or gs)

    -- If the building is finished, clear decaying state
    if buildProgress >= 1 then
        state.decaying = false
        state.decayTime = nil
    end

    if dt > 2 then
        state.firstSet = true
        state.rate = nil
        state.timeLeft = nil
    end

    local rate = dt > 0 and (dp / dt) or 0
    if rate > 0 then
        state.decaying = false
        state.decayTime = nil
        if state.firstSet then
            if (buildProgress > 0.001) then
                state.firstSet = false
            end
        else
            local rf = 0.5
            if state.rate == nil then
                state.rate = rate
            else
                state.rate = ((1 - rf) * state.rate) + (rf * rate)
            end

            local tf = 0.1
            local newTime = (1 - buildProgress) / state.rate
            if state.timeLeft and state.timeLeft > 0 then       
                state.timeLeft = ((1 - tf) * state.timeLeft) + (tf * newTime)
            else
                state.timeLeft = newTime
            end
        end
    elseif rate < 0 or (state.decaying and buildProgress > 0 and buildProgress < 1) then
        -- decaying (latch until progress is 0 or building is being built again)
        state.decaying = true
        local decayRate = 1 / 60
        state.decayTime = buildProgress / decayRate
        state.timeLeft = nil -- hide ETA when decaying
    end

    state.lastTime = gs
    state.lastProg = buildProgress
    state.prevTimeLeft = state.timeLeft

    etaState[unitID] = state
    return state
end

-- Optimized function to get factory-built units
local function getFactoryBuiltUnits()
    local result = {}
    local units = spGetTeamUnits(myTeamID)
    
    -- Clear reused table
    for k in pairs(factoryBuiltIDs) do
        factoryBuiltIDs[k] = nil
    end
    
    local count = 0
    for _, unitID in ipairs(units) do
        local unitDefID = spGetUnitDefID(unitID)
        if unitDefID and UnitDefs[unitDefID].isFactory then
            local builtID = spGetUnitIsBuilding(unitID)
            if builtID then
                local builtDefID = spGetUnitDefID(builtID)
                local _, progress = spGetUnitIsBeingBuilt(builtID)
                count = count + 1
                result[count] = {unitID = builtID, unitDefID = builtDefID, progress = progress}
                factoryBuiltIDs[builtID] = true
            end
        end
    end
    return result
end

-- Optimized function to get all units under construction
local function getAllUnderConstruction()
    local result = {}
    local units = spGetTeamUnits(myTeamID)
    local count = 0
    for _, unitID in ipairs(units) do
        local unitDefID = spGetUnitDefID(unitID)
        if unitDefID then
            local isBeingBuilt, progress = spGetUnitIsBeingBuilt(unitID)
            if isBeingBuilt then
                count = count + 1
                result[count] = {unitID = unitID, unitDefID = unitDefID, progress = progress}
            end
        end
    end
    return result
end

function widget:Initialize()
    myTeamID = Spring.GetMyTeamID()
    font = WG['fonts'] and WG['fonts'].getFont(2)
end

function widget:Update(dt)
    -- Throttle updates for better performance
    local currentTime = spGetGameSeconds()
    if currentTime - lastUpdateTime < updateInterval then
        return
    end
    lastUpdateTime = currentTime
    
    -- Clear tracking tables
    for i = #factoryUnits, 1, -1 do factoryUnits[i] = nil end
    for i = #otherUnits, 1, -1 do otherUnits[i] = nil end
    
    -- Track which units are active this frame
    local newActiveUnitIDs = {}
    
    -- Get all units under construction
    local allUnderConstruction = getAllUnderConstruction()
    local factoryBuilt = getFactoryBuiltUnits()
    
    -- Process factory-built units
    for _, entry in ipairs(factoryBuilt) do
        factoryUnits[#factoryUnits+1] = entry
        updateETAState(entry.unitID, entry.progress)
        newActiveUnitIDs[entry.unitID] = true
    end
    
    -- Process field-built units
    for i = 1, #allUnderConstruction do
        local entry = allUnderConstruction[i]
        local unitID = entry.unitID
        if not factoryBuiltIDs[unitID] then
            otherUnits[#otherUnits+1] = entry
            updateETAState(unitID, entry.progress)
            newActiveUnitIDs[unitID] = true
        end
    end
    
    -- Clean up old entries from etaState
    for unitID in pairs(activeUnitIDs) do
        if not newActiveUnitIDs[unitID] then
            etaState[unitID] = nil
        end
    end
    
    -- Update active unit tracking
    activeUnitIDs = newActiveUnitIDs
end

-- Helper function to draw a unit with its ETA display
local function drawUnitWithETA(x, y, unitInfo)
    local state = etaState[unitInfo.unitID]
    local padding = 2
    
    -- Draw background - simplified approach
    glColor(0.08, 0.08, 0.08, 0.95)
    glRect(x-padding, y-padding, x+iconSize+padding, y+iconSize+padding)
    
    glColor(0.15, 0.15, 0.15, 0.95)
    glRect(x, y, x+iconSize, y+iconSize)
    
    -- Draw the unit icon directly with basic texture rendering
    glColor(1, 1, 1, 1)
    glTexture("#"..unitInfo.unitDefID)
    glTexRect(x, y, x+iconSize, y+iconSize)
    glTexture(false)
    
    -- Progress indicator - simplified approach
    if unitInfo.progress < 1 then
        glColor(0, 0, 0, 0.5)
        local w = iconSize * (1-unitInfo.progress)
        glRect(x, y, x+w, y+iconSize)
    end

    -- ETA text with shadow
    if font and state then
        local etaText = ""
        local etaFontSize = 16
        local showDecay = state.decaying and state.decayTime
        local showETA = not showDecay and state.timeLeft
        local seconds

        if showDecay then
            seconds = max(0, state.decayTime)
        elseif showETA then
            seconds = max(0, state.timeLeft)
        end

        if seconds then
            local minutes = floor(seconds / 60)
            local secs = floor(seconds % 60)
            etaText = string.format("%d:%02d", minutes, secs)
        end

        if etaText ~= "" then
            font:Begin()
            local textWidth = font:GetTextWidth(etaText) * etaFontSize
            local textX = x + iconSize/2 - textWidth/2
            local textY = y + iconSize/2 - etaFontSize/2

            -- Text shadow for better visibility
            font:SetTextColor(0, 0, 0, 0.8)
            for dx = -1, 1, 1 do
                for dy = -1, 1, 1 do
                    if dx ~= 0 or dy ~= 0 then
                        font:Print(etaText, textX + dx, textY + dy, etaFontSize, "o")
                    end
                end
            end

            -- Main text
            if showDecay then
                if floor(spGetGameFrame() / 45) % 2 == 0 then
                    font:SetTextColor(1, 0.2, 0.2, 1)
                else
                    font:SetTextColor(1, 1, 1, 1)
                end
            else
                font:SetTextColor(1, 1, 1, 1)
            end
            font:Print(etaText, textX, textY, etaFontSize, "o")
            font:End()
        end
    end
end

function widget:DrawScreen()
    local vsx, vsy = Spring.GetViewGeometry()
    local iconsPerRow = 8
    local rowSpacing = 8
    local colSpacing = 8
    
    -- Clear previous icon areas
    iconAreas = {}

    -- Calculate layout only once
    local factoryStartX = (vsx / 2) - colSpacing / 2
    local factoryStartY = 125
    local otherStartX = (vsx / 2) + colSpacing / 2
    local otherStartY = 125

    -- Draw factory units (left column)
    for i, unitInfo in ipairs(factoryUnits) do
        local row = floor((i - 1) / iconsPerRow)
        local col = (i - 1) % iconsPerRow
        local x = factoryStartX - (col + 1) * (iconSize + colSpacing)
        local y = factoryStartY + row * (iconSize + rowSpacing)
        
        drawUnitWithETA(x, y, unitInfo)
        
        -- Store clickable area with unit ID
        iconAreas[#iconAreas+1] = {
            x1 = x, 
            y1 = y, 
            x2 = x + iconSize, 
            y2 = y + iconSize, 
            unitID = unitInfo.unitID
        }
    end

    -- Draw other units (right column)
    for i, unitInfo in ipairs(otherUnits) do
        local row = floor((i - 1) / iconsPerRow)
        local col = (i - 1) % iconsPerRow
        local x = otherStartX + col * (iconSize + colSpacing)
        local y = otherStartY + row * (iconSize + rowSpacing)
        
        drawUnitWithETA(x, y, unitInfo)
        
        -- Store clickable area with unit ID
        iconAreas[#iconAreas+1] = {
            x1 = x, 
            y1 = y, 
            x2 = x + iconSize, 
            y2 = y + iconSize, 
            unitID = unitInfo.unitID
        }
    end

    -- Reset GL state
    glColor(1,1,1,1)
end

-- Add helper function to check if point is in rectangle
local function isInRect(x, y, rect)
    return x >= rect.x1 and x <= rect.x2 and y >= rect.y1 and y <= rect.y2
end

-- Add mouse click handler
function widget:MousePress(x, y, button)
    if button == 1 then  -- Left click
        -- Check if click was on any icon
        for _, area in ipairs(iconAreas) do
            if isInRect(x, y, area) then
                -- Get unit position
                local ux, uy, uz = spGetUnitPosition(area.unitID)
                if ux then
                    -- Move camera to unit
                    spSetCameraTarget(ux, uy, uz)
                    return true  -- Consume the click
                end
            end
        end
    end
    return false  -- Don't consume other clicks
end

function widget:PlayerChanged()
    myTeamID = Spring.GetMyTeamID()
end