local widgetName = "Build Placement Cost"
function widget:GetInfo()
	return {
		name    = widgetName,
		desc    = "Shows effective build cost rate near cursor",
		author  = "lov",
		date    = "2026",
		license = "GPLv2",
		layer   = 1000,
		enabled = true,
	}
end

--------------------------------------------------------------------------------
-- Config
--------------------------------------------------------------------------------

local TEXT_OFFSET_X        = 22
local TEXT_OFFSET_Y        = -18
local RANGE_PAD            = 8

local LINE_WIDTH_WORLD     = 3.0  -- ribbon half-width is handled in shader
local LINE_HEIGHT_OFFSET   = 3.0  -- line hovers above terrain
local FILL_SPEED           = 0.02 -- cycles per second
local FILL_HEAD_SIZE       = 0.92 -- size of bright fill head in normalized 0..1 line space
local BASE_ALPHA           = 0.60
local FILL_ALPHA           = 0.95

local LINE_SEGMENTS        = 8;

--------------------------------------------------------------------------------
-- Spring aliases
--------------------------------------------------------------------------------

local spGetActiveCommand   = Spring.GetActiveCommand
local spGetMouseState      = Spring.GetMouseState
local spTraceScreenRay     = Spring.TraceScreenRay
local spPos2BuildPos       = Spring.Pos2BuildPos
local spGetTeamUnits       = Spring.GetTeamUnits
local spGetMyTeamID        = Spring.GetMyTeamID
local spGetUnitDefID       = Spring.GetUnitDefID
local spGetUnitPosition    = Spring.GetUnitPosition
local spGetUnitIsDead      = Spring.GetUnitIsDead
local spGetSpectatingState = Spring.GetSpectatingState
local spIsGUIHidden        = Spring.IsGUIHidden
local spGetBuildFacing     = Spring.GetBuildFacing
local spGetGameFrame       = Spring.GetGameFrame
local spGetSelectedUnits   = Spring.GetSelectedUnits

--------------------------------------------------------------------------------
-- GL / GL4 helpers
--------------------------------------------------------------------------------

local LuaShader            = gl.LuaShader
local InstanceVBOTable     = gl.InstanceVBOTable

local pushElementInstance  = InstanceVBOTable.pushElementInstance
local clearInstanceTable   = InstanceVBOTable.clearInstanceTable
local uploadAllElements    = InstanceVBOTable.uploadAllElements
local drawInstanceVBO      = InstanceVBOTable.drawInstanceVBO

local shaderSourceCache    = nil

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local myTeamID             = Spring.GetMyTeamID()
local constructorCache     = {}
local cacheFrame           = -1

local linkShader           = nil
local linkVertexVBO        = nil
local linkInstanceVBO      = nil
local linkNumVertices      = 0


local vsSrc = [[
#version 420

uniform sampler2D heightMap;

uniform float lineWidth;
uniform float lineHeight;
uniform float fillSpeed;

layout (location = 0) in vec3 localparam;          // x = along [0..1], y = side [-1..1], z unused
layout (location = 1) in vec4 instanceStartPhase;  // xyz = start, w = phase
layout (location = 2) in vec4 instanceEndWidth;    // xyz = end,   w = widthScale
layout (location = 3) in vec4 instanceBaseColor;   // rgba
layout (location = 4) in vec4 instanceFillColor;   // rgba
layout (location = 5) in vec4 instanceMisc;        // unused for line-only path

out DataVS {
	vec4 baseColor;
	vec4 fillColor;
	float tAlong;
	float fillPos;
	float sideCoord;
} vout;

//__ENGINEUNIFORMBUFFERDEFS__
#line 10000

float heightAtWorldPos(vec2 worldXZ)
{
	vec2 uvhm = vec2(
		clamp(worldXZ.x, 8.0, mapSize.x - 8.0),
		clamp(worldXZ.y, 8.0, mapSize.y - 8.0)
	) / mapSize.xy;

	return textureLod(heightMap, uvhm, 0.0).x;
}

vec3 makeLineVertex(float along, float side)
{
	vec3 startPos = instanceStartPhase.xyz;
	vec3 endPos   = instanceEndWidth.xyz;

	vec2 startXZ = startPos.xz;
	vec2 endXZ   = endPos.xz;

	vec2 dirXZ = endXZ - startXZ;
	float len = length(dirXZ);
	if (len < 0.001) {
		dirXZ = vec2(1.0, 0.0);
		len = 1.0;
	}
	dirXZ /= len;

	vec2 normalXZ = vec2(-dirXZ.y, dirXZ.x);
	float width = lineWidth * instanceEndWidth.w;

	vec2 xz = mix(startXZ, endXZ, along) + normalXZ * side * width;

	float terrainY = heightAtWorldPos(xz);
	float endpointLiftY = mix(startPos.y, endPos.y, along);
	float y = max(terrainY + lineHeight, endpointLiftY);

	return vec3(xz.x, y, xz.y);
}

void main()
{
	vec3 worldPos = makeLineVertex(localparam.x, localparam.y);

	gl_Position = cameraViewProj * vec4(worldPos, 1.0);

	vout.baseColor = instanceBaseColor;
	vout.fillColor = instanceFillColor;
	vout.tAlong = localparam.x;
	vout.fillPos = fract(timeInfo.x * fillSpeed + instanceStartPhase.w);
	vout.sideCoord = localparam.y;
}
]]

local fsSrc = [[
#version 420

in DataVS {
	vec4 baseColor;
	vec4 fillColor;
	float tAlong;
	float fillPos;
	float sideCoord;
} fin;

out vec4 fragColor;

void main()
{
	vec4 color = fin.baseColor;

	float wave = sin((fin.tAlong - fin.fillPos) * 6.28318530718);
	float waveMask = 0.5 + 0.5 * wave;

	color.rgb = mix(fin.baseColor.rgb, fin.fillColor.rgb, waveMask);
	color.a   = mix(fin.baseColor.a,   fin.fillColor.a, waveMask);

	// Fade toward the ribbon edges: sideCoord is interpolated from -1 to +1
	float edge = 1.0 - abs(fin.sideCoord);
	edge = smoothstep(0.0, 1.0, edge);

	color.a *= edge;

	if (color.a <= 0.01) {
		discard;
	}

	fragColor = color;
}
]]

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function IsBuildCommand(cmdID)
	return cmdID and cmdID < 0
end

local function GetBuildDefIDFromCmdID(cmdID)
	if not IsBuildCommand(cmdID) then
		return nil
	end
	return -cmdID
end

local function IsConstructorUnitDef(unitDef)
	if not unitDef then
		return false
	end
	return unitDef.isBuilder and (not unitDef.isFactory) and unitDef.buildSpeed and unitDef.buildSpeed > 0
end

local function GetBuildRange(unitDef)
	if not unitDef then
		return 0
	end
	return (unitDef.buildDistance or 0)
end

local function GetFootprintWorldRadius(buildDef, facing)
	if not buildDef then
		return 0
	end

	local xsize = buildDef.xsize or 0
	local zsize = buildDef.zsize or 0

	if facing == 1 or facing == 3 then
		xsize, zsize = zsize, xsize
	end

	local halfX = xsize * 4
	local halfZ = zsize * 4
	return math.sqrt(halfX * halfX + halfZ * halfZ)
end

local function DistSq(x1, z1, x2, z2)
	local dx = x1 - x2
	local dz = z1 - z2
	return dx * dx + dz * dz
end

local function GetSelectedConstructorSet()
	local selected = spGetSelectedUnits() or {}
	local selectedSet = {}

	for i = 1, #selected do
		local unitID = selected[i]
		if not spGetUnitIsDead(unitID) then
			local unitDefID = spGetUnitDefID(unitID)
			local unitDef = unitDefID and UnitDefs[unitDefID]
			if IsConstructorUnitDef(unitDef) then
				selectedSet[unitID] = true
			end
		end
	end

	return selectedSet
end

local function GetConstructorUnits()
	local frame = spGetGameFrame()
	if frame == cacheFrame then
		return constructorCache
	end

	cacheFrame = frame
	constructorCache = {}

	local units = spGetTeamUnits(myTeamID) or {}
	for i = 1, #units do
		local unitID = units[i]
		if not spGetUnitIsDead(unitID) then
			local unitDefID = spGetUnitDefID(unitID)
			local unitDef = unitDefID and UnitDefs[unitDefID]
			if IsConstructorUnitDef(unitDef) then
				constructorCache[#constructorCache + 1] = unitID
			end
		end
	end

	return constructorCache
end

local function GetBuildPlacement()
	local mx, my = spGetMouseState()
	local _, cmdID = spGetActiveCommand()
	local buildDefID = GetBuildDefIDFromCmdID(cmdID)
	if not buildDefID then
		return nil
	end

	local buildDef = UnitDefs[buildDefID]
	if not buildDef then
		return nil
	end

	local typ, p = spTraceScreenRay(mx, my, true, true)
	if typ ~= "ground" or not p then
		return nil
	end

	local facing = spGetBuildFacing()
	local bx, by, bz = spPos2BuildPos(buildDefID, p[1], p[2], p[3], facing)
	if not bx then
		return nil
	end

	return {
		defID = buildDefID,
		def = buildDef,
		x = bx,
		y = by,
		z = bz,
		facing = facing,
		mouseX = mx,
		mouseY = my,
	}
end

local function GetBuildEconomy(def)
	local metal = def.metalCost or 0
	local energy = def.energyCost or 0
	local buildTime = def.buildTime or 1
	if buildTime <= 0 then
		buildTime = 1
	end
	return metal, energy, buildTime
end

local function GetContributors(buildPlacement)
	local contributors = {}
	local totalBuildSpeed = 0

	local footprintRadius = GetFootprintWorldRadius(buildPlacement.def, buildPlacement.facing)
	local constructors = GetConstructorUnits()
	local selectedConstructorSet = GetSelectedConstructorSet()

	for i = 1, #constructors do
		local unitID = constructors[i]
		local ux, uy, uz = spGetUnitPosition(unitID)
		if ux and uz then
			local unitDefID = spGetUnitDefID(unitID)
			local unitDef = unitDefID and UnitDefs[unitDefID]
			if unitDef then
				local buildRange = GetBuildRange(unitDef)
				local effectiveRange = buildRange + footprintRadius + RANGE_PAD
				local inRange = DistSq(ux, uz, buildPlacement.x, buildPlacement.z) <= effectiveRange * effectiveRange
				local isSelected = selectedConstructorSet[unitID] == true

				if inRange or isSelected then
					local buildSpeed = unitDef.buildSpeed or 0
					if buildSpeed > 0 then
						totalBuildSpeed = totalBuildSpeed + buildSpeed
						contributors[#contributors + 1] = {
							unitID = unitID,
							x = ux,
							y = uy,
							z = uz,
							buildSpeed = buildSpeed,
							range = buildRange,
							inRange = inRange,
							selected = isSelected,
						}
					end
				end
			end
		end
	end

	return contributors, totalBuildSpeed, footprintRadius
end

local function FormatRate(metal, energy, buildTime, totalBuildSpeed)
	if totalBuildSpeed <= 0 then
		return 0, 0
	end

	local mps = metal * totalBuildSpeed / buildTime
	local eps = energy * totalBuildSpeed / buildTime
	return mps, eps
end

local function FormatETA(buildTime, totalBuildSpeed)
	if totalBuildSpeed <= 0 then
		return "—"
	end

	local eta = buildTime / totalBuildSpeed
	if eta < 0 then
		eta = 0
	end

	local minutes = math.floor(eta / 60)
	local seconds = math.floor(eta % 60)
	local tenths = math.floor((eta - math.floor(eta)) * 10)

	if minutes > 0 then
		return string.format("%d:%02d", minutes, seconds)
	end

	return string.format("%d.%ds", seconds, tenths)
end

--------------------------------------------------------------------------------
-- GL4 setup
--------------------------------------------------------------------------------
local function MakeRibbonVertexVBO()
	local vbo = gl.GetVBO(GL.ARRAY_BUFFER, false)
	if not vbo then
		return nil, 0
	end

	-- localparam.x = along [0..1]
	-- localparam.y = side  [-1..1]
	-- localparam.z = partType (0=line)
	local layout = {
		{ id = 0, name = "localparam", size = 3 },
	}

	-- More segments = better terrain conformity
	local lineSegments = LINE_SEGMENTS

	local data = {}
	local n = 1

	for seg = 0, lineSegments - 1 do
		local a0 = seg / lineSegments
		local a1 = (seg + 1) / lineSegments

		-- tri 1
		data[n] = a0; n = n + 1
		data[n] = -1; n = n + 1
		data[n] = 0; n = n + 1

		data[n] = a1; n = n + 1
		data[n] = -1; n = n + 1
		data[n] = 0; n = n + 1

		data[n] = a1; n = n + 1
		data[n] = 1; n = n + 1
		data[n] = 0; n = n + 1

		-- tri 2
		data[n] = a0; n = n + 1
		data[n] = -1; n = n + 1
		data[n] = 0; n = n + 1

		data[n] = a1; n = n + 1
		data[n] = 1; n = n + 1
		data[n] = 0; n = n + 1

		data[n] = a0; n = n + 1
		data[n] = 1; n = n + 1
		data[n] = 0; n = n + 1
	end

	local verts = #data / 3
	vbo:Define(verts, layout)
	vbo:Upload(data)
	return vbo, verts
end

local function MakeLinkShader()
	shaderSourceCache = {
		vsSrc = vsSrc,
		fsSrc = fsSrc,
		shaderName = "ConstructorLinksShader",
		uniformInt = {
			heightMap = 0,
		},
		uniformFloat = {
			lineWidth    = LINE_WIDTH_WORLD,
			lineHeight   = LINE_HEIGHT_OFFSET,
			fillSpeed    = FILL_SPEED,
			fillHeadSize = FILL_HEAD_SIZE,
			baseAlpha    = BASE_ALPHA,
			fillAlpha    = FILL_ALPHA,
		},
		shaderConfig = {},
		forceupdate = true
	}

	local shader = LuaShader.CheckShaderUpdates(shaderSourceCache)
	if not shader then
		Spring.Echo("[" .. widgetName .. "] Failed to compile GL4 shader")
		return nil
	end

	return shader
end
local function InitGL4()
	if not gl.CreateShader then
		Spring.Echo("[" .. widgetName .. "] No shader support")
		return false
	end

	linkShader = MakeLinkShader()
	if not linkShader then
		return false
	end

	linkVertexVBO, linkNumVertices = MakeRibbonVertexVBO()
	if not linkVertexVBO then
		return false
	end

	local instanceLayout = {
		-- xyz start, w phase
		{ id = 1, name = "instanceStartPhase", size = 4 },
		-- xyz end, w widthScale
		{ id = 2, name = "instanceEndWidth",   size = 4 },
		-- rgba base
		{ id = 3, name = "instanceBaseColor",  size = 4 },
		-- rgba fill
		{ id = 4, name = "instanceFillColor",  size = 4 },
		-- x radius, y unused, z unused, w mode
		{ id = 5, name = "instanceMisc",       size = 4 },
	}

	linkInstanceVBO = InstanceVBOTable.makeInstanceVBOTable(instanceLayout, 128, "buildLinkInstanceVBO")
	linkInstanceVBO.vertexVBO = linkVertexVBO
	linkInstanceVBO.numVertices = linkNumVertices
	linkInstanceVBO.primitiveType = GL.TRIANGLES
	linkInstanceVBO.VAO = InstanceVBOTable.makeVAOandAttach(linkVertexVBO, linkInstanceVBO.instanceVBO)


	return true
end

--------------------------------------------------------------------------------
-- Widget lifecycle
--------------------------------------------------------------------------------

function widget:Initialize()
	myTeamID = spGetMyTeamID()

	if not InitGL4() then
		widgetHandler:RemoveWidget()
		return
	end
end

function widget:Shutdown()
	if linkShader then
		linkShader:Finalize()
		linkShader = nil
	end
end

function widget:PlayerChanged(playerID)
	myTeamID = spGetMyTeamID()
end

--------------------------------------------------------------------------------
-- GL4 instance building
--------------------------------------------------------------------------------

local function RebuildWorldInstances(placement, contributors, footprintRadius)
	if not linkInstanceVBO then
		return
	end

	clearInstanceTable(linkInstanceVBO)

	local buildX, buildY, buildZ = placement.x, placement.y, placement.z

	for i = 1, #contributors do
		local c = contributors[i]
		local phase = (c.unitID % 97) / 97

		pushElementInstance(
			linkInstanceVBO,
			{
				c.x, c.y, c.z, phase, -- start.xyz at unit feet
				buildX, buildY, buildZ, 1.0, -- end.xyz at building base
				0.15, 0.95, 1.0, BASE_ALPHA,
				1.00, 1.00, 1.00, FILL_ALPHA,
				0.0, 0.0, 0.0, 0.0,
			},
			c.unitID,
			false,
			true
		)
	end

	uploadAllElements(linkInstanceVBO)
end

--------------------------------------------------------------------------------
-- Draw world overlays
--------------------------------------------------------------------------------

function widget:DrawWorld()
	if spIsGUIHidden() then
		return
	end

	local spectating = spGetSpectatingState()
	if spectating then
		return
	end

	local placement = GetBuildPlacement()
	if not placement then
		return
	end

	local contributors, totalBuildSpeed, footprintRadius = GetContributors(placement)
	if #contributors == 0 then
		return
	end

	RebuildWorldInstances(placement, contributors, footprintRadius)

	gl.DepthTest(GL.LEQUAL)
	gl.DepthMask(false)
	gl.Blending(GL.SRC_ALPHA, GL.ONE_MINUS_SRC_ALPHA)
	gl.Texture(0, "$heightmap")

	linkShader:Activate()

	drawInstanceVBO(linkInstanceVBO)

	linkShader:Deactivate()

	gl.Texture(0, false)
	gl.DepthMask(true)
	gl.DepthTest(false)
end

--------------------------------------------------------------------------------
-- Draw screen text
--------------------------------------------------------------------------------
local TEXT_BOX_CORNER_RADIUS = 7
local TEXT_BOX_CORNER_DIVS   = 10
local function DrawRoundedRect(x1, y1, x2, y2, r, divs)
	r = math.max(0, math.min(r, math.min((x2 - x1) * 0.5, (y2 - y1) * 0.5)))

	if r <= 0 then
		gl.Rect(x1, y1, x2, y2)
		return
	end

	gl.BeginEnd(GL.POLYGON, function()
		-- top-left arc
		for i = 0, divs do
			local a = math.pi - (math.pi * 0.5) * (i / divs)
			gl.Vertex(x1 + r + math.cos(a) * r, y2 - r + math.sin(a) * r)
		end

		-- top-right arc
		for i = 0, divs do
			local a = (math.pi * 0.5) - (math.pi * 0.5) * (i / divs)
			gl.Vertex(x2 - r + math.cos(a) * r, y2 - r + math.sin(a) * r)
		end

		-- bottom-right arc
		for i = 0, divs do
			local a = 0.0 - (math.pi * 0.5) * (i / divs)
			gl.Vertex(x2 - r + math.cos(a) * r, y1 + r + math.sin(a) * r)
		end

		-- bottom-left arc
		for i = 0, divs do
			local a = -math.pi * 0.5 - (math.pi * 0.5) * (i / divs)
			gl.Vertex(x1 + r + math.cos(a) * r, y1 + r + math.sin(a) * r)
		end
	end)
end
local TEXT_BOX_BORDER_WIDTH = 1.3
local TEXT_BOX_BORDER_COLOR = { .7, .7, .7, 0.9 }
local function DrawRoundedRectOutline(x1, y1, x2, y2, r, divs)
	r = math.max(0, math.min(r, math.min((x2 - x1) * 0.5, (y2 - y1) * 0.5)))

	if r <= 0 then
		gl.BeginEnd(GL.LINE_LOOP, function()
			gl.Vertex(x1, y1)
			gl.Vertex(x2, y1)
			gl.Vertex(x2, y2)
			gl.Vertex(x1, y2)
		end)
		return
	end

	gl.BeginEnd(GL.LINE_LOOP, function()
		-- top-left arc
		for i = 0, divs do
			local a = math.pi - (math.pi * 0.5) * (i / divs)
			gl.Vertex(x1 + r + math.cos(a) * r, y2 - r + math.sin(a) * r)
		end

		-- top-right arc
		for i = 0, divs do
			local a = (math.pi * 0.5) - (math.pi * 0.5) * (i / divs)
			gl.Vertex(x2 - r + math.cos(a) * r, y2 - r + math.sin(a) * r)
		end

		-- bottom-right arc
		for i = 0, divs do
			local a = 0.0 - (math.pi * 0.5) * (i / divs)
			gl.Vertex(x2 - r + math.cos(a) * r, y1 + r + math.sin(a) * r)
		end

		-- bottom-left arc
		for i = 0, divs do
			local a = -math.pi * 0.5 - (math.pi * 0.5) * (i / divs)
			gl.Vertex(x1 + r + math.cos(a) * r, y1 + r + math.sin(a) * r)
		end
	end)
end

local TEXT_BOX_PAD_X      = 10
local TEXT_BOX_PAD_Y      = 8
local TEXT_LINE_SPACING   = 16
local TEXT_TITLE_SIZE     = 16
local TEXT_BODY_SIZE      = 14
local TEXT_FOOTER_SIZE    = 12
local TEXT_BASELINE_SHIFT = 3
function widget:DrawScreen()
	if spIsGUIHidden() then
		return
	end

	local spectating = spGetSpectatingState()
	if spectating then
		return
	end

	local placement = GetBuildPlacement()
	if not placement then
		return
	end

	local metal, energy, buildTime = GetBuildEconomy(placement.def)
	local contributors, totalBuildSpeed = GetContributors(placement)
	local mps, eps = FormatRate(metal, energy, buildTime, totalBuildSpeed)
	local etaText = FormatETA(buildTime, totalBuildSpeed)

	local anchorX = placement.mouseX + TEXT_OFFSET_X
	local anchorY = placement.mouseY + TEXT_OFFSET_Y
	local count = #contributors

	local metalColor = "\255\245\245\245"
	local energyColor = "\255\255\255\000"
	local greenColor = "\255\112\224\112"

	local lines = {
		string.format("\255\255\217\51Build: %s", placement.def.humanName or placement.def.name or "Unknown"),
		string.format(greenColor .. "Maximum Drain: " .. metalColor .. "%.1f m/s " .. energyColor .. " %.1f e/s", mps,
			eps),
		string.format(greenColor .. "Constructors: " .. metalColor .. "%d", count),
		string.format(greenColor .. "Total BP: " .. metalColor .. "%.0f", totalBuildSpeed),
		string.format("ETA: %s", etaText),
	}

	local lineSizes = {
		TEXT_TITLE_SIZE,
		TEXT_BODY_SIZE,
		TEXT_BODY_SIZE,
		TEXT_BODY_SIZE,
		TEXT_BODY_SIZE,
	}

	local maxWidth = 0
	for i = 1, #lines do
		local w = gl.GetTextWidth(lines[i]) * lineSizes[i]
		if w > maxWidth then
			maxWidth = w
		end
	end

	local numLines = #lines
	local rowHeight = TEXT_LINE_SPACING
	local boxW = maxWidth + (TEXT_BOX_PAD_X * 2)
	local boxH = (numLines * rowHeight) + (TEXT_BOX_PAD_Y * 2)

	local x1 = anchorX
	local y2 = anchorY
	local x2 = x1 + boxW
	local y1 = y2 - boxH

	local textX = x1 + TEXT_BOX_PAD_X
	local contentTop = y2 - TEXT_BOX_PAD_Y

	gl.Color(0, 0, 0, 0.75)
	DrawRoundedRect(x1, y1, x2, y2, TEXT_BOX_CORNER_RADIUS, TEXT_BOX_CORNER_DIVS)

	gl.LineWidth(TEXT_BOX_BORDER_WIDTH)
	gl.Color(
		TEXT_BOX_BORDER_COLOR[1],
		TEXT_BOX_BORDER_COLOR[2],
		TEXT_BOX_BORDER_COLOR[3],
		TEXT_BOX_BORDER_COLOR[4]
	)
	DrawRoundedRectOutline(x1, y1, x2, y2, TEXT_BOX_CORNER_RADIUS, TEXT_BOX_CORNER_DIVS)
	gl.LineWidth(1.0)

	for i = 1, numLines do
		local size = lineSizes[i]

		local rowCenterY = contentTop - ((i - 0.5) * rowHeight)
		local textY = rowCenterY - (size * 0.5) + TEXT_BASELINE_SHIFT

		if i == 1 then
			gl.Color(1, 0.85, 0.2, 1)
		elseif i == 2 then
			if count > 0 then
				gl.Color(0.3, 1, 0.3, 1)
			else
				gl.Color(1, 0.3, 0.3, 1)
			end
		elseif i == 5 then
			if totalBuildSpeed > 0 then
				gl.Color(0.6, 0.9, 1.0, 1)
			else
				gl.Color(1, 0.4, 0.4, 1)
			end
		else
			gl.Color(1, 1, 1, 1)
		end

		gl.Text(lines[i], textX, textY, size, "o")
	end
end
