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
	["DRUID"] = {{106839, 15}, {78675, 60}},
	["EVOKER"] = {{351338, 40}},
	["HUNTER"] = {{147362, 24}, {187707, 15}},
	["MAGE"] = {{2139, 24}},
	["MONK"] = {{116705, 15}},
	["PALADIN"] = {{96231, 15}},
	["PRIEST"] = {{15487, 45}},
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

	return a.name < b.name
end

SORTERS["COOLDOWN"] = function(a, b)
	if a.remaining ~= b.remaining then return a.remaining < b.remaining end

	return a.name < b.name
end

local entries = {}
local bars = {}
local casted = {}
local lastSpell = {}
local elapsed = 0
local function GetDB()
	InterruptTrackG = InterruptTrackG or {}

	return InterruptTrackG
end

local function IsKnown(spellID)
	if C_SpellBook and C_SpellBook.IsSpellKnown then return C_SpellBook.IsSpellKnown(spellID) end
	if IsPlayerSpell then return IsPlayerSpell(spellID) end

	return false
end

local function GetKnownSpell(list)
	for i, tab in ipairs(list) do
		if IsKnown(tab[1]) then return tab[1] end
	end

	return nil
end

local function GetSpellCooldownInfo(spellID)
	if C_Spell and C_Spell.GetSpellCooldown then
		local info = C_Spell.GetSpellCooldown(spellID)
		if info then return info.startTime, info.duration end

		return nil
	end

	if GetSpellCooldown then return GetSpellCooldown(spellID) end

	return nil
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
		if UnitExists(unit) and UnitIsPlayer(unit) then
			local _, class = UnitClass(unit)
			local list = INTERRUPTS[class]
			local guid = UnitGUID(unit)
			if list and guid then
				local spellID = nil
				if unit == "player" then spellID = GetKnownSpell(list) end
				spellID = spellID or lastSpell[guid] or list[1][1]
				tinsert(
					entries,
					{
						["unit"] = unit,
						["guid"] = guid,
						["name"] = UnitName(unit) or unit,
						["class"] = class,
						["role"] = InterruptTrack:GetRole(unit),
						["spellID"] = spellID,
						["known"] = unit == "player" and IsKnown(spellID) or false,
						["remaining"] = 0,
						["duration"] = 0
					}
				)
			end
		end
	end

	InterruptTrack:ApplyLayout()
	InterruptTrack:UpdateBars()
end

function InterruptTrack:OnCast(unit, spellID)
	local duration = SPELLCDS[spellID]
	if duration == nil then return end
	local owner = PETOWNER[unit] or unit
	if UNITMAP[owner] == nil then return end
	local guid = UnitGUID(owner)
	if guid == nil then return end
	lastSpell[guid] = spellID
	casted[guid] = {["spellID"] = spellID, ["start"] = GetTime(), ["duration"] = duration}
	for i, entry in ipairs(entries) do
		if entry.guid == guid then
			entry.spellID = spellID
			entry.known = entry.unit == "player" and IsKnown(spellID) or false
		end
	end

	InterruptTrack:UpdateBars()
end

local function GetRemaining(entry)
	local now = GetTime()
	if entry.unit == "player" and entry.known then
		local start, duration = GetSpellCooldownInfo(entry.spellID)
		if start and duration and start > 0 and duration > 2 then
			local remaining = start + duration - now
			if remaining > 0 then return remaining, duration end
		end

		if start then return 0, 0 end
	end

	local cd = casted[entry.guid]
	if cd and cd.spellID == entry.spellID then
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
			if bar.spellID ~= entry.spellID then
				bar.spellID = entry.spellID
				local _, _, icon = InterruptTrack:GetSpellInfo(entry.spellID)
				bar.icon:SetTexture(icon)
			end

			local r, g, b, colorStr = InterruptTrack:GetClassColor(entry.class)
			bar.name:SetText("|c" .. colorStr .. entry.name .. "|r")
			if entry.remaining > 0 and entry.duration > 0 then
				bar.status:SetValue(1 - entry.remaining / entry.duration)
				bar.status:SetStatusBarColor(r * 0.5, g * 0.5, b * 0.5)
				bar.time:SetText(format("%.1f", entry.remaining))
			else
				bar.status:SetValue(1)
				bar.status:SetStatusBarColor(r, g, b)
				bar.time:SetText(InterruptTrack:Trans("LID_READY"))
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
eventFrame:SetScript(
	"OnEvent",
	function(sel, event, ...)
		if event == "UNIT_SPELLCAST_SUCCEEDED" then
			local unit, _, spellID = ...
			InterruptTrack:OnCast(unit, spellID)
		else
			InterruptTrack:UpdateRoster()
		end
	end
)
