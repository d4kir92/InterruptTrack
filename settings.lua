-- By D4KiR
local _, InterruptTrack = ...
InterruptTrack:SetAddonOutput("InterruptTrack", 132219)
local itset = nil
local DEFAULT_WIDTH = 420
local DEFAULT_HEIGHT = 520
function InterruptTrack:ToggleSettings()
	if itset == nil then return end
	itset:Toggle()
end

local function OnSlash(msg)
	local cmd = ""
	if msg then cmd = strlower(strtrim(msg)) end
	if cmd == "debug" then
		InterruptTrack:ToggleDebug()

		return
	end

	if cmd == "check" then
		InterruptTrack:CheckSecrets()

		return
	end

	InterruptTrack:ToggleSettings()
end

local function GetCollapsed(key)
	if key == nil then return nil end
	if type(InterruptTrackG) ~= "table" then return nil end
	if type(InterruptTrackG["COLLAPSED"]) ~= "table" then return nil end

	return InterruptTrackG["COLLAPSED"][key]
end

local function SetCollapsed(key, collapsed)
	if key == nil then return end
	if type(InterruptTrackG) ~= "table" then return end
	if type(InterruptTrackG["COLLAPSED"]) ~= "table" then InterruptTrackG["COLLAPSED"] = {} end
	if collapsed then
		InterruptTrackG["COLLAPSED"][key] = true
	else
		InterruptTrackG["COLLAPSED"][key] = nil
	end
end

local function GetConfig(key, default)
	local value = InterruptTrack:GV(InterruptTrackG, key, default)
	InterruptTrack:SV(InterruptTrackG, key, value)

	return value
end

local function AddCategory(key, level)
	itset:AddCategory({
		["label"] = "LID_" .. key,
		["key"] = key,
		["search"] = key,
		["level"] = level
	})
end

local function AddCheckbox(key, default, func)
	itset:AddCheckbox({
		["label"] = "LID_" .. key,
		["search"] = key,
		["value"] = GetConfig(key, default),
		["func"] = function(value)
			InterruptTrack:SV(InterruptTrackG, key, value)
			if func then func(value) end
		end
	})
end

local function AddSlider(key, default, min, max, step, decimals, func)
	itset:AddSlider({
		["label"] = "LID_" .. key,
		["search"] = key,
		["value"] = GetConfig(key, default),
		["min"] = min,
		["max"] = max,
		["step"] = step,
		["decimals"] = decimals,
		["func"] = function(value)
			InterruptTrack:SV(InterruptTrackG, key, value)
			if func then func(value) end
		end
	})
end

local function AddKeybind(key, default, func)
	itset:AddKeybind({
		["label"] = "LID_" .. key,
		["search"] = key,
		["value"] = GetConfig(key, default),
		["func"] = function(value)
			InterruptTrack:SV(InterruptTrackG, key, value)
			if func then func(value) end
		end
	})
end

local function AddDropdown(key, default, choices, func)
	itset:AddDropdown({
		["label"] = "LID_" .. key,
		["search"] = key,
		["value"] = GetConfig(key, default),
		["choices"] = choices,
		["func"] = function(value)
			InterruptTrack:SV(InterruptTrackG, key, value)
			if func then func(value) end
		end
	})
end

function InterruptTrack:InitSettings()
	itset = InterruptTrack:CreateUIWindow({
		["name"] = "InterruptTrackSettings",
		["pTab"] = {"CENTER"},
		["width"] = GetConfig("WINDOWWIDTH", DEFAULT_WIDTH),
		["height"] = GetConfig("WINDOWHEIGHT", DEFAULT_HEIGHT),
		["minWidth"] = 360,
		["minHeight"] = 240,
		["onResize"] = function(width, height)
			InterruptTrack:SV(InterruptTrackG, "WINDOWWIDTH", width)
			InterruptTrack:SV(InterruptTrackG, "WINDOWHEIGHT", height)
		end,
		["getCollapsed"] = function(key) return GetCollapsed(key) end,
		["setCollapsed"] = function(key, collapsed) SetCollapsed(key, collapsed) end,
		["title"] = format("|T132219:16:16:0:0|t InterruptTrack v%s", InterruptTrack:GetVersion())
	})

	itset:SuspendLayout()
	itset:AddSearch()
	AddCategory("GENERAL")
	AddCheckbox("MMBTN", true, function(value)
		if value then
			InterruptTrack:ShowMMBtn("InterruptTrack")
		else
			InterruptTrack:HideMMBtn("InterruptTrack")
		end
	end)

	AddKeybind("MARKKEY", nil, function() InterruptTrack:ApplyKeybind() end)
	AddCategory("DISPLAY")
	AddDropdown("SORTBY", "ROLE", InterruptTrack:GetSortModes(), function() InterruptTrack:UpdateBars() end)
	AddCheckbox("KICKROTATION", true, function() InterruptTrack:UpdateBars() end)
	AddCheckbox("SHOWRAIDMARK", true, function() InterruptTrack:UpdateMarks() end)
	AddCategory("BAR", 2)
	AddSlider("BARWIDTH", 200, 100, 400, 5, 0, function() InterruptTrack:ApplyLayout() end)
	AddSlider("BARHEIGHT", 24, 10, 60, 1, 0, function() InterruptTrack:ApplyLayout() end)
	AddSlider("BARSPACING", 2, 0, 20, 1, 0, function() InterruptTrack:ApplyLayout() end)
	itset:ResumeLayout()
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:SetScript("OnEvent", function(self, event, ...)
	if event == "PLAYER_LOGIN" then
		InterruptTrackG = InterruptTrackG or {}
		InterruptTrack:SetVersion(132219, "0.1.0")
		InterruptTrack:InitSettings()
		InterruptTrack:CreateMainFrame()
		InterruptTrack:ApplyKeybind()
		if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then C_ChatInfo.RegisterAddonMessagePrefix("InterruptTrack") end
		InterruptTrack:AddSlash("interrupttrack", OnSlash)
		InterruptTrack:CreateMinimapButton({
			["name"] = "InterruptTrack",
			["icon"] = 132219,
			["var"] = nil,
			["dbtab"] = InterruptTrackG,
			["vTT"] = {{"|T132219:16:16:0:0|t InterruptTrack", "v" .. InterruptTrack:GetVersion()}, {InterruptTrack:Trans("LID_LEFTCLICK"), InterruptTrack:Trans("LID_OPENSETTINGS")}, {InterruptTrack:Trans("LID_SHIFTRIGHTCLICK"), InterruptTrack:Trans("LID_HIDEMINIMAPBUTTON")}},
			["funcL"] = function() InterruptTrack:ToggleSettings() end,
			["funcSR"] = function()
				InterruptTrack:SV(InterruptTrackG, "MMBTN", false)
				InterruptTrack:MSG(InterruptTrack:Trans("LID_MINIMAPBUTTONISNOWHIDDEN"))
				InterruptTrack:HideMMBtn("InterruptTrack")
			end,
			["dbkey"] = "MMBTN"
		})
	end
end)
