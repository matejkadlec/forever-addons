# WoW: Forever - API Notes

Findings verified against the `forever` branch of [wow-ui-source](https://github.com/Gethe/wow-ui-source/tree/forever) and the live client (1.60.1).

## Client identity

- WoW: Forever is the internal project **Camelot**: `WOW_PROJECT_ID == WOW_PROJECT_CAMELOT` (`18`)
- `.toc` interface version: `## Interface: 16001`
- It runs the **modern Mainline FrameXML** (retail 12.x API) with `Camelot` overrides, for example `Blizzard_Minimap/Camelot/`
  - In Blizzard `.toc` files, `[Game]` paths resolve to `Camelot` and `[Family]` paths to `Mainline`
  - Game content is vanilla (spells, talents, creature types), the API is modern (`C_Spell`, `C_AddOns`, `C_Minimap`, `Settings`, ...)
- Third-party AddOns use the `_Camelot.toc` (and sometimes `_Forever.toc`) multi-TOC suffix

## Secret values (AddOn restrictions)

- Some API results are **secret values** for AddOn (tainted) code: they can be stored and passed to some widget APIs,
  but comparing them, doing math with them or concatenating them raises a Lua error
  - Using a secret as a table key is allowed, but it makes every lookup in that table return secrets (`SecretWhenLuaTableHasSecretKeys`)
- Always test with `issecretvalue(value)` **before** any comparison, including `== nil`
- `C_Secrets.HasSecretRestrictions()` tells whether the client build uses secrets at all (it does on Forever)
- Restriction states (`Enum.AddOnRestrictionType`): `Combat`, `Encounter`, `ChallengeMode`, `PvPMatch`, `Map`, `Chat`
  - `C_RestrictedActions.IsAddOnRestrictionActive(type)`, event `ADDON_RESTRICTION_STATE_CHANGED`
- Known secret sources:
  - `UnitCastingInfo` / `UnitChannelInfo` for any unit other than the player and their pet
  - Unit identity (`UnitName`, `UnitCreatureType`, ...) of units that are not player-controlled and not in the group
    - Verified in game: `UnitCreatureType("target")` of a mob is **not** secret out of combat, so this applies while a restriction state is active (in-combat secrecy assumed, not yet observed)
    - Check `C_Secrets.ShouldUnitIdentityBeSecret(unit)` or `issecretvalue` at runtime
  - `UnitHealth` (`SecretReturns`), unit stats (`UnitAttackSpeed`, `UnitRangedDamage`) while restricted
  - `C_Spell.GetSpellCooldown` while restricted; its `isActive` and `isOnGCD` fields are never secret
  - Target/focus auras (`C_UnitAuras.*`) while restricted
  - Tooltip data of restricted units (seen in `Logs/General.log`: "attempt to index local 'color' (a secret table value, while execution tainted by ...)")

## No combat log

- `C_CombatLog.GetCurrentEventInfo` is not exposed to AddOns, so `COMBAT_LOG_EVENT_UNFILTERED` is useless
- Use dedicated events instead, for example the swing timer below

## Swing timer

- `PLAYER_SWING(swingDuration, swingType)` with `Enum.PlayerSwingType`: `MainHand = 0`, `OffHand = 1`, `Ranged = 2`
- `PLAYER_SWING_RANGE_UPDATE(swingType, isInRange, checksRange)`
- `C_SwingTimer.EnableRangeCheck(swingType, enable)`, `C_SwingTimer.IsTargetWithinSwingRange(swingType)`
- Blizzard's own implementation: `Blizzard_SwingTimer`

## Minimap tracking

- `C_Minimap.GetNumTrackingTypes()`, `C_Minimap.GetTrackingInfo(index)` returns `{ name, texture, active, type, subType, spellID }`
  - `subType == 1` is Hunter tracking (`HUNTER_TRACKING`)
- `C_Minimap.SetTracking(index, on)` switches tracking (`CastSpellByName` is not available to AddOns)
- Event: `MINIMAP_UPDATE_TRACKING`

## Settings panel (Esc -> Options -> AddOns)

- Canvas pages: `Settings.RegisterCanvasLayoutCategory(frame, name)`, `Settings.RegisterCanvasLayoutSubcategory(parentCategory, frame, name)`, then `Settings.RegisterAddOnCategory(category)` for the top level category
- Optional frame callbacks: `frame.OnRefresh`, `frame.OnDefault` (only reached through "Restore All Defaults"), `frame.OnCommit`
- Canvas pages hide the settings list, including its `Defaults` button, so a canvas panel needs its own button
- `Settings.OpenToCategory(category:GetID())` calls `C_SettingsUtil.OpenSettingsPanel`, which `HasRestrictions`: only call it from a user click and never in combat
- Templates that exist: `UICheckButtonTemplate` (`.Text`, aliased as `.text`), `UIRadioButtonTemplate` (`.text`), `UISliderTemplateWithLabels` (`.Text`, `.Low`, `.High`), `UIPanelButtonTemplate`
- `InterfaceOptionsCheckButtonTemplate` / `OptionsSliderTemplate` only exist in `DeprecatedTemplates.xml`, avoid them

## Chat

- `ChatFrameEditBoxTemplate` has `ignoreArrows="true"`, plain Up/Down never reach the edit box (only Alt + Up/Down)
- Sent lines go through `editBox:AddHistoryLine(text)`, the focused box is `ChatFrameUtil.GetActiveWindow()`

## Minimap / world map

- The minimap has no `SetPlayerTexture` / `SetPlayerTextureHeight`, the engine player arrow cannot be resized
- World map player arrow: `GroupMembersPinTemplate` pins, `pin.dataProvider:GetUnitPinSizesTable().player`, then `pin:SynchronizePinSizes()`

## Misc

- AddOn metadata: `C_AddOns.GetAddOnMetadata(addonName, "Version")`
- New files, new AddOns and `.toc` changes need a **full game restart**, Lua-only changes only `/reload`

## Taint

- Never write fields onto Blizzard frames (for example `SomeBlizzardFrame.RegisterEvent = function() end`) that handle secret data, it taints Blizzard code and causes secret value errors or "AddOn has been blocked from an action" popups
- Use `hooksecurefunc` / `frame:HookScript` instead of replacing Blizzard functions or scripts
- Debugging: Lua errors with stack traces end up in `_forever_/Logs/General.log`; `/console taintLog 1` writes `Logs/taint.log`
