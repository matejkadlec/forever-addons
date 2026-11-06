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
-- Modified 2026-11 for the unofficial WoW: Forever port: GCD via the GCD spell (61304) with a fallback when cooldowns are secret.
local Quartz3 = LibStub("AceAddon-3.0"):GetAddon("Quartz3")
local L = LibStub("AceLocale-3.0"):GetLocale("Quartz3")

local MODNAME = "GCD"
local GCD = Quartz3:NewModule(MODNAME, "AceEvent-3.0")
local Player = Quartz3:GetModule("Player")

----------------------------
-- Upvalues
local CreateFrame, GetTime, UIParent = CreateFrame, GetTime, UIParent
local unpack, pcall = unpack, pcall
local IsSecret = Quartz3.IsSecret

-- "Global Cooldown" helper spell; its cooldown is the GCD itself
local GCD_SPELL = 61304

local gcdbar, gcdbar_width, gcdspark
local starttime, duration, warned

local db, getOptions

local defaults = {
	profile = {
		sparkcolor = {1, 1, 1},
		gcdalpha = 0.9,
		gcdheight = 4,
		gcdposition = "bottom",
		gcdgap = -4,

		deplete = false,

		x = 500,
		y = 300,
	}
}

local function OnUpdate()
	if not starttime then return gcdbar:Hide() end
	gcdspark:ClearAllPoints()
	local perc = (GetTime() - starttime) / duration
	if perc > 1 then
		return gcdbar:Hide()
	else
		if db.deplete then
			gcdspark:SetPoint("CENTER", gcdbar, "LEFT", gcdbar_width * (1-perc), 0)
		else
			gcdspark:SetPoint("CENTER", gcdbar, "LEFT", gcdbar_width * perc, 0)
		end
	end
end

local function OnHide()
	gcdbar:SetScript("OnUpdate", nil)
end

local function OnShow()
	gcdbar:SetScript("OnUpdate", OnUpdate)
end

function GCD:OnInitialize()
	self.db = Quartz3.db:RegisterNamespace(MODNAME, defaults)
	db = self.db.profile

	self:SetEnabledState(Quartz3:GetModuleEnabled(MODNAME))
	Quartz3:RegisterModuleOptions(MODNAME, getOptions, L["GCD"])
end

function GCD:OnEnable()
	--self:RegisterEvent("UNIT_SPELLCAST_SENT","CheckGCD")
	self:RegisterEvent("UNIT_SPELLCAST_START","CheckGCD")
	self:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED","CheckGCD")
	self:RegisterEvent("SPELL_UPDATE_COOLDOWN", "CheckGCD")
	if not gcdbar then
		gcdbar = CreateFrame("Frame", "Quartz3GCDBar", UIParent, "BackdropTemplate")
		gcdbar:SetFrameStrata("HIGH")
		gcdbar:SetScript("OnShow", OnShow)
		gcdbar:SetScript("OnHide", OnHide)
		gcdbar:SetMovable(true)
		gcdbar:RegisterForDrag("LeftButton")
		gcdbar:SetClampedToScreen(true)

		gcdspark = gcdbar:CreateTexture(nil, "ARTWORK")
		gcdbar:Hide()
	end
	self:ApplySettings()
end

function GCD:OnDisable()
	gcdbar:Hide()
end

-- returns start, duration, isActive for a spell cooldown.
-- start/duration are nil when the client hides them from addons (secret values in combat);
-- isActive is never secret.
local function ReadCooldown(spell)
	if C_Spell and C_Spell.GetSpellCooldown then
		local ok, cooldown = pcall(C_Spell.GetSpellCooldown, spell)
		if not ok or not cooldown or IsSecret(cooldown) then return end
		local start, dur, active = cooldown.startTime, cooldown.duration, cooldown.isActive
		if IsSecret(active) then active = nil end
		if IsSecret(start) or IsSecret(dur) then
			return nil, nil, active
		end
		return start, dur, active
	elseif GetSpellCooldown then
		local start, dur = GetSpellCooldown(spell)
		return start, dur, dur and dur > 0
	end
end

-- vanilla GCD: 1 sec for energy users (rogue, cat form), 1.5 sec for everyone else
local function FallbackGCDDuration()
	local powerType = UnitPowerType("player")
	if not IsSecret(powerType) and powerType == 3 then -- Enum.PowerType.Energy
		return 1
	end
	return 1.5
end

local function ShowGCD(start, dur)
	starttime = start
	duration = dur
	gcdbar:Show()
end

-- how close to its end an approximate GCD bar may be restarted by the next GCD
local RESTART_WINDOW = 0.25

function GCD:CheckGCD(event, ...)
	local unit, guid, spell = ...
	if event ~= "SPELL_UPDATE_COOLDOWN" and unit ~= "player" then return end
	-- SPELL_UPDATE_COOLDOWN payload: spellID, baseSpellID, category, startRecoveryCategory
	local startRecoveryCategory = nil
	if event == "SPELL_UPDATE_COOLDOWN" then
		startRecoveryCategory = select(4, ...)
		if IsSecret(startRecoveryCategory) then startRecoveryCategory = nil end
	end

	-- 1) the GCD helper spell, exact when readable
	local start, dur, active = ReadCooldown(GCD_SPELL)
	if start and dur then
		if dur > 0 and dur <= 1.5 then
			ShowGCD(start, dur)
		end
		return
	elseif active then
		-- the GCD is running but its timing is hidden from addons (in combat);
		-- approximate it, unless a GCD bar is already running: restart only for a new
		-- GCD-triggering cast or when the running bar is about to end (queued spells)
		local now = GetTime()
		local running = starttime and duration and now < starttime + duration - RESTART_WINDOW
		if not running or (startRecoveryCategory ~= nil and now > starttime + RESTART_WINDOW) then
			ShowGCD(now, FallbackGCDDuration())
		end
		return
	elseif active == false then
		return
	end

	-- 2) GCD helper spell unknown on this client: the original per-spell check
	if spell and event ~= "SPELL_UPDATE_COOLDOWN" then
		start, dur = ReadCooldown(spell)
		if start and dur and dur > 0 and dur <= 1.5 then
			ShowGCD(start, dur)
		end
	end
end

function GCD:ApplySettings()
	db = self.db.profile
	if gcdbar and self:IsEnabled() then
		gcdbar:ClearAllPoints()
		gcdbar:SetHeight(db.gcdheight)
		gcdbar_width = Player.Bar:GetWidth() - 8
		gcdbar:SetWidth(gcdbar_width)
		gcdbar:SetBackdrop({bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", tile = true, tileSize = 16})
		gcdbar:SetBackdropColor(0,0,0)
		gcdbar:SetAlpha(db.gcdalpha)
		gcdbar:SetScale(Player.db.profile.scale)
		if db.gcdposition == "bottom" then
			gcdbar:SetPoint("TOP", Player.Bar, "BOTTOM", 0, -1 * db.gcdgap)
		elseif db.gcdposition == "top" then
			gcdbar:SetPoint("BOTTOM", Player.Bar, "TOP", 0, db.gcdgap)
		else -- L["Free"]
			gcdbar:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", db.x, db.y)
		end

		gcdspark:SetTexture("Interface\\CastingBar\\UI-CastingBar-Spark")
		gcdspark:SetVertexColor(unpack(db.sparkcolor))
		gcdspark:SetBlendMode("ADD")
		gcdspark:SetWidth(25)
		gcdspark:SetHeight(db.gcdheight*2.5)
	end
end

do
	local locked = true
	local function nothing()
	end
	local function dragstart()
		gcdbar:StartMoving()
	end
	local function dragstop()
		db.x = gcdbar:GetLeft()
		db.y = gcdbar:GetBottom()
		gcdbar:StopMovingOrSizing()
	end

	local function hiddennofree()
		return db.gcdposition ~= "free"
	end

	local function setOpt(info, value)
		db[info[#info]] = value
		GCD:ApplySettings()
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

	local options
	function getOptions()
		if not options then
			options = {
				type = "group",
				name = L["Global Cooldown"],
				order = 600,
				get = getOpt,
				set = setOpt,
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
					sparkcolor = {
						type = "color",
						name = L["Spark Color"],
						desc = L["Set the color of the GCD bar spark"],
						get = getColor,
						set = setColor,
						order = 103,
					},
					gcdheight = {
						type = "range",
						name = L["Height"],
						desc = L["Set the height of the GCD bar"],
						min = 1, max = 30, step = 1,
						order = 104,
					},
					gcdalpha = {
						type = "range",
						name = L["Alpha"],
						desc = L["Set the alpha of the GCD bar"],
						min = 0.05, max = 1, bigStep = 0.05,
						isPercent = true,
						order = 105,
					},
					gcdposition = {
						type = "select",
						name = L["Bar Position"],
						desc = L["Set the position of the GCD bar"],
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
								gcdbar.Hide = nil
								gcdbar:EnableMouse(false)
								gcdbar:SetScript("OnDragStart", nil)
								gcdbar:SetScript("OnDragStop", nil)
								gcdbar:Hide()
							else
								gcdbar:Show()
								gcdbar:EnableMouse(true)
								gcdbar:SetScript("OnDragStart", dragstart)
								gcdbar:SetScript("OnDragStop", dragstop)
								gcdbar:SetAlpha(1)
								gcdbar.Hide = nothing
							end
							locked = v
						end,
						hidden = hiddennofree,
						order = 107,
					},
					x = {
						type = "range",
						name = L["X"],
						desc = L["Set an exact X value for this bar's position."],
						min = 0, max = 2560, step = 1,
						order = 108,
						hidden = hiddennofree,
					},
					y = {
						type = "range",
						name = L["Y"],
						desc = L["Set an exact Y value for this bar's position."],
						min = 0, max = 1600, step = 1,
						order = 108,
						hidden = hiddennofree,
					},
					gcdgap = {
						type = "range",
						name = L["Gap"],
						desc = L["Tweak the distance of the GCD bar from the cast bar"],
						min = -35, max = 35, step = 1,
						order = 109,
					},
					deplete = {
						type = "toggle",
						name = L["Deplete"],
						desc = L["Reverses the direction of the GCD spark, causing it to move right-to-left"],
						order = 110,
					},
				},
			}
		end
		return options
	end
end
