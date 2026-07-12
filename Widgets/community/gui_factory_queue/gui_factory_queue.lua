local widget = widget ---@type Widget

function widget:GetInfo()
	return {
		name = "Factory Queue",
		desc = "Shows and lets you reorder the selected factory's production queue",
		author = "Codex and GammaPath",
		date = "June 2026",
		license = "Do whatever you want",
		layer = -1,
		enabled = true,
		handler = true,
	}
end

local spGetFactoryCommands = Spring.GetFactoryCommands
local spGetSelectedUnits = Spring.GetSelectedUnits
local spGetUnitCmdDescs = Spring.GetUnitCmdDescs
local spGetUnitDefID = Spring.GetUnitDefID
local spGetUnitIsBeingBuilt = Spring.GetUnitIsBeingBuilt
local spGetUnitIsBuilding = Spring.GetUnitIsBuilding
local spGetViewGeometry = Spring.GetViewGeometry
local spGiveOrderToUnit = Spring.GiveOrderToUnit

local glColor = gl.Color
local glRect = gl.Rect
local glTexRect = gl.TexRect
local glTexture = gl.Texture

local mathAbs = math.abs
local mathFloor = math.floor
local mathMax = math.max
local mathMin = math.min

local CMD_OPT_ALT = CMD.OPT_ALT
local CMD_OPT_CTRL = CMD.OPT_CTRL
local CMD_OPT_INTERNAL = CMD.OPT_INTERNAL

local gridConfig = VFS.Include("luaui/configs/gridmenu_config.lua")
local unitBlocking = VFS.Include("luaui/Include/unitBlocking.lua")

local POLL_INTERVAL = 0.12
local MIN_ICON_SIZE = 18
local MAX_ICON_SIZE = 44
local DRAG_THRESHOLD = 4
local QUEUE_FIT_ALLOWANCE = 10

local vsx, vsy = spGetViewGeometry()
local font
local UiUnit
local RectRoundProgress
local selectedFactoryID
local factoryHasNextPage = false
local factoryBuildOptionCount = 0
local queue = {}
local queueDirty = true
local productionAdvanced = false
local pollTime = 0
local reorderCooldown = 0
local chobbyInterface = false
local panelVisible = false
local queueRects = {}
local overflowRect
local queueExpanded = false
local dragSource
local dragTarget
local dragStartX
local dragStartY
local dragX
local dragging = false
local visualPositions = {}
local settleIndex
local settleX
local settleGhost
local settlePositions = {}

local panel = {
	x1 = 0,
	y1 = 0,
	x2 = 0,
	hitX2 = 0,
	y2 = 0,
	iconSize = 0,
	padding = 0,
	gap = 0,
}

local function clearQueue()
	for i = 1, #queue do
		queue[i] = nil
	end
end

local function clearQueueRects()
	for i = 1, #queueRects do
		queueRects[i] = nil
	end
end

local function clearDrag()
	dragSource = nil
	dragTarget = nil
	dragStartX = nil
	dragStartY = nil
	dragX = nil
	dragging = false
	for i = 1, #visualPositions do
		visualPositions[i] = nil
	end
end

local function clearSettle()
	settleIndex = nil
	settleX = nil
	settleGhost = nil
	for i in pairs(settlePositions) do
		settlePositions[i] = nil
	end
end

local function updateFactoryPagination()
	factoryHasNextPage = false
	factoryBuildOptionCount = 0
	if not selectedFactoryID then
		return
	end

	local unitDefID = spGetUnitDefID(selectedFactoryID)
	local commands = spGetUnitCmdDescs(selectedFactoryID)
	if not unitDefID or not commands then
		return
	end

	local gridOptions = gridConfig.getSortedGridForLab(unitDefID, commands)
	local blockedUnits = unitBlocking.getBlockedUnitDefs()
	local visibleOptions = 0
	for _, option in pairs(gridOptions) do
		local optionUnitDefID = option.id and -option.id
		local reasons = optionUnitDefID and blockedUnits[optionUnitDefID]
		if optionUnitDefID and not (reasons and reasons.hidden) then
			visibleOptions = visibleOptions + 1
		end
	end
	factoryBuildOptionCount = visibleOptions
	factoryHasNextPage = visibleOptions > 12
end

local function updateSelection(selection)
	clearDrag()
	clearSettle()
	productionAdvanced = false
	queueExpanded = false
	overflowRect = nil
	selectedFactoryID = nil

	if #selection ~= 1 then
		clearQueue()
		return
	end

	local unitID = selection[1]
	local unitDefID = spGetUnitDefID(unitID)
	local unitDef = unitDefID and UnitDefs[unitDefID]
	if not unitDef or not unitDef.isFactory or spGetUnitIsBeingBuilt(unitID) then
		clearQueue()
		return
	end

	selectedFactoryID = unitID
	updateFactoryPagination()
	queueDirty = true
end

local function refreshQueue()
	queueDirty = false
	local previousQueue = {}
	for i = 1, #queue do
		previousQueue[i] = {
			unitDefID = queue[i].unitDefID,
			count = queue[i].count,
		}
	end
	clearQueue()

	if not selectedFactoryID or not Spring.ValidUnitID(selectedFactoryID) then
		selectedFactoryID = nil
		return
	end

	local commands = spGetFactoryCommands(selectedFactoryID, -1) or {}
	for i = 1, #commands do
		local cmdID = commands[i].id
		if cmdID and cmdID < 0 then
			local unitDefID = -cmdID
			if UnitDefs[unitDefID] then
				local lastEntry = queue[#queue]
				if lastEntry and lastEntry.unitDefID == unitDefID then
					lastEntry.count = lastEntry.count + 1
					lastEntry.commands[#lastEntry.commands + 1] = commands[i]
				else
					queue[#queue + 1] = {
						unitDefID = unitDefID,
						count = 1,
						commands = { commands[i] },
					}
				end
			end
		end
	end

	if productionAdvanced and previousQueue[1] then
		local frontCountDecreased = queue[1]
			and queue[1].unitDefID == previousQueue[1].unitDefID
			and queue[1].count < previousQueue[1].count
		local frontGroupFinished = #queue == #previousQueue - 1
		for i = 1, #queue do
			local previousEntry = previousQueue[i + 1]
			if not previousEntry
				or queue[i].unitDefID ~= previousEntry.unitDefID
				or queue[i].count ~= previousEntry.count
			then
				frontGroupFinished = false
				break
			end
		end

		if frontGroupFinished then
			clearSettle()
			local step = panel.iconSize + panel.gap
			for i = 1, #queue do
				local targetX = panel.x1 + panel.padding + ((i - 1) * step)
				settlePositions[i] = targetX + step
			end
			productionAdvanced = false
		elseif frontCountDecreased or #queue == 0 then
			productionAdvanced = false
		end
	end
end

local function updatePanel()
	if not WG["buildmenu"]
		or not WG["buildmenu"].getSize
		or not WG["buildmenu"].getBottomPosition
		or not WG["ordermenu"]
		or not WG["ordermenu"].getPosition
	then
		return false
	end

	local orderX, _, orderWidth = WG["ordermenu"].getPosition()
	local buildmenuA, buildmenuB = WG["buildmenu"].getSize()
	if not orderX or not orderWidth or not buildmenuA or not buildmenuB then
		return false
	end

	if buildmenuA <= 1 and buildmenuB <= 1 then
		buildmenuA = buildmenuA * vsy
		buildmenuB = buildmenuB * vsy
	end
	local buildmenuY1 = mathMin(buildmenuA, buildmenuB)
	local buildmenuY2 = mathMax(buildmenuA, buildmenuB)

	local backgroundPadding = WG.FlowUI and WG.FlowUI.elementPadding or 4
	local padding = mathMax(2, mathFloor(backgroundPadding * 0.35))
	local usingGridMenu = WG["buildmenu"].getDynamicIconsize == nil

	if WG["buildmenu"].getBottomPosition() then
		local uiScale = WG.FlowUI and WG.FlowUI.scale or 1
		local elementMargin = WG.FlowUI and WG.FlowUI.elementMargin or backgroundPadding
		local orderRight = mathFloor((orderX + orderWidth) * vsx)
		if not usingGridMenu then
			local iconSize = mathFloor(MAX_ICON_SIZE * (vsy / 1080))
			panel.x1 = orderRight + elementMargin
			panel.y1 = mathFloor(buildmenuY2 + elementMargin)
			panel.x2 = vsx - padding
			panel.y2 = panel.y1 + iconSize + (padding * 2)
			panel.iconSize = iconSize
			panel.padding = padding
			panel.gap = mathMax(1, mathFloor(iconSize * 0.08) - 1)
			return panel.x2 > panel.x1 and panel.y2 <= vsy
		end

		local cellSize = mathFloor(((buildmenuY2 - buildmenuY1) - backgroundPadding) / 2)
		local categoryFontSize = 0.013 * uiScale * vsy
		local categoryWidth = 10 * categoryFontSize * uiScale
		local buildpicsX1 = orderRight + elementMargin + categoryWidth + backgroundPadding
		local buildpicsX2 = buildpicsX1 + (cellSize * 6)
		local iconSize = mathFloor(
			mathMin(MAX_ICON_SIZE * (vsy / 1080), cellSize - (padding * 2))
		)
		if iconSize < MIN_ICON_SIZE then
			return false
		end

		panel.x1 = mathFloor(buildpicsX1 - padding)
		panel.y1 = mathFloor(buildmenuY2 + elementMargin)
		panel.x2 = mathFloor(mathMin(vsx, buildpicsX2 + padding))
		panel.y2 = panel.y1 + iconSize + (padding * 2)
		panel.iconSize = iconSize
		panel.padding = padding
		panel.gap = mathMax(1, mathFloor(iconSize * 0.08) - 1)
		return panel.x2 > panel.x1 and panel.y2 <= vsy
	end

	local backgroundX1 = 0
	local backgroundX2 = mathFloor(orderWidth * vsx)
	if not usingGridMenu then
		local activeAreaMargin = math.ceil(backgroundPadding * 0.1)
		local activeX1 = backgroundX1 + backgroundPadding + activeAreaMargin
		local activeX2 = backgroundX2 - backgroundPadding - activeAreaMargin
		local activeY1 = buildmenuY1 + backgroundPadding + activeAreaMargin
		local activeY2 = buildmenuY2 - backgroundPadding - activeAreaMargin
		local contentWidth = activeX2 - activeX1
		local contentHeight = activeY2 - activeY1
		local dynamicIconSize = WG["buildmenu"].getDynamicIconsize
			and WG["buildmenu"].getDynamicIconsize()
		local columns = dynamicIconSize
			and WG["buildmenu"].getMinColls
			and WG["buildmenu"].getMinColls()
			or (WG["buildmenu"].getDefaultColls and WG["buildmenu"].getDefaultColls())
			or 5
		local maxColumns = WG["buildmenu"].getMaxColls
			and WG["buildmenu"].getMaxColls()
			or columns
		local maxCellSize = contentHeight / 2
		local cellSize = mathMin(maxCellSize, mathFloor(contentWidth / columns))
		local rows = mathFloor(contentHeight / cellSize)

		if dynamicIconSize then
			while factoryBuildOptionCount > rows * columns and columns < maxColumns do
				columns = columns + 1
				cellSize = mathMin(maxCellSize, mathFloor(contentWidth / columns))
				rows = mathFloor(contentHeight / cellSize)
			end
		end

		local paginatorHeight = mathFloor(contentHeight - (rows * cellSize))
		if factoryBuildOptionCount > columns * rows
			and paginatorHeight < (0.06 * (1 - ((columns / 4) * 0.25))) * vsy
		then
			rows = rows - 1
		end

		local visibleOptions = mathMin(factoryBuildOptionCount, columns * rows)
		local occupiedRows = math.ceil(visibleOptions / columns)
		local gridX1 = activeX2 - (columns * cellSize)
		local gridBottom = activeY2 - (occupiedRows * cellSize)
		local y2 = mathFloor(gridBottom - backgroundPadding)
		local availableHeight = y2 - activeY1 - (padding * 2)
		if availableHeight < MIN_ICON_SIZE then
			return false
		end
		local iconSize = mathFloor(mathMin(MAX_ICON_SIZE * (vsy / 1080), availableHeight))

		panel.x1 = mathFloor(gridX1 - padding)
		panel.y1 = mathFloor(y2 - iconSize - (padding * 2))
		panel.x2 = mathFloor(activeX2 + padding)
		panel.y2 = y2
		panel.iconSize = iconSize
		panel.padding = padding
		panel.gap = mathMax(1, mathFloor(iconSize * 0.08) - 1)
		return panel.x2 > panel.x1 and panel.y2 > panel.y1
	end

	local activeX1 = backgroundX1 + backgroundPadding
	local activeX2 = backgroundX2 - backgroundPadding
	local activeWidth = activeX2 - activeX1
	local cellSize = mathFloor((backgroundX2 - backgroundX1 - (backgroundPadding * 2)) / 4)
	local buildpicsTop = buildmenuY2 - mathFloor(backgroundPadding * 1.5)
	local y1 = mathFloor(buildmenuY1 + backgroundPadding)
	local y2 = mathFloor(buildpicsTop - (cellSize * 3))
	local x1 = mathFloor(activeX1)
	local x2 = factoryHasNextPage
		and mathFloor(activeX1 + (activeWidth * (2 / 3)))
		or mathFloor(activeX2)
	local availableHeight = y2 - y1 - (padding * 2)
	if availableHeight < MIN_ICON_SIZE then
		return false
	end
	local iconSize = mathMin(MAX_ICON_SIZE * (vsy / 1080), availableHeight)
	iconSize = mathFloor(iconSize)

	panel.x1 = x1
	panel.y1 = y1
	panel.x2 = x2
	panel.y2 = y2
	panel.iconSize = iconSize
	panel.padding = padding
	panel.gap = mathMax(1, mathFloor(iconSize * 0.08) - 1)
	return x2 > x1 and y2 > y1
end

local function getCurrentBuildProgress()
	if not selectedFactoryID then
		return nil, nil
	end

	local buildUnitID = spGetUnitIsBuilding(selectedFactoryID)
	if not buildUnitID then
		return nil, nil
	end

	local buildDefID = spGetUnitDefID(buildUnitID)
	local _, progress = spGetUnitIsBeingBuilt(buildUnitID)
	return buildDefID, progress
end

local function getQueueRectAt(x, y)
	for i = 1, #queueRects do
		local rect = queueRects[i]
		if x >= rect.x1 and x <= rect.x2 and y >= rect.y1 and y <= rect.y2 then
			return i
		end
	end
end

local function getDropTarget(x)
	if #queueRects == 0 then
		return nil
	end
	if x <= panel.x1 then
		return 1
	end
	if x >= panel.hitX2 then
		return #queue + 1
	end

	for i = 1, #queueRects do
		local rect = queueRects[i]
		if x < (rect.x1 + rect.x2) * 0.5 then
			return i
		end
	end
	return #queueRects + 1
end

local function buildPreviewOrder(sourceIndex, targetIndex)
	local order = {}
	for i = 1, #queue do
		if i ~= sourceIndex then
			order[#order + 1] = i
		end
	end

	local insertIndex = targetIndex
	if insertIndex > sourceIndex then
		insertIndex = insertIndex - 1
	end
	insertIndex = mathMax(1, mathMin(insertIndex, #order + 1))
	table.insert(order, insertIndex, sourceIndex)
	return order
end

local function issueBuildCount(unitDefID, count, right, alt)
	while count > 0 do
		local opts = {}
		if right then
			opts[#opts + 1] = "right"
		end
		if alt then
			opts[#opts + 1] = "alt"
		end
		if count >= 100 then
			opts[#opts + 1] = "ctrl"
			opts[#opts + 1] = "shift"
			count = count - 100
		elseif count >= 20 then
			opts[#opts + 1] = "ctrl"
			count = count - 20
		elseif count >= 5 then
			opts[#opts + 1] = "shift"
			count = count - 5
		else
			count = count - 1
		end
		spGiveOrderToUnit(selectedFactoryID, -unitDefID, {}, opts)
	end
end

local function setLocalQueueFromCommands(commands, trackedCommand)
	clearQueue()
	local trackedIndex
	for i = 1, #commands do
		local command = commands[i]
		local unitDefID = -command.id
		local lastEntry = queue[#queue]
		if lastEntry and lastEntry.unitDefID == unitDefID then
			lastEntry.count = lastEntry.count + 1
		else
			queue[#queue + 1] = {
				unitDefID = unitDefID,
				count = 1,
				commands = {},
			}
		end
		if command == trackedCommand then
			trackedIndex = #queue
		end
	end
	return trackedIndex
end

local updateGridMenuQueueCount

local function reorderQueue(sourceIndex, targetIndex)
	if not widget.canControlUnits or not selectedFactoryID or not queue[sourceIndex] then
		return false
	end
	if not queue[1] or not queue[1].commands[1] then
		queueDirty = true
		return false
	end

	targetIndex = mathMax(1, mathMin(targetIndex, #queue + 1))
	if targetIndex == sourceIndex or targetIndex == sourceIndex + 1 then
		return false
	end

	local order = buildPreviewOrder(sourceIndex, targetIndex)
	local activeCommand = spGetUnitIsBuilding(selectedFactoryID) and queue[1].commands[1] or nil
	local firstOrderedEntry = queue[order[1]]
	local preserveActive = activeCommand
		and firstOrderedEntry
		and firstOrderedEntry.unitDefID == -activeCommand.id
	local desiredCommands = {}
	if preserveActive then
		desiredCommands[1] = activeCommand
	end

	for i = 1, #order do
		local queueIndex = order[i]
		local commands = queue[queueIndex].commands
		local firstCommand = queueIndex == 1 and preserveActive and 2 or 1
		for commandIndex = firstCommand, #commands do
			desiredCommands[#desiredCommands + 1] = commands[commandIndex]
		end
	end

	local sourceCommands = queue[sourceIndex].commands
	local firstSourceCommand = sourceIndex == 1 and preserveActive and 2 or 1
	if firstSourceCommand > #sourceCommands then
		return false
	end

	local commandsToReinsert = {}
	local commandsToReinsertSet = {}
	local tags = {}
	local removedCounts = {}
	for i = firstSourceCommand, #sourceCommands do
		local command = sourceCommands[i]
		if not command.tag then
			queueDirty = true
			return false
		end
		commandsToReinsert[#commandsToReinsert + 1] = command
		commandsToReinsertSet[command] = true
		tags[#tags + 1] = command.tag
		removedCounts[-command.id] = (removedCounts[-command.id] or 0) + 1
	end

	if activeCommand and not preserveActive and not commandsToReinsertSet[activeCommand] then
		if not activeCommand.tag then
			queueDirty = true
			return false
		end
		commandsToReinsert[#commandsToReinsert + 1] = activeCommand
		commandsToReinsertSet[activeCommand] = true
		tags[#tags + 1] = activeCommand.tag
		removedCounts[-activeCommand.id] = (removedCounts[-activeCommand.id] or 0) + 1
	end

	spGiveOrderToUnit(selectedFactoryID, CMD.REMOVE, tags, CMD_OPT_CTRL)
	for desiredIndex = 1, #desiredCommands do
		local command = desiredCommands[desiredIndex]
		if commandsToReinsertSet[command] then
			local insertParams = {
				desiredIndex - 1,
				command.id,
				CMD_OPT_ALT + CMD_OPT_INTERNAL,
			}
			for paramIndex = 1, #(command.params or {}) do
				insertParams[#insertParams + 1] = command.params[paramIndex]
			end
			spGiveOrderToUnit(
				selectedFactoryID,
				CMD.INSERT,
				insertParams,
				CMD_OPT_ALT + CMD_OPT_CTRL
			)
		end
	end

	for unitDefID, count in pairs(removedCounts) do
		updateGridMenuQueueCount(unitDefID, count)
	end
	local trackedCommand = sourceCommands[firstSourceCommand]
	local previousGroupCount = #queue
	local finalIndex = setLocalQueueFromCommands(desiredCommands, trackedCommand)
	local merged = #queue < previousGroupCount
	queueDirty = true
	pollTime = 0
	reorderCooldown = 0.15
	return true, finalIndex, merged
end

local function getModifierQuantity()
	local _, ctrl, _, shift = Spring.GetModKeyState()
	local quantity = 1
	if shift then
		quantity = quantity * 5
	end
	if ctrl then
		quantity = quantity * 20
	end
	return quantity
end

updateGridMenuQueueCount = function(unitDefID, count)
	if not widgetHandler or not widgetHandler.FindWidget then
		return
	end

	local gridMenu = widgetHandler:FindWidget("Grid menu")
	if not gridMenu or not gridMenu.UnitCommand then
		return
	end

	while count > 0 do
		local options = { right = true }
		if count >= 100 then
			options.ctrl = true
			options.shift = true
			count = count - 100
		elseif count >= 20 then
			options.ctrl = true
			count = count - 20
		elseif count >= 5 then
			options.shift = true
			count = count - 5
		else
			count = count - 1
		end
		local succeeded = pcall(
			gridMenu.UnitCommand,
			gridMenu,
			selectedFactoryID,
			nil,
			nil,
			-unitDefID,
			{},
			options
		)
		if not succeeded then
			return
		end
	end
end

local function insertAtRun(entryIndex, quantity)
	local entry = queue[entryIndex]
	if not entry then
		return
	end

	local insertPosition = 0
	for i = 1, entryIndex do
		insertPosition = insertPosition + queue[i].count
	end
	for i = 1, quantity do
		spGiveOrderToUnit(
			selectedFactoryID,
			CMD.INSERT,
			{ insertPosition + i - 1, -entry.unitDefID, CMD_OPT_ALT + CMD_OPT_INTERNAL },
			CMD_OPT_ALT + CMD_OPT_CTRL
		)
	end
	entry.count = entry.count + quantity
	reorderCooldown = 0.2
end

local function addToFront(unitDefID, quantity)
	issueBuildCount(unitDefID, quantity, false, true)
	if queue[1] and queue[1].unitDefID == unitDefID then
		queue[1].count = queue[1].count + quantity
	else
		table.insert(queue, 1, {
			unitDefID = unitDefID,
			count = quantity,
			commands = {},
		})
	end
	reorderCooldown = 0.2
end

local function removeFromRun(entryIndex, quantity)
	local entry = queue[entryIndex]
	if not entry then
		return
	end

	local removeCount = mathMin(quantity, entry.count)
	local tags = {}
	for i = #entry.commands, mathMax(1, #entry.commands - removeCount + 1), -1 do
		local tag = entry.commands[i].tag
		if tag then
			tags[#tags + 1] = tag
		end
	end
	if #tags == 0 then
		return
	end

	spGiveOrderToUnit(selectedFactoryID, CMD.REMOVE, tags, CMD_OPT_CTRL)
	updateGridMenuQueueCount(entry.unitDefID, #tags)
	for i = 1, #tags do
		table.remove(entry.commands)
	end
	entry.count = entry.count - #tags
	if entry.count <= 0 then
		table.remove(queue, entryIndex)
	end
	queueDirty = false
	pollTime = 0
	reorderCooldown = 0.2
end

local function handleQueueClick(entryIndex, button)
	if not widget.canControlUnits or not selectedFactoryID then
		return
	end

	local entry = queue[entryIndex]
	if not entry then
		return
	end

	local alt = Spring.GetModKeyState()
	local quantity = getModifierQuantity()
	if button == 3 then
		removeFromRun(entryIndex, quantity)
	elseif alt then
		addToFront(entry.unitDefID, quantity)
	else
		insertAtRun(entryIndex, quantity)
	end
end

function widget:Initialize()
	widget:ViewResize()
	updateSelection(spGetSelectedUnits())
end

function widget:ViewResize()
	vsx, vsy = spGetViewGeometry()
	font = WG["fonts"] and WG["fonts"].getFont(2)
	UiUnit = WG.FlowUI and WG.FlowUI.Draw and WG.FlowUI.Draw.Unit
	RectRoundProgress = WG.FlowUI and WG.FlowUI.Draw and WG.FlowUI.Draw.RectRoundProgress
end

function widget:SelectionChanged(selection)
	updateSelection(selection)
end

function widget:UnitCommand(unitID)
	if unitID == selectedFactoryID then
		queueDirty = true
	end
end

function widget:UnitCmdDone(unitID, unitDefID, unitTeam, cmdID)
	if unitID == selectedFactoryID then
		if cmdID and cmdID < 0 then
			productionAdvanced = true
		end
		queueDirty = true
	end
end

function widget:UnitFinished(unitID)
	local selection = spGetSelectedUnits()
	if #selection == 1 and selection[1] == unitID then
		updateSelection(selection)
	end
end

function widget:UnitDestroyed(unitID)
	if unitID == selectedFactoryID then
		selectedFactoryID = nil
		clearQueue()
	end
end

function widget:UnitTaken(unitID)
	widget:UnitDestroyed(unitID)
end

function widget:UnitGiven(unitID)
	if unitID == selectedFactoryID then
		updateFactoryPagination()
		queueDirty = true
	end
end

function widget:UnitBlocked()
	updateFactoryPagination()
end

function widget:Update(dt)
	if not selectedFactoryID then
		return
	end
	if dragSource then
		if dragging and dragTarget then
			local order = buildPreviewOrder(dragSource, dragTarget)
			for slot = 1, #order do
				local queueIndex = order[slot]
				if queueIndex ~= dragSource then
					local targetX = panel.x1 + panel.padding + ((slot - 1) * (panel.iconSize + panel.gap))
					local currentX = visualPositions[queueIndex] or targetX
					visualPositions[queueIndex] = currentX + ((targetX - currentX) * mathMin(1, dt * 18))
				end
			end
		end
		return
	end
	if settleIndex and settleX then
		local targetX = panel.x1 + panel.padding + ((settleIndex - 1) * (panel.iconSize + panel.gap))
		settleX = settleX + ((targetX - settleX) * mathMin(1, dt * 22))
		if mathAbs(targetX - settleX) < 0.35 then
			settleIndex = nil
			settleX = nil
			settleGhost = nil
		end
	end
	for index, currentX in pairs(settlePositions) do
		local targetX = panel.x1 + panel.padding + ((index - 1) * (panel.iconSize + panel.gap))
		local nextX = currentX + ((targetX - currentX) * mathMin(1, dt * 22))
		if mathAbs(targetX - nextX) < 0.35 then
			settlePositions[index] = nil
		else
			settlePositions[index] = nextX
		end
	end
	if reorderCooldown > 0 then
		reorderCooldown = reorderCooldown - dt
		return
	end

	pollTime = pollTime + dt
	if queueDirty or pollTime >= POLL_INTERVAL then
		pollTime = 0
		refreshQueue()
	end
end

function widget:RecvLuaMsg(msg)
	if msg:sub(1, 18) == "LobbyOverlayActive" then
		chobbyInterface = msg:sub(1, 19) == "LobbyOverlayActive1"
	end
end

function widget:DrawScreen()
	panelVisible = false
	overflowRect = nil
	clearQueueRects()
	if chobbyInterface or Spring.IsGUIHidden() then
		return
	end
	if not selectedFactoryID or #queue == 0 then
		return
	end
	if WG["buildmenu"] and WG["buildmenu"].getIsShowing and not WG["buildmenu"].getIsShowing() then
		queueExpanded = false
		return
	end
	if not updatePanel() then
		return
	end
	panelVisible = true

	local iconSize = panel.iconSize
	local gap = panel.gap
	local x = panel.x1 + panel.padding
	local right = (queueExpanded and vsx or panel.x2) - panel.padding
	panel.hitX2 = queueExpanded and vsx or panel.x2
	local availableWidth = right - x
	local y1 = panel.y1 + mathFloor(((panel.y2 - panel.y1) - iconSize) * 0.5)
	local y2 = y1 + iconSize
	local maxIcons = mathMax(
		1,
		mathFloor((availableWidth + QUEUE_FIT_ALLOWANCE + gap) / (iconSize + gap))
	)
	local visibleIcons = queueExpanded and #queue or mathMin(#queue, maxIcons)
	local overflow = 0
	local overflowWidth = iconSize
	local showOverflow = not queueExpanded and #queue > visibleIcons
	if showOverflow then
		visibleIcons = mathMax(
			0,
			mathMin(
				#queue - 1,
				mathFloor(
					(availableWidth + QUEUE_FIT_ALLOWANCE - overflowWidth) / (iconSize + gap)
				)
			)
		)
		overflow = 0
		for i = visibleIcons + 1, #queue do
			overflow = overflow + queue[i].count
		end
	end
	if showOverflow and visibleIcons == 0 then
		overflow = 0
		for i = 1, #queue do
			overflow = overflow + queue[i].count
		end
	end
	if queueExpanded then
		panel.hitX2 = mathMin(
			vsx,
			x + (visibleIcons * iconSize) + (mathMax(0, visibleIcons - 1) * gap)
		)
	end
	local currentBuildDefID, buildProgress = getCurrentBuildProgress()
	if font then
		font:Begin()
	end

	for i = 1, visibleIcons do
		local entry = queue[i]
		local unitDefID = entry.unitDefID
		local drawX = x
		if dragging and i ~= dragSource then
			drawX = visualPositions[i] or x
		elseif settleIndex == i and settleX and not settleGhost then
			drawX = settleX
		elseif settlePositions[i] then
			drawX = settlePositions[i]
		end
		local x2 = drawX + iconSize
		queueRects[i] = {
			x1 = x,
			y1 = y1,
			x2 = x + iconSize,
			y2 = y2,
		}

		if not (dragging and i == dragSource) then
			glColor(1, 1, 1, 1)
			if UiUnit then
				UiUnit(
					drawX,
					y1,
					x2,
					y2,
					mathMax(1, mathFloor(iconSize * 0.04)),
					1,
					1,
					1,
					1,
					0.0375,
					nil,
					nil,
					"#" .. unitDefID
				)
			else
				glColor(0.04, 0.04, 0.04, 0.95)
				glRect(drawX, y1, x2, y2)
				glColor(1, 1, 1, 1)
				glTexture("#" .. unitDefID)
				glTexRect(drawX + 1, y1 + 1, x2 - 1, y2 - 1)
				glTexture(false)
			end
		end

		if not (dragging and i == dragSource)
			and i == 1
			and currentBuildDefID == unitDefID
			and buildProgress
			and RectRoundProgress
		then
			RectRoundProgress(
				drawX,
				y1,
				x2,
				y2,
				iconSize * 0.03,
				1 - buildProgress,
				{ 0.08, 0.08, 0.08, 0.6 }
			)
		end

		if font and not (dragging and i == dragSource) then
			local countText = tostring(entry.count)
			local countFontSize = mathMax(10, mathFloor(iconSize * 0.34))
			local textPad = mathMax(2, mathFloor(iconSize * 0.08))
			local badgeHeight = mathFloor(iconSize * 0.38)
			local textWidth = font:GetTextWidth(countText) * countFontSize
			local textHeight = font:GetTextHeight(countText) * countFontSize
			local badgeWidth = mathMax(badgeHeight, mathFloor(textWidth) + (textPad * 2))
			glColor(0.1, 0.1, 0.1, 0.92)
			glRect(drawX, y2 - badgeHeight, drawX + badgeWidth, y2)
			glColor(1, 1, 1, 1)
			font:Print(
				"\255\190\255\190" .. countText,
				drawX + (badgeWidth * 0.5),
				y2 - (badgeHeight * 0.5) - (textHeight * 0.22),
				countFontSize,
				"co"
			)
		end

		x = x + iconSize + gap
	end

	if settleGhost and settleX then
		local drawX = settleX
		local drawX2 = drawX + iconSize
		glColor(1, 1, 1, 0.94)
		if UiUnit then
			UiUnit(
				drawX,
				y1,
				drawX2,
				y2,
				mathMax(1, mathFloor(iconSize * 0.04)),
				1,
				1,
				1,
				1,
				0.0375,
				nil,
				nil,
				"#" .. settleGhost.unitDefID
			)
		else
			glColor(0.04, 0.04, 0.04, 0.95)
			glRect(drawX, y1, drawX2, y2)
			glColor(1, 1, 1, 1)
			glTexture("#" .. settleGhost.unitDefID)
			glTexRect(drawX + 1, y1 + 1, drawX2 - 1, y2 - 1)
			glTexture(false)
		end
		if font then
			local countText = tostring(settleGhost.count)
			local countFontSize = mathMax(10, mathFloor(iconSize * 0.34))
			local textPad = mathMax(2, mathFloor(iconSize * 0.08))
			local badgeHeight = mathFloor(iconSize * 0.38)
			local textWidth = font:GetTextWidth(countText) * countFontSize
			local textHeight = font:GetTextHeight(countText) * countFontSize
			local badgeWidth = mathMax(badgeHeight, mathFloor(textWidth) + (textPad * 2))
			glColor(0.1, 0.1, 0.1, 0.92)
			glRect(drawX, y2 - badgeHeight, drawX + badgeWidth, y2)
			glColor(1, 1, 1, 1)
			font:Print(
				"\255\190\255\190" .. countText,
				drawX + (badgeWidth * 0.5),
				y2 - (badgeHeight * 0.5) - (textHeight * 0.22),
				countFontSize,
				"co"
			)
		end
	end

	if dragging and dragSource and queue[dragSource] then
		local entry = queue[dragSource]
		local drawX = (dragX or dragStartX) - (iconSize * 0.5)
		local drawY = y1
		local drawX2 = drawX + iconSize
		local drawY2 = drawY + iconSize
		glColor(1, 1, 1, 0.94)
		if UiUnit then
			UiUnit(
				drawX,
				drawY,
				drawX2,
				drawY2,
				mathMax(1, mathFloor(iconSize * 0.04)),
				1,
				1,
				1,
				1,
				0.0375,
				nil,
				nil,
				"#" .. entry.unitDefID
			)
		else
			glColor(0.04, 0.04, 0.04, 0.95)
			glRect(drawX, drawY, drawX2, drawY2)
			glColor(1, 1, 1, 1)
			glTexture("#" .. entry.unitDefID)
			glTexRect(drawX + 1, drawY + 1, drawX2 - 1, drawY2 - 1)
			glTexture(false)
		end
		if font then
			local countText = tostring(entry.count)
			local countFontSize = mathMax(10, mathFloor(iconSize * 0.34))
			local textPad = mathMax(2, mathFloor(iconSize * 0.08))
			local badgeHeight = mathFloor(iconSize * 0.38)
			local textWidth = font:GetTextWidth(countText) * countFontSize
			local textHeight = font:GetTextHeight(countText) * countFontSize
			local badgeWidth = mathMax(badgeHeight, mathFloor(textWidth) + (textPad * 2))
			glColor(0.1, 0.1, 0.1, 0.92)
			glRect(drawX, drawY2 - badgeHeight, drawX + badgeWidth, drawY2)
			glColor(1, 1, 1, 1)
			font:Print(
				"\255\190\255\190" .. countText,
				drawX + (badgeWidth * 0.5),
				drawY2 - (badgeHeight * 0.5) - (textHeight * 0.22),
				countFontSize,
				"co"
			)
		end
	end

	if showOverflow and font then
		local overflowText = "+" .. overflow
		local x2 = mathMin(x + overflowWidth, right)
		overflowRect = {
			x1 = x,
			y1 = y1,
			x2 = x2,
			y2 = y2,
		}
		local overflowFontSize = mathFloor(iconSize * 0.34)
		local overflowTextHeight = font:GetTextHeight(overflowText) * overflowFontSize
		glColor(0.08, 0.08, 0.08, 0.95)
		glRect(x, y1, x2, y2)
		glColor(1, 1, 1, 1)
		font:Print(
			overflowText,
			x + ((x2 - x) * 0.5),
			y1 + ((y2 - y1) * 0.5) - (overflowTextHeight * 0.22),
			overflowFontSize,
			"co"
		)
	end

	if font then
		font:End()
	end

	glTexture(false)
	glColor(1, 1, 1, 1)
end

function widget:IsAbove(x, y)
	return panelVisible
		and x >= panel.x1
		and x <= panel.hitX2
		and y >= panel.y1
		and y <= panel.y2
end

function widget:MousePress(x, y, button)
	if widget:IsAbove(x, y) then
		if overflowRect
			and x >= overflowRect.x1
			and x <= overflowRect.x2
			and y >= overflowRect.y1
			and y <= overflowRect.y2
		then
			if button == 1 then
				clearSettle()
				queueExpanded = true
				overflowRect = nil
			end
			return true
		end

		local sourceIndex = getQueueRectAt(x, y)
		if sourceIndex and widget.canControlUnits then
			if button == 1 then
				clearSettle()
				dragSource = sourceIndex
				dragTarget = sourceIndex
				dragStartX = x
				dragStartY = y
				dragX = x
				dragging = false
				for i = 1, #queueRects do
					visualPositions[i] = queueRects[i].x1
				end
			elseif button == 3 then
				handleQueueClick(sourceIndex, button)
			end
		end
		return true
	end
end

function widget:MouseMove(x, y, dx, dy, button)
	if not dragSource then
		return
	end

	if not dragging then
		local movedX = x - dragStartX
		if mathAbs(movedX) < DRAG_THRESHOLD then
			return
		end
		dragging = true
	end

	dragX = x
	dragTarget = getDropTarget(x)
	dragTarget = dragTarget or 1
end

function widget:MouseRelease(x, y, button)
	if button ~= 1 or not dragSource then
		return
	end

	local sourceIndex = dragSource
	local targetIndex = dragTarget
	local wasDragging = dragging
	local draggedEntry = queue[sourceIndex]
	local draggedUnitDefID = draggedEntry and draggedEntry.unitDefID
	local draggedCount = draggedEntry and draggedEntry.count
	local droppedX = (dragX or dragStartX) - (panel.iconSize * 0.5)
	clearDrag()

	if wasDragging and targetIndex then
		local reordered, finalIndex, merged = reorderQueue(sourceIndex, targetIndex)
		if reordered and finalIndex then
			settleIndex = finalIndex
			settleX = droppedX
			settleGhost = merged and {
				unitDefID = draggedUnitDefID,
				count = draggedCount,
			} or nil
			if merged then
				local step = panel.iconSize + panel.gap
				for i = finalIndex + 1, #queue do
					local targetX = panel.x1 + panel.padding + ((i - 1) * step)
					settlePositions[i] = targetX + step
				end
			end
		else
			settleIndex = sourceIndex
			settleX = droppedX
		end
	else
		clearSettle()
		handleQueueClick(sourceIndex, button)
	end
	return true
end
