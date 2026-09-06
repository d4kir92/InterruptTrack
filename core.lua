local _, InterruptTrack = ...
local UNITS = {"player", "party1", "party2", "party3", "party4"}
local UNITMAP = {}
for i, unit in ipairs(UNITS) do
	UNITMAP[unit] = i
end

local PETOWNER = {
	["pet"] = "player",
	["partypet1"] = "party1",
	["partypet2"] = "party2",
	["partypet3"] = "party3",
	["partypet4"] = "party4",
	["party1pet"] = "party1",
	["party2pet"] = "party2",
	["party3pet"] = "party3",
	["party4pet"] = "party4"
}

local INTERRUPTS = {
	["DEATHKNIGHT"] = {{47528, 15}},
	["DEMONHUNTER"] = {{183752, 15}},
	["DRUID"] = {{106839, 15}, {78675, 60, true}},
	["EVOKER"] = {{351338, 40}},
	["HUNTER"] = {{147362, 24}, {187707, 15, true}},
	["MAGE"] = {{2139, 24}},
	["MONK"] = {{116705, 15}},
	["PALADIN"] = {{96231, 15}, {31935, 15, true}},
	["PRIEST"] = {{15487, 45, true}},
	["ROGUE"] = {{1766, 15}},
	["SHAMAN"] = {{57994, 12}},
	["WARLOCK"] = {{19647, 24}},
	["WARRIOR"] = {{6552, 15}}
}

local SPELLCDS = {}
for class, list in pairs(INTERRUPTS) do
	for i, tab in ipairs(list) do
		SPELLCDS[tab[1]] = tab[2]
	end
end

local ROLEORDER = {["TANK"] = 1, ["HEALER"] = 2, ["DAMAGER"] = 3, ["NONE"] = 4}
local SORTERS = {}
SORTERS["ROLE"] = function(a, b)
	local ra = ROLEORDER[a.role] or 4
	local rb = ROLEORDER[b.role] or 4
	if ra ~= rb then return ra < rb end
	if a.name ~= b.name then return a.name < b.name end

	return a.spellID < b.spellID
end

SORTERS["COOLDOWN"] = function(a, b)
	if a.remaining ~= b.remaining then return a.remaining < b.remaining end
	if a.name ~= b.name then return a.name < b.name end

	return a.spellID < b.spellID
end

local MINRATIO = 0.6
local SUCCESSWINDOW = 0.5
local entries = {}
local bars = {}
local casted = {}
local learned = {}
local pending = {}
local elapsed = 0
local debug = false
local function GetDB()
	InterruptTrackG = InterruptTrackG or {}

	return InterruptTrackG
end

local function IsSecret(value)
	return issecretvalue ~= nil and issecretvalue(value) == true
end

local function Safe(value, fallback)
	if value == nil or IsSecret(value) then return fallback end

	return value
end

local function IsKnown(spellID)
	if C_SpellBook and C_SpellBook.IsSpellKnown then return C_SpellBook.IsSpellKnown(spellID) end
	if IsPlayerSpell then return IsPlayerSpell(spellID) end

	return false
end

local function HasKnownSpell(list)
	for i, tab in ipairs(list) do
		if Safe(IsKnown(tab[1]), false) == true then return true end
	end

	return false
end

local function GetKey(guid, spellID)
	return guid .. "-" .. spellID
end

local function DebugValue(value)
	if IsSecret(value) then return "<secret>" end

	return tostring(value)
end

function InterruptTrack:DEBUG(...)
	if debug == false then return end
	InterruptTrack:MSG(...)
end

function InterruptTrack:GetSortModes()
	return {
		{["value"] = "ROLE", ["label"] = "LID_SORTBYROLE"},
		{["value"] = "COOLDOWN", ["label"] = "LID_SORTBYCOOLDOWN"}
	}
end

function InterruptTrack:UpdateRoster()
	wipe(entries)
	for i, unit in ipairs(UNITS) do
		if Safe(UnitExists(unit), false) and Safe(UnitIsPlayer(unit), false) then
			local _, class = UnitClass(unit)
			class = Safe(class)
			local list = INTERRUPTS[class]
			local guid = Safe(UnitGUID(unit))
			if list and guid then
				local name = Safe(UnitName(unit), unit)
				local role = Safe(InterruptTrack:GetRole(unit), "NONE")
				local filter = unit == "player" and HasKnownSpell(list)
				for x, tab in ipairs(list) do
					local key = GetKey(guid, tab[1])
					local show = true
					if filter then
						show = Safe(IsKnown(tab[1]), false) == true
					elseif tab[3] == true then
						show = casted[key] ~= nil
					end

					if show then
						tinsert(
							entries,
							{
								["unit"] = unit,
								["guid"] = guid,
								["key"] = key,
								["name"] = name,
								["class"] = class,
								["role"] = role,
								["spellID"] = tab[1],
								["remaining"] = 0,
								["duration"] = 0
							}
						)
					end
				end
			end
		end
	end

	InterruptTrack:ApplyLayout()
	InterruptTrack:UpdateBars()
end

function InterruptTrack:OnCast(unit, spellID)
	if IsSecret(unit) or IsSecret(spellID) then return end
	local base = SPELLCDS[spellID]
	if base == nil then return end
	local owner = PETOWNER[unit] or unit
	if UNITMAP[owner] == nil then return end
	local guid = Safe(UnitGUID(owner))
	if guid == nil then return end
	local key = GetKey(guid, spellID)
	local now = GetTime()
	local isNew = casted[key] == nil
	if isNew == false then
		local measured = now - casted[key].start
		if measured >= base * MINRATIO and measured < (learned[key] or base) then learned[key] = measured end
	end

	casted[key] = {["start"] = now, ["duration"] = learned[key] or base}
	if pending.time ~= nil and now - pending.time <= SUCCESSWINDOW then
		casted[key].success = true
		casted[key].kicked = pending.kicked
		casted[key].hasKicked = pending.hasKicked
		pending.time = nil
		InterruptTrack:DEBUG("CAST matched pending interrupt", DebugValue(spellID))
	end

	InterruptTrack:DEBUG("CAST", DebugValue(unit), DebugValue(spellID), DebugValue(guid))
	if isNew then
		InterruptTrack:UpdateRoster()
	else
		InterruptTrack:UpdateBars()
	end
end

function InterruptTrack:OnInterrupted(unit, spellID)
	if IsSecret(unit) == false and (UNITMAP[unit] ~= nil or PETOWNER[unit] ~= nil) then return end
	local now = GetTime()
	local hasKicked = IsSecret(spellID) or spellID ~= nil
	local matched = false
	local duplicate = false
	for i, entry in ipairs(entries) do
		local cd = casted[entry.key]
		if cd ~= nil and now - cd.start <= SUCCESSWINDOW then
			if cd.success == true then
				duplicate = true
			else
				cd.success = true
				cd.kicked = spellID
				cd.hasKicked = hasKicked
				matched = true
			end
		end
	end

	if matched then
		InterruptTrack:DEBUG("INTERRUPTED matched a running cooldown")
		InterruptTrack:UpdateBars()

		return
	end

	if duplicate then
		InterruptTrack:DEBUG("INTERRUPTED ignored as duplicate")

		return
	end

	pending.time = now
	pending.kicked = spellID
	pending.hasKicked = hasKicked
	InterruptTrack:DEBUG("INTERRUPTED stored as pending")
end

local function GetRemaining(entry)
	local now = GetTime()
	local cd = casted[entry.key]
	if cd then
		local remaining = cd.start + cd.duration - now
		if remaining > 0 then return remaining, cd.duration end
	end

	return 0, 0
end

function InterruptTrack:CreateBar(index)
	local bar = CreateFrame("Frame", "ITBar" .. index, self.frame)
	bar.bg = bar:CreateTexture(nil, "BACKGROUND")
	bar.bg:SetAllPoints(bar)
	bar.bg:SetColorTexture(0, 0, 0, 0.5)
	bar.icon = bar:CreateTexture(nil, "ARTWORK")
	bar.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	bar.status = CreateFrame("StatusBar", "ITBar" .. index .. "Status", bar)
	bar.status:SetMinMaxValues(0, 1)
	bar.status:SetValue(1)
	bar.status:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
	bar.statusBg = bar.status:CreateTexture(nil, "BACKGROUND")
	bar.statusBg:SetAllPoints(bar.status)
	bar.statusBg:SetColorTexture(0.1, 0.1, 0.1, 0.7)
	bar.name = bar.status:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	bar.name:SetPoint("LEFT", bar.status, "LEFT", 4, 0)
	bar.name:SetJustifyH("LEFT")
	bar.time = bar.status:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	bar.time:SetPoint("RIGHT", bar.status, "RIGHT", -4, 0)
	bar.time:SetJustifyH("RIGHT")
	bars[index] = bar

	return bar
end

function InterruptTrack:ApplyLayout()
	if self.frame == nil then return end
	local db = GetDB()
	local width = InterruptTrack:GV(db, "BARWIDTH", 200)
	local height = InterruptTrack:GV(db, "BARHEIGHT", 24)
	local spacing = InterruptTrack:GV(db, "BARSPACING", 2)
	local fontSize = math.max(8, math.floor(height * 0.5))
	for i = 1, #entries do
		local bar = bars[i] or InterruptTrack:CreateBar(i)
		bar:SetSize(width, height)
		bar:ClearAllPoints()
		bar:SetPoint("TOPLEFT", self.frame, "TOPLEFT", 0, -((i - 1) * (height + spacing)))
		bar.icon:ClearAllPoints()
		bar.icon:SetPoint("TOPLEFT", bar, "TOPLEFT", 0, 0)
		bar.icon:SetSize(height, height)
		bar.status:ClearAllPoints()
		bar.status:SetPoint("TOPLEFT", bar, "TOPLEFT", height + 2, 0)
		bar.status:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", 0, 0)
		InterruptTrack:SetFontSize(bar.name, fontSize, "OUTLINE")
		InterruptTrack:SetFontSize(bar.time, fontSize, "OUTLINE")
		bar:Show()
	end

	for i = #entries + 1, #bars do
		bars[i]:Hide()
	end

	local count = math.max(1, #entries)
	self.frame:SetSize(width, count * (height + spacing) - spacing)
end

local function SetKickedIcon(bar, spellID)
	if C_Spell == nil or C_Spell.GetSpellTexture == nil then return false end
	local ok, err = pcall(function() bar.icon:SetTexture(C_Spell.GetSpellTexture(spellID)) end)
	if ok == false then InterruptTrack:DEBUG("KICKED ICON FAILED", tostring(err)) end

	return ok
end

function InterruptTrack:UpdateBars()
	if self.frame == nil then return end
	for i, entry in ipairs(entries) do
		entry.remaining, entry.duration = GetRemaining(entry)
	end

	local sorter = SORTERS[InterruptTrack:GV(GetDB(), "SORTBY", "ROLE")] or SORTERS["ROLE"]
	table.sort(entries, sorter)
	for i, entry in ipairs(entries) do
		local bar = bars[i]
		if bar then
			local cd = casted[entry.key]
			local running = entry.remaining > 0 and entry.duration > 0
			local wantKicked = running and cd ~= nil and cd.hasKicked == true
			if wantKicked and bar.showKicked ~= true then
				if SetKickedIcon(bar, cd.kicked) then
					bar.showKicked = true
					bar.iconID = nil
				else
					cd.hasKicked = false
					wantKicked = false
				end
			end

			if wantKicked == false and bar.iconID ~= entry.spellID then
				bar.showKicked = false
				bar.iconID = entry.spellID
				local _, _, icon = InterruptTrack:GetSpellInfo(entry.spellID)
				bar.icon:SetTexture(icon)
			end

			local r, g, b, colorStr = InterruptTrack:GetClassColor(entry.class)
			bar.name:SetText("|c" .. colorStr .. entry.name .. "|r")
			if running then
				bar.status:SetValue(entry.remaining / entry.duration)
				bar.status:SetStatusBarColor(r * 0.5, g * 0.5, b * 0.5)
				bar.time:SetText(format("%.1f", entry.remaining))
				if cd and cd.success then
					bar.time:SetTextColor(0.2, 1, 0.2)
				else
					bar.time:SetTextColor(1, 0.3, 0.3)
				end
			else
				bar.status:SetValue(1)
				bar.status:SetStatusBarColor(r, g, b)
				bar.time:SetText(InterruptTrack:Trans("LID_READY"))
				bar.time:SetTextColor(0.2, 1, 0.2)
			end
		end
	end
end

function InterruptTrack:SavePosition()
	local p1, _, p3, p4, p5 = self.frame:GetPoint()
	p4 = InterruptTrack:Grid(p4)
	p5 = InterruptTrack:Grid(p5)
	InterruptTrack:SV(GetDB(), "ITFrame", {p1, "UIParent", p3, p4, p5})
	self.frame:ClearAllPoints()
	self.frame:SetPoint(p1, "UIParent", p3, p4, p5)
end

function InterruptTrack:CreateMainFrame()
	if self.frame then return end
	self.frame = CreateFrame("Frame", "ITFrame", UIParent)
	self.frame:SetSize(200, 24)
	self.frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
	InterruptTrack:SetClampedToScreen(self.frame, true)
	self.frame:SetMovable(true)
	self.frame:EnableMouse(true)
	self.frame:RegisterForDrag("LeftButton")
	self.frame:SetScript(
		"OnDragStart",
		function(sel)
			if InCombatLockdown() then
				InterruptTrack:MSG(InterruptTrack:Trans("LID_CANTBEMOVEDINCOMBAT"))

				return
			end

			InterruptTrack:ShowGrid(sel)
			sel:StartMoving()
		end
	)

	self.frame:SetScript(
		"OnDragStop",
		function(sel)
			InterruptTrack:HideGrid(sel)
			sel:StopMovingOrSizing()
			InterruptTrack:SavePosition()
			InterruptTrack:MSG(InterruptTrack:Trans("LID_SAVEDNEWPOSITION"))
		end
	)

	local p1, p2, p3, p4, p5 = unpack(InterruptTrack:GV(GetDB(), "ITFrame", {}))
	if p1 then
		self.frame:ClearAllPoints()
		self.frame:SetPoint(p1, p2, p3, p4, p5)
	end

	self.frame:SetScript(
		"OnUpdate",
		function(sel, ela)
			elapsed = elapsed + ela
			if elapsed < 0.05 then return end
			elapsed = 0
			InterruptTrack:UpdateBars()
		end
	)

	InterruptTrack:UpdateRoster()
end

local eventFrame = CreateFrame("Frame")
InterruptTrack:RegisterEvent(eventFrame, "PLAYER_ENTERING_WORLD")
InterruptTrack:RegisterEvent(eventFrame, "GROUP_ROSTER_UPDATE")
InterruptTrack:RegisterEvent(eventFrame, "PLAYER_ROLES_ASSIGNED")
InterruptTrack:RegisterEvent(eventFrame, "PLAYER_SPECIALIZATION_CHANGED")
InterruptTrack:RegisterEvent(eventFrame, "UNIT_SPELLCAST_SUCCEEDED")
InterruptTrack:RegisterEvent(eventFrame, "UNIT_SPELLCAST_INTERRUPTED")
eventFrame:SetScript(
	"OnEvent",
	function(sel, event, ...)
		if event == "UNIT_SPELLCAST_SUCCEEDED" then
			local unit, _, spellID = ...
			InterruptTrack:OnCast(unit, spellID)
		elseif event == "UNIT_SPELLCAST_INTERRUPTED" then
			local unit, castGUID, spellID = ...
			InterruptTrack:DEBUG("EVENT INTERRUPTED", DebugValue(unit), DebugValue(castGUID), DebugValue(spellID))
			InterruptTrack:OnInterrupted(unit, spellID)
		else
			InterruptTrack:UpdateRoster()
		end
	end
)

function InterruptTrack:ToggleDebug()
	debug = not debug
	local valid = C_EventUtils ~= nil and C_EventUtils.IsEventValid("UNIT_SPELLCAST_INTERRUPTED")
	InterruptTrack:MSG("DEBUG", tostring(debug), "| EVENT VALID", tostring(valid), "| REGISTERED", tostring(eventFrame:IsEventRegistered("UNIT_SPELLCAST_INTERRUPTED")), "| MY GUID", DebugValue(UnitGUID("player")))
end
