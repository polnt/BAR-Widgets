function widget:GetInfo()
    return {
        name    = "Subgroup Cycle",
        desc    = "Press Tab with a mixed selection to cycle through selecting one unit type at a time (SC2-style), with a visual overlay showing where you are in the cycle.",
        author  = "polnt",
        date    = "2026",
        license = "GNU GPL, v2 or later",
        layer   = 5, -- after FlowUI/Info so WG.FlowUI is ready when we need it
        enabled = true,
    }
end

-- Bindable action name (see README "Design notes"). Rebind with e.g.
-- `bind <key> subgroup_cycle` in your own uikeys.txt, or live via /bind.
local ACTION_NAME = "subgroup_cycle"

-- Cycle state
local baseSelection     = {}   -- full mixed selection when the cycle started
local typeOrder         = {}   -- ordered unique unitDefIDs in baseSelection
local cycleIndex        = 0
local lastAppliedSubset = {}   -- subset selected on the last Tab press

-- Overlay state
local showOverlay      = false
local overlayTypeOrder = {}

-- Global unit order, read from the build menu so our cycle order matches
-- what BAR's own selection panel shows.
local globalUnitOrderIndex = {}
local globalUnitOrderReady = false

local function refreshGlobalUnitOrder()
    if WG['buildmenu'] and WG['buildmenu'].getOrder then
        local order = WG['buildmenu'].getOrder()
        globalUnitOrderIndex = {}
        for index, defID in pairs(order) do
            globalUnitOrderIndex[defID] = index
        end
        globalUnitOrderReady = true
    end
end

local function buildTypeOrder(unitIDs)
    if not globalUnitOrderReady then
        refreshGlobalUnitOrder()
    end

    local seen = {}
    for _, unitID in ipairs(unitIDs) do
        local defID = Spring.GetUnitDefID(unitID)
        if defID and seen[defID] == nil then
            seen[defID] = true
        end
    end

    local order = {}
    for defID in pairs(seen) do
        order[#order + 1] = defID
    end

    table.sort(order, function(a, b)
        local posA = globalUnitOrderIndex[a] or (100000 + a)
        local posB = globalUnitOrderIndex[b] or (100000 + b)
        return posA < posB
    end)

    return order
end

local function selectionsMatch(a, b)
    if #a ~= #b then return false end
    local setB = {}
    for _, id in ipairs(b) do setB[id] = true end
    for _, id in ipairs(a) do
        if not setB[id] then return false end
    end
    return true
end

-- Overlay rendering: uses WG.FlowUI.Draw.Unit / Element, the same primitives
-- gui_info.lua and gui_unitgroups.lua use, so it stays visually consistent.
local vsx, vsy = Spring.GetViewGeometry()
local elementCorner
local RectRound, UiElement, UiUnit
local backgroundRect = { 0, 0, 0, 0 }

local function computeLayout()
    vsx, vsy = Spring.GetViewGeometry()
    local margin = 4
    local n = math.max(1, #overlayTypeOrder)

    -- Anchored to the control-groups panel's own position (rather than a
    -- fixed spot), since it moves depending on whether the build menu is
    -- docked at the bottom or on the left.
    if WG['unitgroups'] and WG['unitgroups'].getPosition then
        local posXFrac, bottomPx, rightPx, topPx = WG['unitgroups'].getPosition()
        if bottomPx and rightPx and topPx then
            local leftPx = (posXFrac or 0) * vsx
            local panelHeight = topPx - bottomPx
            local cellSize = panelHeight - (2 * margin)
            local width = (cellSize * n) + (margin * (n + 1))
            backgroundRect = { leftPx, topPx + margin, leftPx + width, topPx + margin + panelHeight }
            return
        end
    end

    -- Fallback if the control-groups panel isn't available
    local cellSize = 0.046 * vsy
    local width = (cellSize * n) + (margin * (n + 1))
    backgroundRect = { 0, cellSize + margin, width, (cellSize * 2) + margin }
end

function widget:ViewResize()
    computeLayout()
    if WG.FlowUI then
        elementCorner = WG.FlowUI.elementCorner
        RectRound     = WG.FlowUI.Draw.RectRound
        UiElement     = WG.FlowUI.Draw.Element
        UiUnit        = WG.FlowUI.Draw.Unit
    end
end

local function tryLoadFlowUI()
    if not UiUnit and WG.FlowUI then
        widget:ViewResize()
    end
end

local function drawBorder(rect, r, g, b, a, lineWidth)
    gl.LineWidth(lineWidth or 3)
    gl.Color(r, g, b, a)
    gl.BeginEnd(GL.LINE_LOOP, function()
        gl.Vertex(rect[1], rect[2], 0)
        gl.Vertex(rect[3], rect[2], 0)
        gl.Vertex(rect[3], rect[4], 0)
        gl.Vertex(rect[1], rect[4], 0)
    end)
    gl.LineWidth(1)
end

local function drawOverlayIcon(cellRect, defID, isActive)
    gl.Color(1, 1, 1, 1)
    UiUnit(
        cellRect[1], cellRect[2], cellRect[3], cellRect[4],
        elementCorner,
        1, 1, 1, 1,
        0.05,
        nil, isActive and 0.32 or 0.08,
        "#" .. defID,
        nil, nil, nil
    )
    if isActive then
        gl.Blending(GL.SRC_ALPHA, GL.ONE)
        gl.Color(1, 1, 1, 0.3)
        RectRound(cellRect[1], cellRect[2], cellRect[3], cellRect[4], elementCorner)
        gl.Blending(GL.SRC_ALPHA, GL.ONE_MINUS_SRC_ALPHA)

        local expand = 2
        local borderRect = { cellRect[1] - expand, cellRect[2] - expand, cellRect[3] + expand, cellRect[4] + expand }
        drawBorder(borderRect, 1, 0.78, 0.15, 1, 3)
    end
end

function widget:DrawScreen()
    if not showOverlay or #overlayTypeOrder <= 1 then
        return
    end

    tryLoadFlowUI()
    if not UiUnit or not UiElement then
        return
    end

    computeLayout() -- re-anchor every frame in case the control-groups panel moved

    gl.Blending(GL.SRC_ALPHA, GL.ONE_MINUS_SRC_ALPHA)
    UiElement(backgroundRect[1], backgroundRect[2], backgroundRect[3], backgroundRect[4], 0, 1, 0, 0, nil, nil, nil, nil, nil, nil, nil, nil)

    local margin = 4
    local cellSize = (backgroundRect[4] - backgroundRect[2]) - (2 * margin)

    for i, defID in ipairs(overlayTypeOrder) do
        local left  = backgroundRect[1] + margin + ((i - 1) * (cellSize + margin))
        local right = left + cellSize
        local cell  = { left, backgroundRect[2] + margin, right, backgroundRect[4] - margin }
        drawOverlayIcon(cell, defID, i == cycleIndex)
    end

    gl.Color(1, 1, 1, 1)
end

local function CycleAction()
    local selected = Spring.GetSelectedUnits()
    if #selected == 0 then return end

    if not selectionsMatch(selected, lastAppliedSubset) then
        baseSelection = selected
        typeOrder     = buildTypeOrder(selected)
        cycleIndex    = 0
    end

    if #typeOrder <= 1 then
        return
    end

    cycleIndex = cycleIndex + 1
    if cycleIndex > #typeOrder then
        cycleIndex = 1
    end

    local targetDefID = typeOrder[cycleIndex]
    local subset = {}
    for _, unitID in ipairs(baseSelection) do
        if Spring.GetUnitDefID(unitID) == targetDefID then
            subset[#subset + 1] = unitID
        end
    end

    -- Set before selecting: SelectionChanged fires synchronously from
    -- SelectUnitArray and must see the subset we're about to apply.
    lastAppliedSubset = subset
    overlayTypeOrder  = typeOrder
    showOverlay       = true

    Spring.SelectUnitArray(subset)
end

-- Whatever's natively bound to plain Tab (e.g. GRID's "selectcomm focus"),
-- snapshotted in Initialize so Shutdown can restore it exactly. Only set
-- when we actually claim Tab as the default (see widget:Initialize).
local savedTabBindings = nil
local didAutoBindTab    = false

function widget:Initialize()
    refreshGlobalUnitOrder()
    widget:ViewResize()

    widgetHandler:AddAction(ACTION_NAME, CycleAction, nil, "p")

    -- Only claim Tab as a default if the player hasn't already bound this
    -- action to a key of their own choosing (e.g. via their own uikeys.txt).
    -- That way rebinding away from Tab is respected instead of being
    -- fought on every widget load.
    local existingHotkeys = Spring.GetActionHotKeys(ACTION_NAME)
    if not existingHotkeys or #existingHotkeys == 0 then
        -- BAR's GRID keyset binds "selectcomm focus" to plain Tab in its own
        -- uikeys.txt, loaded before this widget ever runs. Actions bound to
        -- the same keyset are tried in bind order with first match winning,
        -- so that native binding always wins the race regardless of how we
        -- listen for Tab -- it has to be cleared for cycling to work at all.
        -- Freeing it here only edits this session's live keyset, never the
        -- user's uikeys.txt file, so Shutdown below restores it exactly.
        savedTabBindings = Spring.GetKeyBindings("tab")
        Spring.SendCommands("unbindkeyset tab")
        Spring.SendCommands("bind tab " .. ACTION_NAME)
        didAutoBindTab = true
    end
end

function widget:Shutdown()
    if not didAutoBindTab then return end

    Spring.SendCommands("unbindkeyset tab")
    for _, kb in ipairs(savedTabBindings or {}) do
        local action = (kb.extra ~= "" and (kb.command .. " " .. kb.extra)) or kb.command
        Spring.SendCommands("bind tab " .. action)
    end
end

function widget:SelectionChanged(sel)
    sel = sel or {}
    if not selectionsMatch(sel, lastAppliedSubset) then
        baseSelection     = {}
        typeOrder         = {}
        cycleIndex        = 0
        lastAppliedSubset = {}
        showOverlay       = false
    end
end
