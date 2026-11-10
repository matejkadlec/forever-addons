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

## Range checks

- `C_Spell.IsSpellInRange(spell, unit)` returns `true` / `false` / `nil` (`nil` when the range check is invalid, per the API docs); not flagged as secret; accepts spell IDs or names (that a name matches the rank you know is not yet verified in game)
- `C_Spell.GetSpellInfo(spell)` returns a table with `minRange` / `maxRange`
- `CheckInteractDistance`, `C_Item.IsItemInRange` exist; [LibRangeCheck-3.0](https://github.com/WeakAuras/LibRangeCheck-3.0) supports Forever since v38 (`isForever`), v39 also handles secret GUIDs
  - Its distance steps for hostile units on Forever/Era come from item range checks: 5, 10, 15, 20, 25, 30, 35, 40, 45, 100 yards (plus class spells such as Auto Shot); the interact distance checks (8 and 28 yards) are only used while no item data is cached, for example right after login
  - When every check fails it returns the largest cached step and `nil`, e.g. `(100, nil)` or `(45, nil)` while the 100 yard item is not cached; in combat it only skips item checks on units you cannot attack (not yet verified in game)
  - With secret GUIDs it caches by unit token, so pass `maxCacheAge = 0` to `GetRange` right after a target change
- `UnitCanAttack`, `UnitIsDeadOrGhost` are not flagged as secret
- `Region:SetAlphaFromBoolean(value, alphaIfTrue, alphaIfFalse)` accepts secret booleans (shows/hides a region based on a secret result)

## Nameplates

- `C_NamePlate.GetNamePlateForUnit(unit)` (the `"target"` unit token is used for the target's plate), events `NAME_PLATE_UNIT_ADDED` / `NAME_PLATE_UNIT_REMOVED` (the plate is still returned while `REMOVED` is dispatched)
- Blizzard's health bar: `plate.UnitFrame.HealthBarsContainer.healthBar`; the Camelot level frame sits to the right of it
- Plater keeps its own unit frame on `plate.unitFrame` with `plate.unitFrame.healthBar`; its level text is anchored above the top right corner of the health bar by default

## Spell casts

- `UNIT_SPELLCAST_SUCCEEDED` (`unitTarget, castGUID, spellID, castBarID`) is flagged `SecretWhenUnitSpellCastRestricted`; `C_Secrets.ShouldUnitSpellCastingBeSecret(unit)` / `ShouldUnitSpellCastBeSecret(unit, spell)` tell when; guard `spellID` with `issecretvalue` (ForeverHawkTimer counts such casts in `/fht debug`, not yet verified whether the player's own casts are ever secret)
- Register it with `frame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")` for the player's own casts
- `C_Spell.GetSpellName(spellID)` / `C_Spell.GetSpellTexture(spellID)` take secret arguments (`AllowedWhenTainted`) and return nothing for unknown spells
- Forever-only spells use new high IDs (game data, not in wow-ui-source; from the in-game tooltip and warcraft.wiki.gg): **Summon Hawk** (Beast Mastery talent, 4 ranks, added in 1.60.1) is 1293241 (rank 1) and 1293527 (rank 4), ranks 2 and 3 are unknown, so match the spell name; the hawk stays 18 sec and only 2 hawks can be active at once (tooltip)

## Edit Mode

- `EventRegistry:RegisterCallback("EditMode.Enter" / "EditMode.Exit", func, owner)` (used by Blizzard's Camelot `MainMenuBarEndCaps.lua`); the CallbackRegistry runs every callback through `securecallfunction`, so addon callbacks do not taint Edit Mode
- `EditModeManagerFrame:IsEditModeActive()` tells whether Edit Mode is open; it stays true while Blizzard hides Edit Mode for a moment without leaving it (`CheckHideAndLockEditMode`: Quick Keybind mode, Action Bar / Raid Frame settings, Cooldown Viewer), which fires no `EditMode.Exit`, so also follow `EditModeManagerFrame:IsShown()` (`HookScript` its `OnShow` / `OnHide`)
- AddOn frames cannot join Blizzard's Edit Mode systems; ForeverHawkTimer shows its own drag overlay while Edit Mode is open, with Blizzard's look: a `NineSliceCodeTemplate` frame and `NineSliceUtil.ApplyLayout(frame, layout, "editmode-actionbar-highlight")` (`"editmode-actionbar-selected"` for the yellow look) with a copy of the local `EditModeSystemSelectionLayout` from `Blizzard_EditMode/Shared/EditModeSystemTemplates.lua`
- Movable addon frames: `SetMovable(true)`, `SetClampedToScreen(true)`, `SetDontSavePosition(true)` (keeps the position out of the client's own layout file, the AddOn saves it), `StartMoving()` / `StopMovingOrSizing()`

## Settings panel (Esc -> Options -> AddOns)

- Canvas pages: `Settings.RegisterCanvasLayoutCategory(frame, name)`, `Settings.RegisterCanvasLayoutSubcategory(parentCategory, frame, name)`, then `Settings.RegisterAddOnCategory(category)` for the top level category
- Optional frame callbacks: `frame.OnRefresh`, `frame.OnDefault` (only reached through "Restore All Defaults"), `frame.OnCommit`
- Canvas pages hide the settings list, including its `Defaults` button, so a canvas panel needs its own button
- `Settings.OpenToCategory(category:GetID())` calls `C_SettingsUtil.OpenSettingsPanel`, which `HasRestrictions`: only call it from a user click and never in combat
- Templates that exist: `UICheckButtonTemplate` (`.Text`, aliased as `.text`), `UIRadioButtonTemplate` (`.text`), `UISliderTemplateWithLabels` (`.Text`, `.Low`, `.High`), `UIPanelButtonTemplate`
- `InterfaceOptionsCheckButtonTemplate` / `OptionsSliderTemplate` only exist in `DeprecatedTemplates.xml`, avoid them
- Color picker: `ColorPickerFrame:SetupColorPickerAndShow({ r, g, b, hasOpacity, swatchFunc, cancelFunc })`, read the color with `ColorPickerFrame:GetColorRGB()`

## Chat

- `ChatFrameEditBoxTemplate` has `ignoreArrows="true"`, plain Up/Down never reach the edit box (only Alt + Up/Down)
- Sent lines go through `editBox:AddHistoryLine(text)`, the focused box is `ChatFrameUtil.GetActiveWindow()`

## Minimap / world map

- The minimap has no `SetPlayerTexture` / `SetPlayerTextureHeight`, the engine player arrow cannot be resized
- World map player arrow: `GroupMembersPinTemplate` pins, `pin.dataProvider:GetUnitPinSizesTable().player`, then `pin:SynchronizePinSizes()`

## AddOn list

- `Blizzard_AddOnList/AddonList.lua` reads these `.toc` fields:
  - `## IconTexture:` (texture path or file ID) or `## IconAtlas:` puts an icon before the title, without them the list shows `INV_Misc_QuestionMark`
  - `## Category:` puts AddOns under one collapsible category header (categories are sorted alphabetically above the uncategorized AddOns, the header's right-click menu has Enable all / Disable all / Reset to default); no AddOn depends on another for this
  - `## Group:` nests an AddOn under another *installed* AddOn whose folder name matches exactly (seen in game with the multi-part ForeverArtisan and its "Core"); the client sets it automatically for AddOns with similar names and dependencies, children with a missing parent fall back to the top level outside any category
- SavedVariables files are named after the AddOn folder (`WTF/Account/<account>/SavedVariables/<AddOnName>.lua`, seen on the maintainer's client), so a renamed AddOn starts with a new file and the old one stays unused; the variable name inside must match the `## SavedVariables:` name too

## Misc

- AddOn metadata: `C_AddOns.GetAddOnMetadata(addonName, "Version")`
- New files, new AddOns and `.toc` changes need a **full game restart**, Lua-only changes only `/reload`

## Taint

- Never write fields onto Blizzard frames (for example `SomeBlizzardFrame.RegisterEvent = function() end`) that handle secret data, it taints Blizzard code and causes secret value errors or "AddOn has been blocked from an action" popups
- Use `hooksecurefunc` / `frame:HookScript` instead of replacing Blizzard functions or scripts
- Debugging: Lua errors with stack traces end up in `_forever_/Logs/General.log`; `/console taintLog 1` writes `Logs/taint.log`
