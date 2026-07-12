function widget:GetInfo()
    return {
        name      = "Clone Builder (Drag‑Copy)",
        desc      = "Shift‑drag to copy selected units with ghost preview + terrain collision con units everywhere",
        author    = "Armis71 + Copilot",
        version   = "0.9",
        date      = "2026",
        license   = "GPLv2",
        layer     = 0,
        enabled   = true
    }
end

local swapped = false

--------------------------------------------------------------------------------
-- NEW SECTION: Widget options (3 patterns)
--------------------------------------------------------------------------------
options = {
    patternMode = {
        name  = "Build Order Pattern",
        type  = "list",
        value = "rowmajor",
        items = {
            {key="rowmajor", name="Row‑major"},
            {key="colmajor", name="Column‑major"},
        },
        desc = "Controls the order builders follow when placing copied buildings."
    },
}


--------------------------------------------------------------------------------
-- NEW SECTION: Sorting helpers
--------------------------------------------------------------------------------
-- Correct Row-major: left/right first
local function SortRowMajor(list)
    table.sort(list, function(a, b)
        if math.abs(a.gx - b.gx) < 1e-3 then
            return a.gz < b.gz
        else
            return a.gx < b.gx
        end
    end)
end

-- Correct Column-major: up/down first
local function SortColumnMajor(list)
    table.sort(list, function(a, b)
        if math.abs(a.gz - b.gz) < 1e-3 then
            return a.gx < b.gx
        else
            return a.gz < b.gz
        end
    end)
end


--------------------------------------------------------------------------------
-- NEW SECTION: Apply selected pattern
--------------------------------------------------------------------------------
local function ApplyPattern(list)
    -- Detect layout orientation
    local minX, maxX = math.huge, -math.huge
    local minZ, maxZ = math.huge, -math.huge

    for _, g in ipairs(list) do
        if g.gx < minX then minX = g.gx end
        if g.gx > maxX then maxX = g.gx end
        if g.gz < minZ then minZ = g.gz end
        if g.gz > maxZ then maxZ = g.gz end
    end

    local width  = maxX - minX
    local height = maxZ - minZ

    local isHorizontal = width > height

    ------------------------------------------------------------------------
    -- FINAL LOGIC:
    -- Default: horizontal=row, vertical=column
    -- Swapped: horizontal=column, vertical=row
    ------------------------------------------------------------------------

    if not swapped then
        -- normal behavior
        if isHorizontal then
            SortRowMajor(list)
        else
            SortColumnMajor(list)
        end
    else
        -- swapped behavior
        if isHorizontal then
            SortColumnMajor(list)
        else
            SortRowMajor(list)
        end
    end
end


--------------------------------------------------------------------------------
-- Original code continues unchanged below
--------------------------------------------------------------------------------

local spGetSelectedUnits = Spring.GetSelectedUnits
local spGetUnitDefID     = Spring.GetUnitDefID
local spGetUnitPosition  = Spring.GetUnitPosition
local spTestBuildOrder   = Spring.TestBuildOrder
local spGetMouseState    = Spring.GetMouseState
local spTraceScreenRay   = Spring.TraceScreenRay
local spGiveOrderToUnit  = Spring.GiveOrderToUnit
local spPlaySoundFile    = Spring.PlaySoundFile
local spGetTimer         = Spring.GetTimer
local spDiffTimers       = Spring.DiffTimers

local ghostData = {}
local dragging  = false
local rotation  = 0

local lastSoundTime = nil
local soundInterval = 0.30

--------------------------------------------------------------------------------
-- Split selection into builders and buildings (with Dragon's Teeth support)
--------------------------------------------------------------------------------
local function SplitSelection()
    local builders = {}
    local buildings = {}

    local selected = spGetSelectedUnits()
    for _, id in ipairs(selected) do
        local udid = spGetUnitDefID(id)
        local ud = UnitDefs[udid]

        -- TRUE builders have buildOptions
        if ud and ud.buildOptions and #ud.buildOptions > 0 then
            table.insert(builders, id)

        else
            -- Dragon's Teeth unitDef names
            local name = ud and ud.name
            if name == "armdrag" or name == "cordrag" or name == "legdrag" then
                -- treat Dragon's Teeth as buildings
                table.insert(buildings, id)
            else
                -- Everything else is a building
                table.insert(buildings, id)
            end
        end
    end

    return builders, buildings
end


--------------------------------------------------------------------------------
-- Auto-detect Dragon's Teeth as buildings for drag-copy
--------------------------------------------------------------------------------
local function IsDragonsTeeth(ud)
    if not ud or not ud.name then return false end

    -- Dragon's Teeth unitDef names
    return (ud.name == "armdrag") or
           (ud.name == "cordrag") or
           (ud.name == "legdrag")
end



--------------------------------------------------------------------------------
-- Create ghost objects (with nano turret priority)
--------------------------------------------------------------------------------
local nanoTurrets = {
    legnanotc = true,
    armnanotc = true,
    cornanotc = true,
}

--------------------------------------------------------------------------------
-- Create ghost objects (each building keeps its own unit type)
--------------------------------------------------------------------------------
local function CreateGhosts(buildings)
    ghostData = {}

    for _, unitID in ipairs(buildings) do
        local udid = spGetUnitDefID(unitID)
        local x, y, z = spGetUnitPosition(unitID)

        table.insert(ghostData, {
            udid = udid,           -- KEEP ORIGINAL UNIT TYPE
            ox = x, oy = y, oz = z,
            gx = x, gy = y, gz = z,
            valid = true,
        })
    end
end


--------------------------------------------------------------------------------
-- Update ghost positions + sound loop
--------------------------------------------------------------------------------
local function UpdateGhostPositions()
    local mx, my = spGetMouseState()
    local _, pos = spTraceScreenRay(mx, my, true)
    if not pos then return end

    local tx, ty, tz = pos[1], pos[2], pos[3]

    local cx, cy, cz = 0, 0, 0
    for _, g in ipairs(ghostData) do
        cx = cx + g.ox
        cy = cy + g.oy
        cz = cz + g.oz
    end
    cx = cx / #ghostData
    cy = cy / #ghostData
    cz = cz / #ghostData

    for _, g in ipairs(ghostData) do
        local dx = g.ox - cx
        local dz = g.oz - cz

        local rx = dx * math.cos(math.rad(rotation)) - dz * math.sin(math.rad(rotation))
        local rz = dx * math.sin(math.rad(rotation)) + dz * math.cos(math.rad(rotation))

        g.gx = tx + rx
        g.gy = ty
        g.gz = tz + rz

        local canBuild = spTestBuildOrder(g.udid, g.gx, g.gy, g.gz, rotation)
        g.valid = (canBuild == 2)
    end

    if lastSoundTime then
        local now = spGetTimer()
        local dt = spDiffTimers(now, lastSoundTime)
        if dt > soundInterval then
            spPlaySoundFile("LuaUI/Sounds/land.wav", 1.0)
            lastSoundTime = now
        end
    end
end

--------------------------------------------------------------------------------
-- MousePress: start drag-copy (Shift)
--------------------------------------------------------------------------------
function widget:MousePress(x, y, button)
    local ctrl, alt, meta, shift = Spring.GetModKeyState()
    if button == 1 and shift then
        local builders, buildings = SplitSelection()

        if #builders > 0 and #buildings > 0 then
            dragging = true
            rotation = 0
            CreateGhosts(buildings)

            lastSoundTime = spGetTimer()

            return true
        end
    end
end

--------------------------------------------------------------------------------
-- MouseMove
--------------------------------------------------------------------------------
function widget:MouseMove()
    if dragging then
        UpdateGhostPositions()
        return true
    end
end


function widget:KeyPress(key)
    if not dragging then return end

    -- SPACE = rotate
    if key == 32 then
        rotation = (rotation + 90) % 360
        UpdateGhostPositions()
        return true
    end

    -- SHIFT + LMB + R = toggle swap
    local ctrl, alt, meta, shift = Spring.GetModKeyState()
    local mx, my, lmb = Spring.GetMouseState()

    if shift and lmb and key == string.byte('r') then
        swapped = not swapped
        Spring.Echo("DCB: swap = " .. tostring(swapped))
        return true
    end
end


--------------------------------------------------------------------------------
-- Helper: can this builder build this unitDef?
--------------------------------------------------------------------------------
local function BuilderCanBuild(builderDef, unitDefID)
    if not builderDef or not builderDef.buildOptions then
        return false
    end

    for _, optID in ipairs(builderDef.buildOptions) do
        if optID == unitDefID then
            return true
        end
    end

    return false
end

-- Find the best builder that can build a given unitDefID
local function FindPrimaryBuilder(builders, targetUnitDefID)
    local primary = nil

    for _, builder in ipairs(builders) do
        local builderDefID = spGetUnitDefID(builder)
        local builderDef = UnitDefs[builderDefID]

        if BuilderCanBuild(builderDef, targetUnitDefID) then
            -- Prefer highest-tier builder (largest buildOptions count)
            if not primary or #builderDef.buildOptions > #UnitDefs[spGetUnitDefID(primary)].buildOptions then
                primary = builder
            end
        end
    end

    return primary
end


--------------------------------------------------------------------------------
-- MouseRelease: Blueprint-style mixed-tech assist (BUILD for everyone)
--------------------------------------------------------------------------------
function widget:MouseRelease()
    if dragging then
        dragging = false
        lastSoundTime = nil

        local builders, buildings = SplitSelection()

        -- Apply sorting pattern
        ApplyPattern(ghostData)

        --------------------------------------------------------------------
        -- STEP 1: Issue BUILD command to EVERY builder
        -- Spring will auto-convert invalid builds into assist
        --------------------------------------------------------------------
        for _, g in ipairs(ghostData) do
            if g.valid then
                for _, builder in ipairs(builders) do
                    spGiveOrderToUnit(
                        builder,
                        -g.udid,                 -- BUILD command
                        { g.gx, g.gy, g.gz },    -- position
                        { "shift" }
                    )
                end
            end
        end

        ghostData = {}
        return true
    end
end


local function GetCurrentPatternName(isHorizontal)
    if not swapped then
        if isHorizontal then
            return "Row"
        else
            return "Column"
        end
    else
        if isHorizontal then
            return "Column"
        else
            return "Row"
        end
    end
end

function widget:DrawScreen()
    if not dragging then return end

    -- Get mouse world position
    local mx, my = Spring.GetMouseState()
    local _, pos = Spring.TraceScreenRay(mx, my, true)
    if not pos then return end

    local px, py, pz = pos[1], pos[2], pos[3]

    -- Convert world → screen
    local sx, sy = Spring.WorldToScreenCoords(px, py, pz)
    if not sx or not sy then return end

    ---------------------------------------------------------
    -- Determine layout orientation
    ---------------------------------------------------------
    local minX, maxX = math.huge, -math.huge
    local minZ, maxZ = math.huge, -math.huge
    for _, g in ipairs(ghostData) do
        if g.gx < minX then minX = g.gx end
        if g.gx > maxX then maxX = g.gx end
        if g.gz < minZ then minZ = g.gz end
        if g.gz > maxZ then maxZ = g.gz end
    end
    local width  = maxX - minX
    local height = maxZ - minZ
    local isHorizontal = width > height

    local label
    if not swapped then
        label = isHorizontal and "Column" or "Row"
    else
        label = isHorizontal and "Row" or "Column"
    end

---------------------------------------------------------
-- SCREEN-SPACE TEXT WITH SHADOW
---------------------------------------------------------

local shadowOffset = 3
local labelSize    = 36
local hintSize     = 18

---------------------------------------------------------
-- Row/Column label (TOP)
---------------------------------------------------------
gl.Color(0, 0, 0, 0.8)
gl.Text(label, sx + shadowOffset, sy + 60 - shadowOffset, labelSize, "oc")

gl.Color(1, 1, 1, 1)
gl.Text(label, sx, sy + 60, labelSize, "oc")

---------------------------------------------------------
-- Spacebar hint (MIDDLE)
---------------------------------------------------------
gl.Color(0, 0, 0, 0.8)
gl.Text("Spacebar to rotate", sx + shadowOffset, sy + 30 - shadowOffset, hintSize, "oc")

gl.Color(1, 1, 1, 1)
gl.Text("Spacebar to rotate", sx, sy + 30, hintSize, "oc")

---------------------------------------------------------
-- R to change pattern (BOTTOM)
---------------------------------------------------------
gl.Color(0, 0, 0, 0.8)
gl.Text("R to change pattern", sx + shadowOffset, sy + 0 - shadowOffset, hintSize, "oc")

gl.Color(1, 1, 1, 1)
gl.Text("R to change pattern", sx, sy + 0, hintSize, "oc")


    end



--------------------------------------------------------------------------------
-- Draw ghosts
--------------------------------------------------------------------------------
function widget:DrawWorld()
    if not dragging then return end

    ---------------------------------------------------------
    -- Get mouse world position
    ---------------------------------------------------------
    local mx, my = Spring.GetMouseState()
    local _, pos = Spring.TraceScreenRay(mx, my, true)
    if not pos then return end

    local px, py, pz = pos[1], pos[2], pos[3]

    ---------------------------------------------------------
    -- Determine layout orientation
    ---------------------------------------------------------
    local minX, maxX = math.huge, -math.huge
    local minZ, maxZ = math.huge, -math.huge
    for _, g in ipairs(ghostData) do
        if g.gx < minX then minX = g.gx end
        if g.gx > maxX then maxX = g.gx end
        if g.gz < minZ then minZ = g.gz end
        if g.gz > maxZ then maxZ = g.gz end
    end
    local width  = maxX - minX
    local height = maxZ - minZ
    local isHorizontal = width > height

    ---------------------------------------------------------
    -- Corrected label
    ---------------------------------------------------------
    local label
    if not swapped then
        label = isHorizontal and "Column" or "Row"
    else
        label = isHorizontal and "Row" or "Column"
    end

    ---------------------------------------------------------
    -- Draw ghosts (original behavior)
    ---------------------------------------------------------
    gl.DepthTest(true)

    for _, g in ipairs(ghostData) do
        if g.valid then gl.Color(0, 1, 0, 0.4)
        else gl.Color(1, 0, 0, 0.4) end

        gl.PushMatrix()
        gl.Translate(g.gx, g.gy, g.gz)
        gl.Rotate(rotation, 0, 1, 0)
        gl.UnitShape(g.udid, 0)
        gl.PopMatrix()
    end

    gl.DepthTest(false)

    ---------------------------------------------------------
    -- SCREEN-SPACE TEXT (ALWAYS UPRIGHT, ALWAYS VISIBLE)
    ---------------------------------------------------------

    -- Convert world → screen
    local sx, sy = Spring.WorldToScreenCoords(px, py, pz)

    -- Main Row/Column label
    gl.Color(1, 1, 1, 1)
    gl.Text(label, sx, sy + 40, 30, "oc")

    -- Hint: Spacebar to rotate
    gl.Text("Spacebar to rotate", sx, sy + 20, 10, "oc")

    gl.Color(1,1,1,1)
end


-- end of drag_copy_builder.lua
