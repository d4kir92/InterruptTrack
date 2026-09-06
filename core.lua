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
local entries = {}
local bars = {}
local casted = {}
local learned = {}
local pending = {}
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

	lastKicker = guid
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

local PREFIX = "InterruptTrack"
local PLATEICONSIZE = 28
local marks = {}
local markBySender = {}
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

local function GetMySpecIcon()
	if GetSpecialization and GetSpecializationInfo then
		local spec = GetSpecialization()
		if spec then
			local _, _, _, icon = GetSpecializationInfo(spec)
			if icon then return icon end
		end
	end

	local _, class = UnitClass("player")

	return InterruptTrack:GetClassIcon(class)
end

local function GetPlateMarkFrame(plate)
	if plate.ITMark then return plate.ITMark end
	local frame = CreateFrame("Frame", nil, plate)
	frame:SetSize(PLATEICONSIZE, PLATEICONSIZE)
	frame:SetPoint("LEFT", plate, "RIGHT", 6, 0)
	frame.icon = frame:CreateTexture(nil, "ARTWORK")
	frame.icon:SetAllPoints(frame)
	frame.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	frame.text = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	frame.text:SetPoint("CENTER", frame, "CENTER", 0, 0)
	frame:Hide()
	plate.ITMark = frame

	return frame
end

function InterruptTrack:UpdatePlates()
	if C_NamePlate == nil then return end
	for i, plate in pairs(C_NamePlate.GetNamePlates()) do
		local token = GetPlateToken(plate)
		local mark = nil
		if token then
			local guid = Safe(UnitGUID(token))
			if guid then mark = marks[guid] end
		end

		local frame = GetPlateMarkFrame(plate)
		if mark then
			frame.icon:SetTexture(mark.icon)
			frame.text:SetText(mark.initial)
			frame:Show()
		else
			frame:Hide()
		end
	end
end

function InterruptTrack:ApplyMark(sender, guid, icon)
	local old = markBySender[sender]
	if old then marks[old] = nil end
	if guid == nil then
		markBySender[sender] = nil
	else
		markBySender[sender] = guid
		marks[guid] = {["icon"] = icon, ["initial"] = FirstChar(sender), ["sender"] = sender}
	end

	InterruptTrack:UpdatePlates()
end

function InterruptTrack:SendMark(guid)
	if C_ChatInfo == nil or C_ChatInfo.SendAddonMessage == nil then return end
	local channel = nil
	if IsInRaid() then
		channel = "RAID"
	elseif IsInGroup() then
		channel = "PARTY"
	end

	if channel == nil then return end
	local msg = "C"
	if guid then msg = "M:" .. guid .. ":" .. tostring(GetMySpecIcon() or 0) end
	C_ChatInfo.SendAddonMessage(PREFIX, msg, channel)
end

function InterruptTrack:SetMark(guid)
	InterruptTrack.markGuid = guid
	InterruptTrack:ApplyMark(UnitName("player"), guid, GetMySpecIcon())
	InterruptTrack:SendMark(guid)
end

function InterruptTrack:OnAddonMessage(msg, sender)
	if msg == nil or sender == nil then return end
	local name = strsplit("-", sender)
	if name == UnitName("player") then return end
	if msg == "C" then
		InterruptTrack:ApplyMark(name, nil, nil)

		return
	end

	local cmd, guid, icon = strsplit(":", msg)
	if cmd ~= "M" or guid == nil or guid == "" then return end
	InterruptTrack:ApplyMark(name, guid, tonumber(icon))
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

local function GetTargetPlateUnit()
	if C_NamePlate == nil then return nil end
	if C_NamePlate.GetNamePlateForUnit then
		local plate = C_NamePlate.GetNamePlateForUnit("target")
		if plate and plate.namePlateUnitToken then return plate.namePlateUnitToken end
	end

	for i, plate in pairs(C_NamePlate.GetNamePlates()) do
		local token = plate.namePlateUnitToken
		if token == nil and plate.UnitFrame then token = plate.UnitFrame.unit end
		if token and Safe(UnitIsUnit(token, "target"), false) == true then return token end
	end

	return nil
end

function InterruptTrack:MarkTarget()
	if Safe(UnitExists("target"), true) ~= true then
		InterruptTrack:MSG(InterruptTrack:Trans("LID_MARKNOTARGET"))

		return
	end

	local token = GetTargetPlateUnit()
	local guid = nil
	local name = nil
	if token then
		guid = Safe(UnitGUID(token))
		name = Safe(UnitName(token))
	end

	InterruptTrack:DEBUG("MARK", tostring(token), DebugValue(guid), DebugValue(name))
	if guid == nil then
		InterruptTrack:MSG(InterruptTrack:Trans("LID_MARKTARGETSECRET"))

		return
	end

	if InterruptTrack.markGuid == guid then
		InterruptTrack:SetMark(nil)
		InterruptTrack:MSG(InterruptTrack:Trans("LID_MARKTARGETCLEARED"))

		return
	end

	InterruptTrack:SetMark(guid)
	InterruptTrack:MSG(InterruptTrack:Trans("LID_MARKTARGETSET"), name or guid)
end

function InterruptTrack:CheckSecrets()
	InterruptTrack:MSG("target guid", DebugValue(UnitGUID("target")))
	InterruptTrack:MSG("target name", DebugValue(UnitName("target")))
	InterruptTrack:MSG("target mark", DebugValue(GetRaidTargetIndex("target")))
	InterruptTrack:MSG("nameplate1 guid", DebugValue(UnitGUID("nameplate1")))
	InterruptTrack:MSG("nameplate1 name", DebugValue(UnitName("nameplate1")))
	InterruptTrack:MSG("nameplate1 is target", DebugValue(UnitIsUnit("nameplate1", "target")))
	InterruptTrack:MSG("party1target guid", DebugValue(UnitGUID("party1target")))
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
			end
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
InterruptTrack:RegisterEvent(eventFrame, "NAME_PLATE_UNIT_ADDED")
InterruptTrack:RegisterEvent(eventFrame, "NAME_PLATE_UNIT_REMOVED")
InterruptTrack:RegisterEvent(eventFrame, "CHAT_MSG_ADDON")
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
