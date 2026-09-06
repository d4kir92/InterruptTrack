local _, InterruptTrack = ...
local UNITS = {"player", "party1", "party2", "party3", "party4"}
local UNITMAP = {}
for i, unit in ipairs(UNITS) do
	UNITMAP[unit] = i
end

local PETUNITS = {"pet", "partypet1", "partypet2", "partypet3", "partypet4"}
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

local TRAVELTIME = {[31935] = 2, [147362] = 2}
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

SORTERS["COOLDOWNASC"] = function(a, b)
	if a.remaining ~= b.remaining then return a.remaining < b.remaining end
	if a.name ~= b.name then return a.name < b.name end

	return a.spellID < b.spellID
end

SORTERS["COOLDOWNDESC"] = function(a, b)
	if a.remaining ~= b.remaining then return a.remaining > b.remaining end
	if a.name ~= b.name then return a.name < b.name end

	return a.spellID < b.spellID
end

SORTERS["COOLDOWN"] = SORTERS["COOLDOWNASC"]
SORTERS["ROTATION"] = function(a, b)
	local ra = ROLEORDER[a.role] or 4
	local rb = ROLEORDER[b.role] or 4
	if ra ~= rb then return ra < rb end
	if a.guid ~= b.guid then return a.guid < b.guid end

	return a.spellID < b.spellID
end

local MINRATIO = 0.6
local SUCCESSWINDOW = 0.5
local DRIFTGRACE = 1.5
local entries = {}
local bars = {}
local casted = {}
local learned = {}
local pending = {}
local castStats = {}
local unknownCasts = {}
local hasAddon = {}
local lastHello = 0
local msgBlocked = false
local elapsed = 0
local markElapsed = 0
local lastKicker = nil
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

local function GetWindow(spellID)
	return TRAVELTIME[spellID] or SUCCESSWINDOW
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
		{["value"] = "COOLDOWNDESC", ["label"] = "LID_SORTBYCOOLDOWNDESC"},
		{["value"] = "COOLDOWNASC", ["label"] = "LID_SORTBYCOOLDOWNASC"}
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
	InterruptTrack:SendHello()
end

local nameIndex = nil
local function GetNameIndex()
	if nameIndex then return nameIndex end
	nameIndex = {}
	for spellID, cd in pairs(SPELLCDS) do
		local name = InterruptTrack:GetSpellInfo(spellID)
		if name and IsSecret(name) == false then nameIndex[name] = spellID end
	end

	return nameIndex
end

local function ResolveSpellID(spellID)
	if spellID == nil then return nil, true end
	if IsSecret(spellID) == false then return spellID, true end
	local readable = false
	if C_Spell and C_Spell.GetSpellName then
		local ok, name = pcall(C_Spell.GetSpellName, spellID)
		if ok and name and IsSecret(name) == false then
			readable = true
			local id = GetNameIndex()[name]
			if id then return id, true end
		end
	end

	if C_Spell and C_Spell.GetBaseSpell then
		local ok, baseID = pcall(C_Spell.GetBaseSpell, spellID)
		if ok and baseID and IsSecret(baseID) == false and SPELLCDS[baseID] then return baseID, true end
	end

	return nil, readable
end

local function FindReadyEntry(guid)
	for i, entry in ipairs(entries) do
		if entry.guid == guid and entry.remaining <= DRIFTGRACE then return entry end
	end

	return nil
end

local function StartUnknownCooldown(entry, castTime, kicked, hasKicked)
	casted[entry.key] = {
		["start"] = castTime,
		["duration"] = learned[entry.key] or SPELLCDS[entry.spellID],
		["success"] = true,
		["kicked"] = kicked,
		["hasKicked"] = hasKicked
	}

	lastKicker = entry.guid
end

function InterruptTrack:OnUnknownCast(unit)
	local owner = PETOWNER[unit] or unit
	if owner == "player" or UNITMAP[owner] == nil then return end
	local guid = Safe(UnitGUID(owner))
	if guid == nil then return end
	local name = Safe(UnitName(owner))
	if name and hasAddon[name] then return end
	local entry = FindReadyEntry(guid)
	if entry == nil then return end
	local now = GetTime()
	if pending.time ~= nil and now - pending.time <= SUCCESSWINDOW then
		unknownCasts[guid] = nil
		pending.time = nil
		StartUnknownCooldown(entry, now, pending.kicked, pending.hasKicked)
		InterruptTrack:DEBUG("UNIDENTIFIED CAST matched pending interrupt", entry.name)
		InterruptTrack:UpdateBars()

		return
	end

	unknownCasts[guid] = now
end

function InterruptTrack:OnCast(unit, spellID)
	if IsSecret(unit) then return end
	local resolved, readable = ResolveSpellID(spellID)
	if resolved == nil then
		if readable == false then InterruptTrack:OnUnknownCast(unit) end

		return
	end

	spellID = resolved
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

	lastKicker = guid
	if owner == "player" then InterruptTrack:SendKick(spellID, casted[key].duration) end
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
		if cd ~= nil and now - cd.start <= GetWindow(entry.spellID) then
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

	local guid = nil
	local newest = 0
	for castGuid, castTime in pairs(unknownCasts) do
		if now - castTime <= SUCCESSWINDOW and castTime > newest then
			newest = castTime
			guid = castGuid
		end
	end

	if guid then
		local target = FindReadyEntry(guid)
		if target then
			unknownCasts[guid] = nil
			StartUnknownCooldown(target, newest, spellID, hasKicked)
			InterruptTrack:DEBUG("INTERRUPTED attributed to unidentified cast", target.name)
			InterruptTrack:UpdateBars()

			return
		end
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
	bar.circle = bar:CreateTexture(nil, "ARTWORK")
	bar.circle:SetTexture("Interface\\COMMON\\Indicator-Green")
	bar.circle:Hide()
	bar.mark = bar:CreateTexture(nil, "ARTWORK")
	bar.mark:Hide()
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
		bar.circle:ClearAllPoints()
		bar.circle:SetPoint("RIGHT", bar, "LEFT", -2, 0)
		bar.circle:SetSize(height, height)
		bar.mark:ClearAllPoints()
		bar.mark:SetPoint("LEFT", bar, "RIGHT", 2, 0)
		bar.mark:SetSize(height, height)
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

local function GetNextInRotation()
	local order = {}
	local ready = {}
	for i, entry in ipairs(entries) do
		if ready[entry.guid] == nil then
			ready[entry.guid] = false
			tinsert(order, entry.guid)
		end

		if entry.remaining <= 0 then ready[entry.guid] = true end
	end

	local count = #order
	if count == 0 then return nil end
	local start = 1
	if lastKicker ~= nil then
		for i, guid in ipairs(order) do
			if guid == lastKicker then
				start = i + 1

				break
			end
		end
	end

	for x = 0, count - 1 do
		local guid = order[((start - 1 + x) % count) + 1]
		if ready[guid] then return guid end
	end

	return nil
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

	local rotation = InterruptTrack:GV(GetDB(), "KICKROTATION", true)
	local mode = InterruptTrack:GV(GetDB(), "SORTBY", "ROLE")
	if rotation then mode = "ROTATION" end
	local sorter = SORTERS[mode] or SORTERS["ROLE"]
	table.sort(entries, sorter)
	local nextKicker = nil
	if rotation then nextKicker = GetNextInRotation() end
	for i, entry in ipairs(entries) do
		local bar = bars[i]
		if bar then
			if nextKicker ~= nil and entry.guid == nextKicker then
				bar.circle:Show()
			else
				bar.circle:Hide()
			end
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
			local label = entry.name
			if entry.unit ~= "player" and hasAddon[entry.name] ~= true then label = "?" .. label end
			bar.name:SetText("|c" .. colorStr .. label .. "|r")
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

local PREFIX = "InterruptTrack"
local PLATEICONSIZE = 28
local PLATEICONOFFSET = 20
local markers = {}
local function FirstChar(name)
	if name == nil or name == "" then return "" end
	local b = strbyte(name, 1)
	local len = 1
	if b >= 240 then
		len = 4
	elseif b >= 224 then
		len = 3
	elseif b >= 192 then
		len = 2
	end

	return strsub(name, 1, len)
end

local function GetPlateToken(plate)
	local token = plate.namePlateUnitToken
	if token == nil and plate.UnitFrame then token = plate.UnitFrame.unit end

	return token
end

local function GetPlateMarkFrame(plate)
	if plate.ITMark then return plate.ITMark end
	local frame = CreateFrame("Frame", nil, plate)
	frame:SetSize(PLATEICONSIZE, PLATEICONSIZE)
	frame:SetPoint("LEFT", plate, "RIGHT", PLATEICONOFFSET, 0)
	frame.icon = frame:CreateTexture(nil, "ARTWORK")
	frame.icon:SetAllPoints(frame)
	frame.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	frame.text = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	frame.text:SetPoint("CENTER", frame, "CENTER", 0, 0)
	frame.time = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	frame.time:SetPoint("TOP", frame, "BOTTOM", 0, -2)
	frame:Hide()
	plate.ITMark = frame

	return frame
end

local function GetKickInfo()
	local best = nil
	local guid = GetNextInRotation()
	if guid then
		for i, entry in ipairs(entries) do
			if entry.guid == guid and entry.remaining <= 0 then
				best = entry

				break
			end
		end
	end

	if best == nil then
		for i, entry in ipairs(entries) do
			if best == nil or entry.remaining < best.remaining then best = entry end
		end
	end

	if best == nil then return nil end
	local _, _, icon = InterruptTrack:GetSpellInfo(best.spellID)

	return {
		["icon"] = icon,
		["initial"] = FirstChar(best.name),
		["remaining"] = best.remaining,
		["ready"] = best.remaining <= 0
	}
end

local function GetUnitByName(name)
	for i, unit in ipairs(UNITS) do
		if Safe(UnitName(unit)) == name then return unit end
	end

	return nil
end

local function GetTargetUnit(unit)
	if unit == "player" then return "target" end

	return unit .. "target"
end

local activeMarkers = {}
function InterruptTrack:UpdatePlates()
	if C_NamePlate == nil then return end
	wipe(activeMarkers)
	for name, active in pairs(markers) do
		local unit = GetUnitByName(name)
		if unit then tinsert(activeMarkers, {["target"] = GetTargetUnit(unit)}) end
	end

	local plates = C_NamePlate.GetNamePlates()
	local info = nil
	if #activeMarkers > 0 then info = GetKickInfo() end
	if info == nil then
		for i, plate in pairs(plates) do
			if plate.ITMark then plate.ITMark:Hide() end
		end

		return
	end

	for i, plate in pairs(plates) do
		local token = GetPlateToken(plate)
		local marked = false
		if token then
			for x, tab in ipairs(activeMarkers) do
				if Safe(UnitIsUnit(token, tab.target), false) == true then
					marked = true

					break
				end
			end
		end

		local frame = GetPlateMarkFrame(plate)
		if marked then
			frame.icon:SetTexture(info.icon)
			frame.icon:SetDesaturated(info.ready ~= true)
			frame.text:SetText(info.initial)
			if info.ready then
				frame.time:SetText("")
			else
				frame.time:SetText(format("%.0f", info.remaining))
			end

			frame:Show()
		else
			frame:Hide()
		end
	end
end

local function Transmit(msg, channel)
	local ok, ret = pcall(C_ChatInfo.SendAddonMessage, PREFIX, msg, channel)
	if ok == false then return false end
	if ret == 0 then
		msgBlocked = false

		return true
	end

	if ret == 11 then msgBlocked = true end

	return false
end

local function IsInInstanceGroup()
	if LE_PARTY_CATEGORY_INSTANCE == nil then return false end

	return IsInGroup(LE_PARTY_CATEGORY_INSTANCE) == true
end

local function Send(msg)
	if C_ChatInfo == nil or C_ChatInfo.SendAddonMessage == nil then return end
	local channel = nil
	if IsInInstanceGroup() then
		channel = "INSTANCE_CHAT"
	elseif IsInRaid() then
		channel = "RAID"
	elseif IsInGroup() then
		channel = "PARTY"
	end

	if channel == nil then return end
	Transmit(msg, channel)
end

function InterruptTrack:SendMark(active)
	if active then
		Send("M")
	else
		Send("C")
	end
end

function InterruptTrack:SendKick(spellID, duration)
	Send(format("K:%d:%.1f", spellID, duration))
end

function InterruptTrack:SendHello()
	local now = GetTime()
	if now - lastHello < 5 then return end
	lastHello = now
	Send("H")
end

function InterruptTrack:HasAddon(name)
	return hasAddon[name] == true
end

function InterruptTrack:SetMark(active)
	local me = Safe(UnitName("player"))
	if me == nil then return end
	if active then
		markers[me] = true
	else
		markers[me] = nil
	end

	InterruptTrack:SendMark(active)
	InterruptTrack:UpdatePlates()
end

function InterruptTrack:IsMarking()
	local me = Safe(UnitName("player"))

	return me ~= nil and markers[me] ~= nil
end

function InterruptTrack:OnAddonMessage(msg, sender)
	if msg == nil or sender == nil then return end
	local name = strsplit("-", sender)
	if name == Safe(UnitName("player")) then return end
	hasAddon[name] = true
	local cmd, a, b = strsplit(":", msg)
	if cmd == "H" then return end
	if cmd == "K" then
		local spellID = tonumber(a)
		local duration = tonumber(b)
		if spellID == nil or duration == nil then return end
		local unit = GetUnitByName(name)
		if unit == nil then return end
		local guid = Safe(UnitGUID(unit))
		if guid == nil then return end
		local key = GetKey(guid, spellID)
		local isNew = casted[key] == nil
		casted[key] = {["start"] = GetTime(), ["duration"] = duration}
		lastKicker = guid
		InterruptTrack:DEBUG("KICK from", name, spellID, duration)
		if isNew then
			InterruptTrack:UpdateRoster()
		else
			InterruptTrack:UpdateBars()
		end

		return
	end

	if cmd == "C" then
		markers[name] = nil
	elseif cmd == "M" then
		markers[name] = true
	else
		return
	end

	InterruptTrack:UpdatePlates()
end

local markButton = CreateFrame("Button", "ITMarkButton", UIParent)
markButton:SetSize(1, 1)
markButton:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -200, 200)
markButton:SetAlpha(0)
markButton:RegisterForClicks("AnyDown")
markButton:SetScript("OnClick", function() InterruptTrack:MarkTarget() end)
function InterruptTrack:ApplyKeybind()
	if InCombatLockdown() then return end
	ClearOverrideBindings(markButton)
	local key = InterruptTrack:GV(GetDB(), "MARKKEY", nil)
	if key == nil or key == "" then return end
	SetOverrideBindingClick(markButton, true, key, "ITMarkButton")
end

function InterruptTrack:MarkTarget()
	if InterruptTrack:IsMarking() then
		InterruptTrack:SetMark(false)
		InterruptTrack:MSG(InterruptTrack:Trans("LID_MARKTARGETCLEARED"))

		return
	end

	if Safe(UnitExists("target"), true) ~= true then
		InterruptTrack:MSG(InterruptTrack:Trans("LID_MARKNOTARGET"))

		return
	end

	InterruptTrack:SetMark(true)
	InterruptTrack:MSG(InterruptTrack:Trans("LID_MARKTARGETSET"), Safe(UnitName("target"), ""))
end

function InterruptTrack:CheckSecrets()
	InterruptTrack:MSG("target exists", DebugValue(UnitExists("target")), "guid", DebugValue(UnitGUID("target")))
	if C_NamePlate == nil then
		InterruptTrack:MSG("C_NamePlate missing")

		return
	end

	local ok, plate = pcall(C_NamePlate.GetNamePlateForUnit, "target")
	InterruptTrack:MSG("GetNamePlateForUnit(target)", tostring(ok), tostring(plate))
	if ok and plate then InterruptTrack:MSG("  token", tostring(plate.namePlateUnitToken)) end
	local ok2, plate2 = pcall(C_NamePlate.GetNamePlateForUnit, "target", true)
	InterruptTrack:MSG("GetNamePlateForUnit(target, true)", tostring(ok2), tostring(plate2))
	if ok2 and plate2 then InterruptTrack:MSG("  token", tostring(plate2.namePlateUnitToken)) end
	local count = 0
	for i, p in pairs(C_NamePlate.GetNamePlates()) do
		count = count + 1
		local token = GetPlateToken(p)
		local highlight = "?"
		if p.UnitFrame and p.UnitFrame.selectionHighlight then highlight = tostring(p.UnitFrame.selectionHighlight:IsShown()) end
		InterruptTrack:MSG("plate", tostring(token), DebugValue(UnitName(token)), "guid", DebugValue(UnitGUID(token)), "isTarget", DebugValue(UnitIsUnit(token, "target")), "highlight", highlight)
	end

	InterruptTrack:MSG("plate count", count)
	InterruptTrack:MSG("group", tostring(IsInGroup()), "| instance group", tostring(IsInInstanceGroup()), "| messages blocked", tostring(msgBlocked))
	for token, n in pairs(castStats) do
		InterruptTrack:MSG("cast events", token, n)
	end
end

local markedPlates = {}
local function BuildMarkedPlates()
	wipe(markedPlates)
	if C_NamePlate == nil then return end
	for i, plate in pairs(C_NamePlate.GetNamePlates()) do
		local token = GetPlateToken(plate)
		if token then
			local index = Safe(GetRaidTargetIndex(token))
			if index then tinsert(markedPlates, {["token"] = token, ["index"] = index}) end
		end
	end
end

local function GetTargetMark(unit)
	if #markedPlates == 0 then return nil end
	local target = "target"
	if unit ~= "player" then target = unit .. "target" end
	if Safe(UnitExists(target), true) ~= true then return nil end
	for i, tab in ipairs(markedPlates) do
		if Safe(UnitIsUnit(tab.token, target), false) == true then return tab.index end
	end

	return nil
end

function InterruptTrack:UpdateMarks()
	if self.frame == nil then return end
	local show = InterruptTrack:GV(GetDB(), "SHOWRAIDMARK", true)
	if show then BuildMarkedPlates() end
	for i, entry in ipairs(entries) do
		local bar = bars[i]
		if bar then
			local index = nil
			if show then index = GetTargetMark(entry.unit) end
			if index ~= bar.markIndex then
				bar.markIndex = index
				if index then
					bar.mark:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcon_" .. index)
					bar.mark:Show()
				else
					bar.mark:Hide()
				end
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
			if elapsed >= 0.05 then
				elapsed = 0
				InterruptTrack:UpdateBars()
			end

			markElapsed = markElapsed + ela
			if markElapsed >= 0.25 then
				markElapsed = 0
				InterruptTrack:UpdateMarks()
				InterruptTrack:UpdatePlates()
			end
		end
	)

	InterruptTrack:UpdateRoster()
end

local castFrames = {}
local function OnCastEvent(sel, event, unit, castGUID, spellID)
	local key = "secret-unit"
	if IsSecret(unit) == false then
		key = unit
		if IsSecret(spellID) then
			key = unit .. " (secret id"
			if C_Spell and C_Spell.GetSpellName then
				local ok, name = pcall(C_Spell.GetSpellName, spellID)
				if ok and name and IsSecret(name) == false then
					key = key .. ", NAME OK)"
				else
					key = key .. ", name secret)"
				end
			else
				key = key .. ")"
			end
		end
	end

	castStats[key] = (castStats[key] or 0) + 1
	InterruptTrack:OnCast(unit, spellID)
end

for i, unit in ipairs(UNITS) do
	local frame = CreateFrame("Frame")
	frame:SetScript("OnEvent", OnCastEvent)
	if C_EventUtils == nil or C_EventUtils.IsEventValid("UNIT_SPELLCAST_SUCCEEDED") then frame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", unit, PETUNITS[i]) end
	castFrames[i] = frame
end

local eventFrame = CreateFrame("Frame")
InterruptTrack:RegisterEvent(eventFrame, "PLAYER_ENTERING_WORLD")
InterruptTrack:RegisterEvent(eventFrame, "GROUP_ROSTER_UPDATE")
InterruptTrack:RegisterEvent(eventFrame, "PLAYER_ROLES_ASSIGNED")
InterruptTrack:RegisterEvent(eventFrame, "PLAYER_SPECIALIZATION_CHANGED")
InterruptTrack:RegisterEvent(eventFrame, "UNIT_SPELLCAST_INTERRUPTED")
InterruptTrack:RegisterEvent(eventFrame, "UNIT_SPELLCAST_CHANNEL_STOP")
InterruptTrack:RegisterEvent(eventFrame, "NAME_PLATE_UNIT_ADDED")
InterruptTrack:RegisterEvent(eventFrame, "NAME_PLATE_UNIT_REMOVED")
InterruptTrack:RegisterEvent(eventFrame, "CHAT_MSG_ADDON")
eventFrame:SetScript(
	"OnEvent",
	function(sel, event, ...)
		if event == "UNIT_SPELLCAST_INTERRUPTED" then
			local unit, castGUID, spellID = ...
			InterruptTrack:DEBUG("EVENT INTERRUPTED", DebugValue(unit), DebugValue(castGUID), DebugValue(spellID))
			InterruptTrack:OnInterrupted(unit, spellID)
		elseif event == "UNIT_SPELLCAST_CHANNEL_STOP" then
			local unit, _, spellID, interruptedBy = ...
			if interruptedBy ~= nil then
				InterruptTrack:DEBUG("EVENT CHANNEL STOP", DebugValue(unit), DebugValue(spellID))
				InterruptTrack:OnInterrupted(unit, spellID)
			end
		elseif event == "NAME_PLATE_UNIT_ADDED" or event == "NAME_PLATE_UNIT_REMOVED" then
			InterruptTrack:UpdatePlates()
		elseif event == "CHAT_MSG_ADDON" then
			local prefix, msg, _, sender = ...
			if prefix == PREFIX then InterruptTrack:OnAddonMessage(msg, sender) end
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
