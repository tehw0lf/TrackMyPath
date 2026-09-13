--[[ TrackMyPath - Options.lua
     Slash commands and a small options panel.

     The panel is hand-rolled rather than using InterfaceOptions_AddCategory
     templates, because the 3.3.5a option-panel templates are awkward about
     sliders with non-integer steps and this keeps the addon dependency-free.
]]

local TMP = TrackMyPath

local panel = nil

local function print_(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99TrackMyPath|r: " .. tostring(msg))
end

--------------------------------------------------------------------------------
-- Slash commands
--------------------------------------------------------------------------------

local function status()
	local db = TMP.db
	print_(string.format("enabled: %s | fade: %ds | interval: %.1fs",
		db.enabled and "|cff00ff00yes|r" or "|cffff0000no|r",
		db.fadeTime, db.sampleInterval))
	print_(string.format("worldmap: %s | minimap: %s",
		db.showWorldMap and "on" or "off",
		db.showMinimap and "on" or "off"))
	print_(string.format("samples: %d across %d zone(s) | cap %d",
		TMP.Trail:TotalCount(), TMP.Trail:ActiveZoneCount(), db.maxSamples))
end

local function usage()
	print_("commands:")
	print_("  /tmp            - open options")
	print_("  /tmp on | off   - enable or disable tracking")
	print_("  /tmp fade <sec> - trail lifetime in seconds (30-3600)")
	print_("  /tmp rate <sec> - sample interval in seconds (0.2-5)")
	print_("  /tmp size <px>  - dot size (2-16)")
	print_("  /tmp minimap    - toggle the minimap trail")
	print_("  /tmp worldmap   - toggle the world map trail")
	print_("  /tmp clear      - erase the recorded trail")
	print_("  /tmp reset      - restore default settings")
	print_("  /tmp status     - show current state")
end

local function handler(input)
	local db = TMP.db
	input = (input or ""):lower()
	local cmd, arg = input:match("^(%S*)%s*(.-)$")

	if cmd == "" then
		TMP:ToggleOptions()

	elseif cmd == "on" then
		db.enabled = true
		TMP:ApplyMinimapVisibility()
		print_("tracking enabled")

	elseif cmd == "off" then
		db.enabled = false
		TMP:RefreshWorldMap()
		TMP:ApplyMinimapVisibility()
		print_("tracking disabled")

	elseif cmd == "fade" then
		local v = tonumber(arg)
		if not v or v < 30 or v > 3600 then
			print_("fade needs a value between 30 and 3600 seconds")
		else
			db.fadeTime = v
			print_(string.format("fade time set to %d seconds", v))
		end

	elseif cmd == "rate" then
		local v = tonumber(arg)
		if not v or v < 0.2 or v > 5 then
			print_("rate needs a value between 0.2 and 5 seconds")
		else
			db.sampleInterval = v
			print_(string.format("sample interval set to %.1f seconds", v))
		end

	elseif cmd == "size" then
		local v = tonumber(arg)
		if not v or v < 2 or v > 16 then
			print_("size needs a value between 2 and 16")
		else
			db.dotSize = v
			TMP:RefreshWorldMap()
			print_(string.format("dot size set to %d", v))
		end

	elseif cmd == "minimap" then
		db.showMinimap = not db.showMinimap
		TMP:ApplyMinimapVisibility()
		print_("minimap trail " .. (db.showMinimap and "on" or "off"))

	elseif cmd == "worldmap" then
		db.showWorldMap = not db.showWorldMap
		TMP:RefreshWorldMap()
		print_("world map trail " .. (db.showWorldMap and "on" or "off"))

	elseif cmd == "clear" then
		TMP.Trail:Clear()
		TMP:RefreshWorldMap()
		TMP:RefreshMinimap()
		print_("trail cleared")

	elseif cmd == "reset" then
		TMP:ResetConfig()
		TMP:ApplyMinimapVisibility()
		TMP:RefreshWorldMap()
		print_("settings restored to defaults")

	elseif cmd == "status" then
		status()

	else
		usage()
	end
end

function TMP:InitSlash()
	SLASH_TRACKMYPATH1 = "/trackmypath"
	SLASH_TRACKMYPATH2 = "/tmp"
	SlashCmdList["TRACKMYPATH"] = handler
end

--------------------------------------------------------------------------------
-- Options panel
--------------------------------------------------------------------------------

local function makeSlider(parent, label, minV, maxV, step, y, fmt, get, set)
	local s = CreateFrame("Slider", "TrackMyPathSlider" .. label:gsub("%s", ""),
		parent, "OptionsSliderTemplate")
	s:SetPoint("TOPLEFT", 20, y)
	s:SetWidth(220)
	s:SetMinMaxValues(minV, maxV)
	s:SetValueStep(step)
	s:SetValue(get())

	local name = s:GetName()
	_G[name .. "Low"]:SetText("")
	_G[name .. "High"]:SetText("")
	local text = _G[name .. "Text"]
	text:SetText(string.format(fmt, get()))

	s:SetScript("OnValueChanged", function(self, value)
		-- OptionsSliderTemplate does not snap to the step itself on 3.3.5a.
		if step >= 1 then
			value = math.floor(value / step + 0.5) * step
		end
		set(value)
		text:SetText(string.format(fmt, value))
	end)

	return s
end

local function makeCheck(parent, label, y, get, set)
	local c = CreateFrame("CheckButton", "TrackMyPathCheck" .. label:gsub("%s", ""),
		parent, "InterfaceOptionsCheckButtonTemplate")
	c:SetPoint("TOPLEFT", 16, y)
	_G[c:GetName() .. "Text"]:SetText(label)
	c:SetChecked(get())
	c:SetScript("OnClick", function(self)
		set(self:GetChecked() and true or false)
	end)
	return c
end

function TMP:InitOptions()
	panel = CreateFrame("Frame", "TrackMyPathOptions", UIParent)
	panel:SetWidth(300)
	panel:SetHeight(420)
	panel:SetPoint("CENTER")
	panel:SetBackdrop({
		bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
		edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
		tile = true, tileSize = 32, edgeSize = 32,
		insets = { left = 11, right = 12, top = 12, bottom = 11 },
	})
	panel:SetMovable(true)
	panel:EnableMouse(true)
	panel:RegisterForDrag("LeftButton")
	panel:SetScript("OnDragStart", panel.StartMoving)
	panel:SetScript("OnDragStop", panel.StopMovingOrSizing)
	panel:Hide()

	local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOP", 0, -18)
	title:SetText("TrackMyPath " .. TMP.VERSION)

	local close = CreateFrame("Button", nil, panel, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -8, -8)

	local db = TMP.db

	makeCheck(panel, "Enable tracking", -46,
		function() return db.enabled end,
		function(v)
			db.enabled = v
			TMP:RefreshWorldMap()
			TMP:ApplyMinimapVisibility()
		end)

	makeCheck(panel, "Show on world map", -74,
		function() return db.showWorldMap end,
		function(v) db.showWorldMap = v; TMP:RefreshWorldMap() end)

	makeCheck(panel, "Show on minimap (approximate)", -102,
		function() return db.showMinimap end,
		function(v) db.showMinimap = v; TMP:ApplyMinimapVisibility() end)

	makeSlider(panel, "Fade", 30, 1800, 30, -150, "Trail lifetime: %d s",
		function() return db.fadeTime end,
		function(v) db.fadeTime = v end)

	makeSlider(panel, "Rate", 0.2, 5, 0.2, -200, "Sample every %.1f s",
		function() return db.sampleInterval end,
		function(v) db.sampleInterval = v end)

	makeSlider(panel, "Size", 2, 16, 1, -250, "Dot size: %d px",
		function() return db.dotSize end,
		function(v) db.dotSize = v; TMP:RefreshWorldMap() end)

	makeSlider(panel, "MinimapSize", 2, 12, 1, -300, "Minimap dot size: %d px",
		function() return db.minimapDotSize end,
		function(v) db.minimapDotSize = v end)

	-- Colour swatch
	local colorBtn = CreateFrame("Button", nil, panel)
	colorBtn:SetWidth(24)
	colorBtn:SetHeight(24)
	colorBtn:SetPoint("TOPLEFT", 24, -345)
	local swatch = colorBtn:CreateTexture(nil, "OVERLAY")
	swatch:SetAllPoints(colorBtn)
	swatch:SetTexture("Interface\\Buttons\\WHITE8X8")
	swatch:SetVertexColor(db.color.r, db.color.g, db.color.b)

	local colorLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	colorLabel:SetPoint("LEFT", colorBtn, "RIGHT", 8, 0)
	colorLabel:SetText("Trail colour")

	colorBtn:SetScript("OnClick", function()
		local function apply()
			local r, g, b = ColorPickerFrame:GetColorRGB()
			db.color.r, db.color.g, db.color.b = r, g, b
			swatch:SetVertexColor(r, g, b)
			TMP:RefreshWorldMap()
		end
		local prev = { db.color.r, db.color.g, db.color.b }
		ColorPickerFrame.func = apply
		ColorPickerFrame.opacityFunc = nil
		ColorPickerFrame.hasOpacity = false
		ColorPickerFrame.cancelFunc = function()
			db.color.r, db.color.g, db.color.b = prev[1], prev[2], prev[3]
			swatch:SetVertexColor(prev[1], prev[2], prev[3])
			TMP:RefreshWorldMap()
		end
		ColorPickerFrame:SetColorRGB(db.color.r, db.color.g, db.color.b)
		ColorPickerFrame:Hide() -- force OnShow to fire even if already shown
		ColorPickerFrame:Show()
	end)

	local clearBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	clearBtn:SetWidth(110)
	clearBtn:SetHeight(22)
	clearBtn:SetPoint("BOTTOMLEFT", 24, 22)
	clearBtn:SetText("Clear trail")
	clearBtn:SetScript("OnClick", function()
		TMP.Trail:Clear()
		TMP:RefreshWorldMap()
		TMP:RefreshMinimap()
	end)

	local resetBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	resetBtn:SetWidth(110)
	resetBtn:SetHeight(22)
	resetBtn:SetPoint("BOTTOMRIGHT", -24, 22)
	resetBtn:SetText("Reset")
	resetBtn:SetScript("OnClick", function()
		TMP:ResetConfig()
		TMP:ApplyMinimapVisibility()
		TMP:RefreshWorldMap()
		-- Rebuild so widgets reflect the restored values.
		print_("settings reset - /reload to refresh this panel")
	end)

	tinsert(UISpecialFrames, "TrackMyPathOptions")
end

function TMP:ToggleOptions()
	if not panel then return end
	if panel:IsShown() then panel:Hide() else panel:Show() end
end
