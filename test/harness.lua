--[[ Minimal WoW 3.3.5a API stub so the data model can be exercised outside the
     game. Only covers what Trail.lua and Config.lua touch. ]]

_G.DEFAULT_CHAT_FRAME = { AddMessage = function(self, m) print(m) end }

local fakeTime = 0
function _G.GetTime() return fakeTime end
function advanceTime(d) fakeTime = fakeTime + d end
function setTime(t) fakeTime = t end

-- Frame stub: records scripts so we can fire them manually.
local function newFrame()
	local f = {}
	f.scripts = {}
	f.children = {}
	f.shown = true
	function f:SetScript(k, fn) self.scripts[k] = fn end
	function f:HookScript(k, fn) self.scripts["hook_" .. k] = fn end
	function f:GetScript(k) return self.scripts[k] end
	function f:RegisterEvent() end
	function f:UnregisterEvent() end
	-- Record the offsets so tests can assert on placement. The real client
	-- signature is SetPoint(point, relativeTo, relativePoint, x, y), and the
	-- addon always uses that 5-argument form.
	function f:SetPoint(point, relativeTo, relativePoint, x, y)
		self.px, self.py = x, y
	end
	function f:ClearAllPoints() end
	function f:SetAllPoints() end
	function f:SetWidth(v) self.w = v end
	function f:SetHeight(v) self.h = v end
	function f:GetWidth() return self.w or 1002 end
	function f:GetHeight() return self.h or 668 end
	function f:Show() self.shown = true end
	function f:Hide() self.shown = false end
	function f:IsShown() return self.shown end
	function f:SetFrameLevel(v) self.level = v end
	function f:GetFrameLevel() return self.level or 1 end
	function f:SetScale() end
	function f:GetZoom() return 3 end
	function f:SetBackdrop() end
	function f:SetMovable() end
	function f:EnableMouse() end
	function f:RegisterForDrag() end
	function f:SetMinMaxValues() end
	function f:SetValueStep() end
	function f:SetValue() end
	function f:SetChecked() end
	function f:GetChecked() return false end
	function f:SetText() end
	function f:SetTexture() end
	function f:SetVertexColor(r,g,b,a) self.vc = {r,g,b,a} end
	function f:SetTexCoord() end
	function f:SetColorRGB() end
	function f:GetColorRGB() return 1,1,1 end
	function f:CreateTexture()
		local t = newFrame()
		t.isTexture = true
		self.children[#self.children+1] = t
		return t
	end
	function f:CreateFontString() return newFrame() end
	function f:StartMoving() end
	function f:StopMovingOrSizing() end
	return f
end
_G.newFrame = newFrame

function _G.CreateFrame(kind, name, parent, tmpl)
	local f = newFrame()
	f.name = name
	if name then _G[name] = f end
	-- OptionsSliderTemplate children the code pokes via _G
	if tmpl == "OptionsSliderTemplate" and name then
		_G[name .. "Low"] = newFrame()
		_G[name .. "High"] = newFrame()
		_G[name .. "Text"] = newFrame()
	end
	if tmpl == "InterfaceOptionsCheckButtonTemplate" and name then
		_G[name .. "Text"] = newFrame()
	end
	function f:GetName() return name end
	return f
end

_G.WorldMapFrame = CreateFrame("Frame", "WorldMapFrame")
_G.WorldMapFrame.shown = false
_G.WorldMapDetailFrame = CreateFrame("Frame", "WorldMapDetailFrame")
_G.WorldMapDetailFrame.w, _G.WorldMapDetailFrame.h = 1002, 668
_G.Minimap = CreateFrame("Frame", "Minimap")
_G.Minimap.w, _G.Minimap.h = 140, 140
_G.UIParent = CreateFrame("Frame", "UIParent")
_G.ColorPickerFrame = CreateFrame("Frame", "ColorPickerFrame")
_G.UISpecialFrames = {}
_G.SlashCmdList = {}
function _G.tinsert(t, v) t[#t+1] = v end

-- Map state, controllable from tests.
local mapAreaID, mapContinent, mapZone = 1, 2, 1
local px, py = 0.5, 0.5
local inInstance = false

function _G.GetCurrentMapAreaID() return mapAreaID end
function _G.GetCurrentMapContinent() return mapContinent end
function _G.GetCurrentMapZone() return mapZone end
function _G.SetMapToCurrentZone() end
function _G.GetPlayerMapPosition(unit) return px, py end
function _G.IsInInstance() return inInstance end
function _G.IsIndoors() return false end
local cvars = { rotateMinimap = "0" }
function _G.GetCVar(k) return cvars[k] or "0" end
function _G.SetCVarStub(k, v) cvars[k] = v end

local facing = 0
function _G.GetPlayerFacing() return facing end
function _G.setFacing(f) facing = f end

-- Minimap zoom is settable so the redraw-skip logic can be exercised.
function _G.setMinimapZoom(z) _G.Minimap.zoom = z end
_G.Minimap.GetZoom = function(self) return self.zoom or 3 end

function setMap(area, continent, zone)
	mapAreaID, mapContinent, mapZone = area, continent, zone
end
function setPos(x, y) px, py = x, y end
function setInstance(v) inInstance = v end
