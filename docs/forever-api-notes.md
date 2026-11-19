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

## Damage meter

- `C_DamageMeter` is Blizzard's built-in meter data (no combat log): `GetAvailableCombatSessions`, `GetCombatSessionFromType/FromID` and `GetCombatSessionSourceFromType/FromID` (the last four are `SecretWhenInCombat`), `IsDamageMeterAvailable()` returns `isAvailable, failureReason`; session types `Overall` 0, `Current` 1, `Expired` 2
- Blizzard's meter window is shown only with the CVar `damageMeterEnabled` on, the meter available and its visibility setting allowing it (`Blizzard_DamageMeter/DamageMeter.lua` `ShouldBeShown`); the checkboxes for `damageMeterEnabled` and `damageMeterResetOnNewInstance` (reset on new instance) are registered in `Blizzard_SettingsDefinitions_Frame/AdvancedOptions.lua`
- In combat the source fields `totalAmount` / `amountPerSecond` and the session `totalAmount` are secret, so AddOns cannot divide them; Blizzard's own meter computes the percentage in secure code (`Blizzard_DamageMeter/DamageMeterEntry.lua`, numbers setting `Complete`)
- Secret-safe display helpers: `AbbreviateNumbers` / `AbbreviateLargeNumbers` / `BreakUpLargeNumbers` take secret numbers (`AllowedWhenTainted`); custom `breakpointData` entries need `abbreviationIsGlobal = false` for raw suffixes, and `CreateAbbreviateConfig(breakpoints)` (call it in `pcall`, it errors on rejected breakpoints) gives a cached `config`; `C_CurveUtil` curves only take secrets from untainted code
- Percentage of two secret numbers without math (Skada port, not yet verified in game): `StatusBar:SetMinMaxValues` / `SetValue` accept secrets (`AllowedWhenTainted`, they add the `BarValue` secret aspect to the bar), and a bar exactly 100 units wide should have a fill texture width equal to the percentage; `GetWidth` is `SecretWhenAnchoringSecret`, so the width is expected to come back secret and only goes to `string.format` for display; Skada uses it only after a self-test with plain numbers shows that the fill width follows `SetValue` immediately
- `FontString:SetFormattedText` takes secret arguments (`AllowedWhenTainted`, adds the `Text` aspect), so it can compose secret names or numbers with other text; Lua's `string.format` is known to work with secret numbers (`%.0f`), for secret strings prefer `SetFormattedText`
- Reported, not verifiable in wow-ui-source: calling `C_DamageMeter.ResetAllCombatSessions()` again in response to a reset (from `DAMAGE_METER_RESET`) can leave the native meter unable to attribute damage until `/reload`, so Blizzard's meter and every addon meter stay empty ([skada#9](https://github.com/zarnivoop/skada/issues/9), fixed in Skada 2.6.2, our backport also skips resets within 2 s of another one)

## Edit Mode

- `EventRegistry:RegisterCallback("EditMode.Enter" / "EditMode.Exit", func, owner)` (used by Blizzard's Camelot `MainMenuBarEndCaps.lua`); the CallbackRegistry runs every callback through `securecallfunction`, so addon callbacks do not taint Edit Mode
- `EditModeManagerFrame:IsEditModeActive()` tells whether Edit Mode is open; it stays true while Blizzard hides Edit Mode for a moment without leaving it (`CheckHideAndLockEditMode`: Quick Keybind mode, Action Bar / Raid Frame settings, Cooldown Viewer), which fires no `EditMode.Exit`, so also follow `EditModeManagerFrame:IsShown()` (`HookScript` its `OnShow` / `OnHide`)
- AddOn frames cannot join Blizzard's Edit Mode systems; ForeverHawkTimer shows its own drag overlay while Edit Mode is open, with Blizzard's look: a `NineSliceCodeTemplate` frame and `NineSliceUtil.ApplyLayout(frame, layout, "editmode-actionbar-highlight")` (`"editmode-actionbar-selected"` for the yellow look) with a copy of the local `EditModeSystemSelectionLayout` from `Blizzard_EditMode/Shared/EditModeSystemTemplates.lua`
- Snapping like Edit Mode: `EditModeManagerFrame:IsSnapEnabled()` is the `Snap to Elements` checkbox; Blizzard's magnetism range is `EditModeMagnetismManager.magnetismRange` (8), compared with `distance * UIParent:GetEffectiveScale()` (`EditModeUtil.lua`, `CheckReplaceMagneticFrameInfo`), and its preview lines are red `Line`s anchored to `UIParent` with `PixelUtil.GetNearestPixelSize(1.5, line:GetEffectiveScale(), 1.5)` thickness in a HIGH strata container above the Edit Mode highlights (`EditModeTemplates.lua`/`.xml` `MagnetismPreviewLineTemplate`, `EditModeManager.xml` `MagnetismPreviewLinesContainer`); ForeverHawkTimer copies this for its center snap
- Movable addon frames: `SetMovable(true)`, `SetClampedToScreen(true)`, `SetDontSavePosition(true)` (keeps the position out of the client's own layout file, the AddOn saves it), `StartMoving()` / `StopMovingOrSizing()`

## Settings panel (Esc -> Options -> AddOns)

- Canvas pages: `Settings.RegisterCanvasLayoutCategory(frame, name)`, `Settings.RegisterCanvasLayoutSubcategory(parentCategory, frame, name)`, then `Settings.RegisterAddOnCategory(category)` for the top level category
- Optional frame callbacks: `frame.OnRefresh`, `frame.OnDefault` (only reached through "Restore All Defaults"), `frame.OnCommit`
- Canvas pages hide the settings list, including its `Defaults` button, so a canvas panel needs its own button
- `Settings.OpenToCategory(category:GetID())` calls `C_SettingsUtil.OpenSettingsPanel`, which `HasRestrictions`: only call it from a user click and never in combat
- Templates that exist: `UICheckButtonTemplate` (`.Text`, aliased as `.text`), `UIRadioButtonTemplate` (`.text`), `UISliderTemplateWithLabels` (`.Text`, `.Low`, `.High`), `UIPanelButtonTemplate`
- `InterfaceOptionsCheckButtonTemplate` / `OptionsSliderTemplate` only exist in `DeprecatedTemplates.xml`, avoid them
- Color picker: `ColorPickerFrame:SetupColorPickerAndShow({ r, g, b, hasOpacity, swatchFunc, cancelFunc })`, read the color with `ColorPickerFrame:GetColorRGB()`
- Input boxes on canvas pages: Settings calls `OnRefresh` on every canvas page while it still has no parent or anchors (0 width), and `EditBox:SetText()` then leaves the box scrolled so the text is invisible until the user types (seen in game with ForeverHawkTimer 1.1.0); call `editBox:SetCursorPosition(0)` after every `SetText` (Blizzard's documented workaround in `Blizzard_AuctionHouseSellFrame.lua`, not yet confirmed in game for our panel; fallback: set the text again one frame later)

## Chat

- `ChatFrameEditBoxTemplate` has `ignoreArrows="true"`, plain Up/Down never reach the edit box (only Alt + Up/Down)
- Sent lines go through `editBox:AddHistoryLine(text)`, the focused box is `ChatFrameUtil.GetActiveWindow()`

## Minimap / world map

- The minimap has no `SetPlayerTexture` / `SetPlayerTextureHeight`, the engine player arrow cannot be resized
- World map player arrow: `GroupMembersPinTemplate` pins, `pin.dataProvider:GetUnitPinSizesTable().player`, then `pin:SynchronizePinSizes()`

## Bags and bank

Verified against wow-ui-source `forever` (1.60.1) for FRV-10; ForeverMarket already reads bags and the character bank this way in game, the account bank is not yet verified in game.

- Containers: `C_Container.GetContainerNumSlots(bag)` and `C_Container.GetContainerItemInfo(bag, slot)` (a table with `itemID`, `stackCount`, `isBound`, `hyperlink`, ...; nothing for an empty slot); neither is flagged secret
- `Enum.BagIndex`: `Backpack` 0, `Bag_1`..`Bag_4` 1-4, `ReagentBag` 5, `CharacterBankTab_1`..`9` 6-14, `AccountBankTab_1`..`9` 15-23; `Keyring` is -1, and `Characterbanktab` -2 / `Accountbanktab` -3 are the bank's bag slots themselves (the bag in a slot, not its items)
- The bank is Camelot's own frame (`Blizzard_UIPanels_Game/Camelot/BankFrame.lua`) on Mainline's bank panel (`Mainline/BankFrameTemplates.lua`): what retail calls bank tabs are bank bag slots to buy here, and each bought one is a container
  - `C_Bank.FetchPurchasedBankTabIDs(bankType)` lists the containers, `C_Bank.FetchPurchasedBankTabData(bankType)` adds their data (`ID` = the container); bank types: `Enum.BankType.Character` 0, `Guild` 1, `Account` 2
  - Events: `BANKFRAME_OPENED`, `BANKFRAME_CLOSED`, `PLAYERBANKSLOTS_CHANGED(slot)`, `BANK_TABS_CHANGED(bankType)`
  - ForeverMarket scans the character bank slot by slot only while the bank is open and keeps the last reading per character (`R.bank`, `trade/Sources.lua`, `scan/Worth.lua`)
- Account bank: the Camelot frame also handles `Enum.BankType.Account` (page tabs with the `UI_Warbands` icon, containers `AccountBankTab_1`.., event `PLAYER_ACCOUNT_BANK_TAB_SLOTS_CHANGED(slot)`) and shows its tab only when `C_Bank.CanViewBank(Enum.BankType.Account)` is true
  - Whether the live game gives characters an account bank is not yet verified in game: ask `CanViewBank` at runtime, never assume either way
- `C_Item.GetItemCount(itemInfo, includeBank, includeUses, includeReagentBank, includeAccountBank)`: the account bank is a flag of its own (the fifth argument), every flag defaults to false

## Professions

Verified against wow-ui-source `forever` (1.60.1) for FRV-10, not yet verified in game: no AddOn of this repository calls these (ForeverMarket takes its recipes from the SavedVariables of the third-party AddOn ForeverArtisan).

- The profession window is Mainline's `Blizzard_Professions` with Camelot overrides, so recipes come from `C_TradeSkillUI`; the Classic Era functions (`GetNumTradeSkills`, `GetTradeSkillInfo`, `GetNumCrafts`, `GetCraftInfo`) appear nowhere in the branch
  - `C_TradeSkillUI.GetRecipeInfo(recipeSpellID)` returns a table with `learned`, `relativeDifficulty`, `recipeID`, ... (or nil); `C_TradeSkillUI.GetRecipeSchematic(recipeSpellID, isRecraft)` returns `outputItemID`, `quantityMin` / `quantityMax` and `reagentSlotSchematics`
  - Events: `TRADE_SKILL_SHOW`, `TRADE_SKILL_LIST_UPDATE`, `TRADE_SKILL_CLOSE`, `NEW_RECIPE_LEARNED(recipeID)`
- `C_TradeSkillUI.GetAllRecipeIDs` appears nowhere in the `forever` branch (not documented, not used by Blizzard's Lua): treat it as missing
  - Blizzard's recipe list is built from `C_TradeSkillUI.GetFilteredRecipeIDs()` once `C_TradeSkillUI.IsTradeSkillReady()` is true (`Blizzard_ProfessionsTemplates/Blizzard_Professions.lua`); both are used by Blizzard's Lua without an entry in the generated documentation
- A character's professions without a profession window: `GetProfessions()` returns the indexes `prof1, prof2, faid, fish, cook` (First Aid third, where retail has Archaeology) and `GetProfessionInfo(index)` returns `name, texture, rank, maxRank, numSpells, spellOffset, skillLine, rankModifier, ...` (`Blizzard_ProfessionsBook/Camelot/Blizzard_ProfessionsBook.lua`)
  - `C_TradeSkillUI.GetProfessionInfoBySkillLineID(skillLine)` returns `skillLevel` / `maxSkillLevel`; the Camelot book falls back to `rank` / `maxRank` when both are 0
- Every skill line (professions, weapon skills, Defense): `C_SkillInfo.GetNumSkillLines()` and `C_SkillInfo.GetSkillLineInfo(index)` (`skillID`, `name`, `rank`, `maxRank`, `isHeader`, `parentSkillLineID`, ...), event `SKILL_LINES_CHANGED` (`Blizzard_UIPanels_Game/Camelot/SkillsFrame.lua`)

## AddOn list

- `Blizzard_AddOnList/AddonList.lua` reads these `.toc` fields:
  - `## IconTexture:` (texture path or file ID) or `## IconAtlas:` puts an icon before the title, without them the list shows `INV_Misc_QuestionMark`
  - `## Category:` puts AddOns under one collapsible category header (categories are sorted alphabetically above the uncategorized AddOns, the header's right-click menu has Enable all / Disable all / Reset to default); no AddOn depends on another for this
  - `## Group:` nests an AddOn under another *installed* AddOn whose folder name matches exactly (seen in game with the multi-part ForeverArtisan and its "Core"); the client sets it automatically for AddOns with similar names and dependencies, children with a missing parent fall back to the top level outside any category
- SavedVariables files are named after the AddOn folder (`WTF/Account/<account>/SavedVariables/<AddOnName>.lua`, seen on the maintainer's client), so a renamed AddOn starts with a new file and the old one stays unused; the variable name inside must match the `## SavedVariables:` name too

## Misc

- AddOn metadata: `C_AddOns.GetAddOnMetadata(addonName, "Version")`
- New files, new AddOns and `.toc` changes that the client reads at startup (the file list and any field but `## Version:`, for example `## Interface:`, `## SavedVariables:`, dependencies), also a new or removed `Bindings.xml`, need a **full game restart**, Lua-only changes only `/reload`; a `## Version:` bump alone needs no restart, the client only keeps showing the old number until the next one

## Taint

- Never write fields onto Blizzard frames (for example `SomeBlizzardFrame.RegisterEvent = function() end`) that handle secret data, it taints Blizzard code and causes secret value errors or "AddOn has been blocked from an action" popups
- Use `hooksecurefunc` / `frame:HookScript` instead of replacing Blizzard functions or scripts
- Debugging: Lua errors with stack traces end up in `_forever_/Logs/General.log`; `/console taintLog 1` writes `Logs/taint.log`
