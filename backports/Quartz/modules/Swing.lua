--[[
	Copyright (C) 2006-2007 Nymbia
	Copyright (C) 2010-2017 Hendrik "Nevcairiel" Leppkes < h.leppkes@gmail.com >

	This program is free software; you can redistribute it and/or modify
	it under the terms of the GNU General Public License as published by
	the Free Software Foundation; either version 2 of the License, or
	(at your option) any later version.

	This program is distributed in the hope that it will be useful,
	but WITHOUT ANY WARRANTY; without even the implied warranty of
	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
	GNU General Public License for more details.

	You should have received a copy of the GNU General Public License along
	with this program; if not, write to the Free Software Foundation, Inc.,
	51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
]]
-- Modified 2026-11 for the unofficial WoW: Forever port: rewritten on PLAYER_SWING (see below).

--[[
	WoW: Forever port of the Swing module.

	The original module timed swings from the combat log, which addons cannot read on
	WoW: Forever. This version uses the client's own swing event instead:
	PLAYER_SWING(swingDuration, swingType), the same event the built-in swing timer uses.

	Additions for ranged play (kiting):
	  * Auto Shot wind-up zone: the last part of the ranged timer is marked, that is the
	    part in which you have to stand still for the next Auto Shot to fire.
	  * When the ranged timer runs out while Auto Shot is still on (e.g. you kept moving),
	    the bar stays full until the shot fires instead of disappearing.
	  * Optional out-of-range indication (C_SwingTimer range check).
]]
local Quartz3 = LibStub("AceAddon-3.0"):GetAddon("Quartz3")
local L = LibStub("AceLocale-3.0"):GetLocale("Quartz3")

local MODNAME = "Swing"
local Swing = Quartz3:NewModule(MODNAME, "AceEvent-3.0")
local Player = Quartz3:GetModule("Player")

local media = LibStub("LibSharedMedia-3.0")

----------------------------
-- Upvalues
local CreateFrame, GetTime, UIParent = CreateFrame, GetTime, UIParent
local UnitAttackSpeed, UnitRangedDamage = UnitAttackSpeed, UnitRangedDamage
local unpack, pcall, select, type, min = unpack, pcall, select, type, math.min
local IsSecret = Quartz3.IsSecret

local SwingType = Enum and Enum.PlayerSwingType or {}
local SWING_MAINHAND = SwingType.MainHand or 0
local SWING_OFFHAND = SwingType.OffHand or 1
local SWING_RANGED = SwingType.Ranged or 2

-- a finished ranged bar stays full (waiting for the shot) at most this long
local RANGED_HOLD_TIME = 10
-- alpha multiplier of the bar while the target is out of range
local OUT_OF_RANGE_ALPHA = 0.4

local swingbar, swingbar_width, swingstatusbar, remainingtext, durationtext, windupzone
local swingtype -- swing type currently shown, nil when idle
local starttime, duration
local autorepeat -- Auto Shot (or wand) is turned on
local outofrange = {} -- [swingType] = true when the target is out of range
local rangeCheckEnabled

local db, getOptions

local defaults = {
	profile = {
		barcolor = {1, 1, 1},
		rangedcolor = {0.55, 0.85, 1},
		swingalpha = 1,
		swingheight = 4,
		swingposition = "top",
		swinggap = -4,

		durationtext = true,
		remainingtext = true,

		showmelee = true,
		showranged = true,

		windup = true,
		windupduration = 0.5,
		windupcolor = {1, 0.1, 0.1, 0.75},

		rangecheck = true,

		x = 300,
		y = 300,
	}
}

local function OnUpdate()
	if not starttime then
		return swingbar:Hide()
	end
	local spent = GetTime() - starttime
	if spent >= duration then
		-- Auto Shot still on but the shot did not fire yet (moving, out of range, ...):
		-- keep the bar full until the next shot instead of hiding it
		if swingtype == SWING_RANGED and autorepeat and spent < duration + RANGED_HOLD_TIME then
			swingstatusbar:SetValue(1)
			remainingtext:SetText("0.0")
			return
		end
		starttime, swingtype = nil, nil
		return swingbar:Hide()
	end
	remainingtext:SetFormattedText("%.1f", duration - spent)
	swingstatusbar:SetValue(spent / duration)
end

local function OnHide()
	swingbar:SetScript("OnUpdate", nil)
end

local function OnShow()
	swingbar:SetScript("OnUpdate", OnUpdate)
end

-- current weapon speed for a swing type, nil if unknown or hidden from addons
local function GetEquippedSwingDuration(swingType)
	local ok, speed
	if swingType == SWING_RANGED then
		ok, speed = pcall(function() return select(3, UnitAttackSpeed("player")) end)
		if ok and not IsSecret(speed) and not speed and UnitRangedDamage then
			ok, speed = pcall(UnitRangedDamage, "player")
		end
	else
		ok, speed = pcall(UnitAttackSpeed, "player")
	end
	if not ok or IsSecret(speed) or type(speed) ~= "number" or speed <= 0 then
		return nil
	end
	return speed
end

local function SetRangeCheck(enable)
	if not (C_SwingTimer and C_SwingTimer.EnableRangeCheck) then return end
	if not enable and not rangeCheckEnabled then return end
	-- don't switch it off under the built-in swing timer's feet
	if not enable and GetCVarBool and GetCVarBool("showSwingTimer") then
		rangeCheckEnabled = nil
		return
	end
	pcall(C_SwingTimer.EnableRangeCheck, SWING_MAINHAND, enable)
	pcall(C_SwingTimer.EnableRangeCheck, SWING_RANGED, enable)
	rangeCheckEnabled = enable or nil
end

function Swing:OnInitialize()
	self.db = Quartz3.db:RegisterNamespace(MODNAME, defaults)
	db = self.db.profile

	self:SetEnabledState(Quartz3:GetModuleEnabled(MODNAME))
	Quartz3:RegisterModuleOptions(MODNAME, getOptions, L["Swing"])
end

function Swing:OnEnable()
	self:RegisterEvent("PLAYER_SWING")
	self:RegisterEvent("PLAYER_SWING_RANGE_UPDATE")
	self:RegisterEvent("PLAYER_TARGET_CHANGED")
	self:RegisterEvent("UNIT_ATTACK_SPEED")
	self:RegisterEvent("UNIT_RANGEDDAMAGE", "UNIT_ATTACK_SPEED")
	-- Blizzard's own swing timer shares the client-wide range check switch, re-assert it
	self:RegisterEvent("PLAYER_REGEN_DISABLED", "ReassertRangeCheck")
	-- fired when Auto Shot (or wand) is turned on/off
	self:RegisterEvent("START_AUTOREPEAT_SPELL")
	self:RegisterEvent("STOP_AUTOREPEAT_SPELL")

	if not swingbar then
		swingbar = CreateFrame("Frame", "Quartz3SwingBar", UIParent, "BackdropTemplate")
		swingbar:SetFrameStrata("HIGH")
		swingbar:SetScript("OnShow", OnShow)
		swingbar:SetScript("OnHide", OnHide)
		swingbar:SetMovable(true)
		swingbar:RegisterForDrag("LeftButton")
		swingbar:SetClampedToScreen(true)

		swingstatusbar = Quartz3:CreateStatusBar(nil, swingbar)

		windupzone = swingstatusbar:CreateTexture(nil, "OVERLAY")
		windupzone:Hide()

		durationtext = swingstatusbar:CreateFontString(nil, "OVERLAY")
		remainingtext = swingstatusbar:CreateFontString(nil, "OVERLAY")
		swingbar:Hide()
	end
	-- Auto Shot may already be on (e.g. after /reload)
	local ok, current = pcall(C_Spell.IsCurrentSpell, 75)
	autorepeat = (ok and not IsSecret(current) and current) or nil
	self:ApplySettings()
end

function Swing:ReassertRangeCheck()
	if db.rangecheck then
		SetRangeCheck(true)
	end
end

function Swing:OnDisable()
	swingbar:Hide()
	starttime, swingtype = nil, nil
	SetRangeCheck(false)
end

function Swing:PLAYER_SWING(event, swingDuration, swingType)
	if IsSecret(swingDuration) or IsSecret(swingType) then return end
	if swingType == SWING_OFFHAND then return end
	if swingType == SWING_RANGED then
		if not db.showranged then return end
	elseif not db.showmelee then
		return
	end
	if type(swingDuration) ~= "number" or swingDuration <= 0 then
		swingDuration = GetEquippedSwingDuration(swingType)
		if not swingDuration then return end
	end
	self:StartSwing(swingType, swingDuration)
end

function Swing:StartSwing(swingType, swingDuration)
	swingtype = swingType
	duration = swingDuration
	starttime = GetTime()

	durationtext:SetFormattedText("%.1f", duration)
	remainingtext:SetFormattedText("%.1f", duration)
	swingstatusbar:SetValue(0)
	self:UpdateBarColor()
	self:UpdateWindup()
	self:UpdateRangeVisual()
	swingbar:Show()
end

-- attack speed changed mid-swing (haste buff, Rapid Fire, ...): keep the progress, rescale the rest
function Swing:UNIT_ATTACK_SPEED(event, unit)
	if unit ~= "player" or not starttime or not swingtype then return end
	local newDuration = GetEquippedSwingDuration(swingtype)
	if not newDuration or newDuration == duration then return end
	local now = GetTime()
	local spent = now - starttime
	if spent >= duration then return end
	local progress = spent / duration
	duration = newDuration
	starttime = now - progress * newDuration
	durationtext:SetFormattedText("%.1f", duration)
	self:UpdateWindup()
end

function Swing:START_AUTOREPEAT_SPELL()
	autorepeat = true
	self:ReassertRangeCheck()
end

function Swing:STOP_AUTOREPEAT_SPELL()
	autorepeat = nil
	-- drop a ranged bar that was only waiting for the next shot
	if swingtype == SWING_RANGED and starttime and GetTime() - starttime >= duration then
		starttime, swingtype = nil, nil
		swingbar:Hide()
	end
end

function Swing:PLAYER_SWING_RANGE_UPDATE(event, swingType, isInRange, checksRange)
	if IsSecret(swingType) or IsSecret(isInRange) or IsSecret(checksRange) then return end
	outofrange[swingType] = (checksRange and not isInRange) or nil
	self:UpdateRangeVisual()
end

function Swing:PLAYER_TARGET_CHANGED()
	self:ReassertRangeCheck()
	if not (C_SwingTimer and C_SwingTimer.IsTargetWithinSwingRange) then return end
	for _, t in ipairs({SWING_MAINHAND, SWING_RANGED}) do
		local ok, inRange = pcall(C_SwingTimer.IsTargetWithinSwingRange, t)
		-- nil means no range check was possible, it must not be treated as out of range
		if not ok or IsSecret(inRange) then
			outofrange[t] = nil
		else
			outofrange[t] = (inRange == false) or nil
		end
	end
	self:UpdateRangeVisual()
end

function Swing:UpdateBarColor()
	local color = (swingtype == SWING_RANGED) and db.rangedcolor or db.barcolor
	swingstatusbar:SetStatusBarColor(unpack(color))
end

function Swing:UpdateWindup()
	if not windupzone then return end
	if swingtype ~= SWING_RANGED or not db.windup or not duration or duration <= 0 then
		return windupzone:Hide()
	end
	local width = swingbar_width * min(db.windupduration / duration, 1)
	windupzone:ClearAllPoints()
	windupzone:SetPoint("TOPRIGHT", swingstatusbar, "TOPRIGHT")
	windupzone:SetPoint("BOTTOMRIGHT", swingstatusbar, "BOTTOMRIGHT")
	windupzone:SetWidth(width)
	windupzone:SetColorTexture(unpack(db.windupcolor))
	windupzone:Show()
end

function Swing:UpdateRangeVisual()
	if not swingstatusbar then return end
	local isOutOfRange = db.rangecheck and swingtype and outofrange[swingtype]
	local r, g, b = 1, 1, 1
	if isOutOfRange then
		r, g, b = 1, 0.1, 0.1
	end
	durationtext:SetTextColor(r, g, b)
	remainingtext:SetTextColor(r, g, b)
	swingstatusbar:SetAlpha(isOutOfRange and OUT_OF_RANGE_ALPHA or 1)
end

function Swing:ApplySettings()
	db = self.db.profile
	if swingbar and self:IsEnabled() then
		swingbar:ClearAllPoints()
		swingbar:SetHeight(db.swingheight)
		swingbar_width = Player.Bar:GetWidth() - 8
		swingbar:SetWidth(swingbar_width)
		swingbar:SetBackdrop({bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", tile = true, tileSize = 16})
		swingbar:SetBackdropColor(0,0,0)
		swingbar:SetAlpha(db.swingalpha)
		swingbar:SetScale(Player.db.profile.scale)

		if db.swingposition == "bottom" then
			swingbar:SetPoint("TOP", Player.Bar, "BOTTOM", 0, -1 * db.swinggap)
		elseif db.swingposition == "top" then
			swingbar:SetPoint("BOTTOM", Player.Bar, "TOP", 0, db.swinggap)
		else -- L["Free"]
			swingbar:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", db.x, db.y)
		end

		swingstatusbar:SetAllPoints(swingbar)
		swingstatusbar:SetStatusBarTexture(media:Fetch("statusbar", Player.db.profile.texture))
		swingstatusbar:SetMinMaxValues(0, 1)
		self:UpdateBarColor()

		if db.durationtext then
			durationtext:Show()
			durationtext:ClearAllPoints()
			durationtext:SetPoint("BOTTOMLEFT", swingbar, "BOTTOMLEFT")
			durationtext:SetJustifyH("LEFT")
		else
			durationtext:Hide()
		end
		durationtext:SetFont(media:Fetch("font", Player.db.profile.font), 9)
		durationtext:SetShadowColor( 0, 0, 0, 1)
		durationtext:SetShadowOffset( 0.8, -0.8 )
		durationtext:SetNonSpaceWrap(false)
		durationtext:SetWidth(swingbar_width)

		if db.remainingtext then
			remainingtext:Show()
			remainingtext:ClearAllPoints()
			remainingtext:SetPoint("BOTTOMRIGHT", swingbar, "BOTTOMRIGHT")
			remainingtext:SetJustifyH("RIGHT")
		else
			remainingtext:Hide()
		end
		remainingtext:SetFont(media:Fetch("font", Player.db.profile.font), 9)
		remainingtext:SetShadowColor( 0, 0, 0, 1)
		remainingtext:SetShadowOffset( 0.8, -0.8 )
		remainingtext:SetNonSpaceWrap(false)
		remainingtext:SetWidth(swingbar_width)

		SetRangeCheck(db.rangecheck)
		if not db.rangecheck then
			wipe(outofrange)
		end
		self:UpdateWindup()
		self:UpdateRangeVisual()
	end
end

do
	local locked = true
	local function nothing()
	end
	local function dragstart()
		swingbar:StartMoving()
	end
	local function dragstop()
		db.x = swingbar:GetLeft()
		db.y = swingbar:GetBottom()
		swingbar:StopMovingOrSizing()
	end

	local function setOpt(info, value)
		db[info[#info]] = value
		Swing:ApplySettings()
	end

	local function getOpt(info)
		return db[info[#info]]
	end

	local function getColor(info)
		return unpack(getOpt(info))
	end

	local function setColor(info, r, g, b, a)
		setOpt(info, {r, g, b, a})
	end

	local function windupDisabled()
		return not db.windup or not db.showranged
	end

	local options
	function getOptions()
		options = options or {
		type = "group",
		name = L["Swing"],
		desc = L["Swing"],
		get = getOpt,
		set = setOpt,
		order = 600,
		args = {
			toggle = {
				type = "toggle",
				name = L["Enable"],
				desc = L["Enable"],
				get = function()
					return Quartz3:GetModuleEnabled(MODNAME)
				end,
				set = function(info, v)
					Quartz3:SetModuleEnabled(MODNAME, v)
				end,
				order = 100,
			},
			showmelee = {
				type = "toggle",
				name = "Melee Swings",
				desc = "Show the timer for melee (main hand) swings",
				order = 101,
			},
			showranged = {
				type = "toggle",
				name = "Ranged Swings",
				desc = "Show the timer for Auto Shot and wand shots",
				order = 102,
			},
			barcolor = {
				type = "color",
				name = L["Bar Color"],
				desc = L["Set the color of the swing timer bar"],
				get = getColor,
				set = setColor,
				order = 103,
			},
			rangedcolor = {
				type = "color",
				name = "Ranged Bar Color",
				desc = "Set the color of the swing timer bar for Auto Shot and wand shots",
				get = getColor,
				set = setColor,
				order = 103.5,
			},
			swingheight = {
				type = "range",
				name = L["Height"],
				desc = L["Set the height of the swing timer bar"],
				min = 1, max = 20, step = 1,
				order = 104,
			},
			swingalpha = {
				type = "range",
				name = L["Alpha"],
				desc = L["Set the alpha of the swing timer bar"],
				min = 0.05, max = 1, bigStep = 0.05,
				isPercent = true,
				order = 105,
			},
			swingposition = {
				type = "select",
				name = L["Bar Position"],
				desc = L["Set the position of the swing timer bar"],
				values = {["top"] = L["Top"], ["bottom"] = L["Bottom"], ["free"] = L["Free"]},
				order = 106,
			},
			lock = {
				type = "toggle",
				name = L["Lock"],
				desc = L["Toggle Cast Bar lock"],
				get = function()
					return locked
				end,
				set = function(info, v)
					if v then
						swingbar.Hide = nil
						swingbar:EnableMouse(false)
						swingbar:SetScript("OnDragStart", nil)
						swingbar:SetScript("OnDragStop", nil)
						if not starttime then
							swingbar:Hide()
						end
					else
						swingbar:Show()
						swingbar:EnableMouse(true)
						swingbar:SetScript("OnDragStart", dragstart)
						swingbar:SetScript("OnDragStop", dragstop)
						swingbar:SetAlpha(1)
						swingbar.Hide = nothing
					end
					locked = v
				end,
				hidden = function()
					return db.swingposition ~= "free"
				end,
				order = 107,
			},
			x = {
				type = "range",
				name = L["X"],
				desc = L["Set an exact X value for this bar's position."],
				min = -2560, max = 2560, bigStep = 1,
				order = 108,
				hidden = function()
					return db.swingposition ~= "free"
				end,
			},
			y = {
				type = "range",
				name = L["Y"],
				desc = L["Set an exact Y value for this bar's position."],
				min = -2560,
				max = 2560,
				order = 108,
				hidden = function()
					return db.swingposition ~= "free"
				end,
			},
			swinggap = {
				type = "range",
				name = L["Gap"],
				desc = L["Tweak the distance of the swing timer bar from the cast bar"],
				min = -35, max = 35, step = 1,
				order = 108,
			},
			durationtext = {
				type = "toggle",
				name = L["Duration Text"],
				desc = L["Toggle display of text showing your total swing time"],
				order = 109,
			},
			remainingtext = {
				type = "toggle",
				name = L["Remaining Text"],
				desc = L["Toggle display of text showing the time remaining until you can swing again"],
				order = 110,
			},
			rangecheck = {
				type = "toggle",
				name = "Out of Range Warning",
				desc = "Dim the bar and color its text red while your target is out of auto attack / Auto Shot range",
				order = 111,
			},
			windupheader = {
				type = "header",
				name = "Auto Shot Wind-up",
				order = 120,
			},
			windupdesc = {
				type = "description",
				name = "Marks the end of the ranged swing timer. Auto Shot only fires if you stand still during this part, so you can move freely until the bar reaches the marked zone.",
				order = 121,
			},
			windup = {
				type = "toggle",
				name = "Show Wind-up Zone",
				desc = "Mark the part of the Auto Shot timer in which you have to stand still",
				order = 122,
			},
			windupduration = {
				type = "range",
				name = "Wind-up Length",
				desc = "Length of the marked zone in seconds (Auto Shot wind-up is 0.5 sec)",
				min = 0.1, max = 1.5, step = 0.05,
				disabled = windupDisabled,
				order = 123,
			},
			windupcolor = {
				type = "color",
				name = "Wind-up Zone Color",
				desc = "Color of the marked zone",
				hasAlpha = true,
				get = getColor,
				set = setColor,
				disabled = windupDisabled,
				order = 124,
			},
		},
	}
	return options
	end
end
