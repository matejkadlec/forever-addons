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

## Character names

Verified against wow-ui-source `forever` (1.60.1) for FRV-10, not yet verified in game by this repository.

- Characters have a first name and a surname: Camelot's own `Blizzard_FrameXMLUtil/Camelot/NameUtil.lua` reads `local name, surname = UnitName(unit)` (and the same from `UnitNameUnmodified`), so the second return is the surname here, where retail has the realm; the full name is `name .. Constants.CharacterNameSeparatorConsts.CHARACTERNAME_SURNAME_SEPARATOR .. surname` (a space)
- Character creation takes both and checks them together (`C_CharacterCreation.CreateCharacter(name, surname, ...)`, `CheckName(name, surname)` in `Blizzard_CharacterCreate/Camelot/Blizzard_CharacterCreate.lua`) while `C_CharacterCreation.AreRegionalUniqueNamesEnabled()`; in game `RegionalUniqueNamesEnabled()` tells whether surnames are on
- So a character is identified by both names together (or by `UnitGUID("player")`); a first name alone may repeat, also among one player's characters on a realm
  - Read the two parts with `UnitNameUnmodified("player")` and guard a missing surname: AceDB-3.0 builds its character key that way, `name .. " " .. surname` while `RegionalUniqueNamesEnabled()` (the copy in `backports/Skada/lib/AceDB-3.0/AceDB-3.0.lua`)
  - The source does not settle whether the first return of `UnitName("player")` is the first name alone (`NameUtil.GetUnitFirstName` in the same Camelot file splits it at the separator, "name can be both name + surname"). Seen in game (the maintainer's saved variables, 1.60.1, FRV-56): it is the first name alone, as ForeverArtisan says (`ForeverArtisan_Core/Alts.lua`): ForeverMarket's character key is "Elfiehu", while AceDB's key from `UnitNameUnmodified("player")` in Skada's and Quartz's saved variables is "Elfiehu Ntress" (first name, space, surname)
  - ForeverMarket keys its per-character data by that first return; since 1.23 (FRV-35) a second character with the same first name on one realm and faction gets its full name as its key, and each key remembers its character's `UnitGUID("player")` (`FM.PlayerName()`, `R.charInfo`); `FM.PlayerFullName()` builds the full name from `UnitNameUnmodified("player")` (FRV-70). `UnitGUID` is flagged `SecretWhenUnitIdentityRestricted` and guarded with `issecretvalue`
  - `UnitClass("player")` returns the class name and the class file (`"HUNTER"`): `local _, class = UnitClass and UnitClass("player")` keeps only the first return (a Lua `and` expression is one value), which is why every `R.chars` entry of ForeverMarket before 1.23 is `true`

## Bags and bank

Verified against wow-ui-source `forever` (1.60.1) for FRV-10. In game ForeverMarket already reads bags and the character bank through `C_Container` with `BANKFRAME_OPENED`, `BANKFRAME_CLOSED` and `PLAYERBANKSLOTS_CHANGED`; the `C_Bank` functions, `BANK_TABS_CHANGED` and everything about the account bank are verified against the source only (no AddOn of this repository uses them, not yet verified in game).

- Containers: `C_Container.GetContainerNumSlots(bag)` and `C_Container.GetContainerItemInfo(bag, slot)` (a table with `itemID`, `stackCount`, `isBound`, `hyperlink`, ...; nothing for an empty slot); neither is flagged secret
- `Enum.BagIndex`: `Backpack` 0, `Bag_1`..`Bag_4` 1-4, `ReagentBag` 5, `CharacterBankTab_1`..`9` 6-14, `AccountBankTab_1`..`9` 15-23; `Keyring` is -1, and `Characterbanktab` -2 / `Accountbanktab` -3 are the bank's bag slots themselves (the bag in a slot, not its items)
- The bank is Camelot's own frame (`Blizzard_UIPanels_Game/Camelot/BankFrame.lua`) on Mainline's bank panel (`Mainline/BankFrameTemplates.lua`): what retail calls bank tabs are bank bag slots to buy here, and each bought one is a container
  - `C_Bank.FetchPurchasedBankTabIDs(bankType)` lists the containers, `C_Bank.FetchPurchasedBankTabData(bankType)` adds their data (`ID` = the container); bank types: `Enum.BankType.Character` 0, `Guild` 1, `Account` 2
  - Events: `BANKFRAME_OPENED`, `BANKFRAME_CLOSED`, `PLAYERBANKSLOTS_CHANGED(slot)`, `BANK_TABS_CHANGED(bankType)`
  - ForeverMarket scans the character bank slot by slot (`CharacterBankTab_1`..`9` through `C_Container`) only while the bank is open and keeps the last reading per character (`R.bank`, `trade/Sources.lua`, `scan/Worth.lua`)
- Account bank: the Camelot frame also handles `Enum.BankType.Account` (page tabs with the `UI_Warbands` icon, containers `AccountBankTab_1`.., event `PLAYER_ACCOUNT_BANK_TAB_SLOTS_CHANGED(slot)`) and shows its tab only when `C_Bank.CanViewBank(Enum.BankType.Account)` is true
  - Whether the live game gives characters an account bank is not yet verified in game: ask `CanViewBank` at runtime, never assume either way
  - ForeverMarket (1.23, FRV-35) reads it while the bank is open: `C_Bank.CanViewBank(Enum.BankType.Account)`, then the containers of `C_Bank.FetchPurchasedBankTabIDs(Enum.BankType.Account)` through `C_Container`, again on `PLAYER_ACCOUNT_BANK_TAB_SLOTS_CHANGED` and `BANK_TABS_CHANGED`, every call in `pcall` (not yet verified in game)
- `C_Item.GetItemCount(itemInfo, includeBank, includeUses, includeReagentBank, includeAccountBank)`: the account bank is a flag of its own (the fifth argument), every flag defaults to false

## Professions

Verified against wow-ui-source `forever` (1.60.1) for FRV-10 and FRV-65, not yet verified in game. ForeverMarket takes the recipe list of its market table from the SavedVariables of the third-party AddOn ForeverArtisan; since 1.21 its craft log (`trade/Crafts.lua`) hooks `C_TradeSkillUI.CraftRecipe` and reads `C_TradeSkillUI.GetRecipeSchematic` (below).

- The profession window is Mainline's `Blizzard_Professions` with Camelot overrides, so recipes come from `C_TradeSkillUI`; the Classic Era functions (`GetNumTradeSkills`, `GetTradeSkillInfo`, `GetNumCrafts`, `GetCraftInfo`) appear nowhere in the branch
  - `C_TradeSkillUI.GetRecipeInfo(recipeSpellID)` returns a table with `learned`, `relativeDifficulty`, `recipeID`, ... (or nil); `C_TradeSkillUI.GetRecipeSchematic(recipeSpellID, isRecraft)` returns `outputItemID`, `quantityMin` / `quantityMax` and `reagentSlotSchematics`
  - A schematic's normal materials are the slots with `reagentType == Enum.CraftingReagentType.Basic` (1; `Modifying` 0, `Finishing` 2, `Automatic` 3): `reagents[1].itemID` and `quantityRequired` per craft (`Blizzard_ProfessionsTemplates/Blizzard_Professions.lua`, `Blizzard_ProfessionsTransaction.lua`)
  - Events: `TRADE_SKILL_SHOW`, `TRADE_SKILL_LIST_UPDATE`, `TRADE_SKILL_CLOSE`, `NEW_RECIPE_LEARNED(recipeID)`
- Crafting: Create and Create All call `C_TradeSkillUI.CraftRecipe(recipeSpellID, numCasts, craftingReagents, recipeLevel, orderID, applyConcentration)` once, `numCasts` = how many crafts (`ProfessionsCraftingPageMixin:CreateInternal` in `Blizzard_Professions/Blizzard_ProfessionsCrafting.lua`, through `ProfessionsRecipeTransactionMixin:CraftRecipe`; Camelot's own `Blizzard_ProfessionsCrafting.lua` only moves the window's buttons). Enchants go through `CraftEnchant`, salvage through `CraftSalvage`
  - `CraftRecipe`, `GetRecipeSchematic` and `GetRecipeInfo` are not flagged `HasRestrictions`; their `SecretArguments = "AllowedWhenUntainted"` means only untainted code may pass secret arguments, so an AddOn passes plain numbers (checked with `issecretvalue`)
  - ForeverMarket's craft log hooks `CraftRecipe` with `hooksecurefunc` and counts what a batch used and made from `C_Item.GetItemCount(item, true, false, true, true)` (bags, bank, reagent bank, account bank) after each `BAG_UPDATE_DELAYED`: no combat log and no crafting event needed. That the hook sees every Create / Create All and that the counts move as described is not yet verified in game
  - `TRADE_SKILL_ITEM_CRAFTED_RESULT(data)` (`CraftingItemResultData`: `itemID`, `quantity`, `hyperlink`, ...) and `TRADE_SKILL_CRAFT_BEGIN(recipeSpellID)` exist, and Camelot keeps Blizzard's crafting output log that listens to the first (`Blizzard_Professions/Camelot/Blizzard_ProfessionsCraftingOutputLog.lua` only turns its auto open off); whether the server sends them for Forever's recipes is not verified in game, so ForeverMarket does not rely on them
- `C_TradeSkillUI.GetAllRecipeIDs` appears nowhere in the `forever` branch (not documented, not used by Blizzard's Lua): treat it as missing
  - Blizzard's recipe list comes from `C_TradeSkillUI.GetFilteredRecipeIDs()` in `Professions.GenerateCraftingDataProvider` (`Blizzard_ProfessionsTemplates/Blizzard_Professions.lua`); the window rebuilds it on `TRADE_SKILL_LIST_UPDATE`, and not while `C_TradeSkillUI.IsDataSourceChanging()` is true (`Blizzard_Professions/Blizzard_ProfessionsFrame.lua`)
  - It is the filtered list of the open window: Camelot calls `C_TradeSkillUI.SetShowUnlearned(false)` after every build (`Blizzard_ProfessionsTemplates/Camelot/Blizzard_Professions.lua`), so expect unlearned recipes to be left out of it
  - `C_TradeSkillUI.IsTradeSkillReady()` exists, but Blizzard asks it only for the rank bar (`CanShowBar` in `Blizzard_ProfessionsTemplates/Blizzard_Professions.lua`); using it as the gate for reading recipes is an assumption
  - `GetFilteredRecipeIDs`, `IsDataSourceChanging` and `IsTradeSkillReady` are used by Blizzard's Lua without an entry in the generated documentation
- A character's professions without a profession window: `GetProfessions()` returns profession indexes and `GetProfessionInfo(index)` returns `name, texture, rank, maxRank, numSpells, spellOffset, skillLine, rankModifier, ...` (`Blizzard_ProfessionsBook/Camelot/Blizzard_ProfessionsBook.lua`)
  - How many indexes `GetProfessions()` returns is not settled by the source: the Camelot book reads five (`prof1, prof2, faid, fish, cook`, First Aid third, where retail has Archaeology), the Camelot profession window reads seven (`prim1, prim2, sec1`..`sec5`, `Blizzard_Professions/Camelot/Blizzard_ProfessionsFrame.lua`); collect every non-nil return and take the profession from `GetProfessionInfo`, not from the position
  - `C_TradeSkillUI.GetProfessionInfoBySkillLineID(skillLine)` returns `skillLevel` / `maxSkillLevel`; the Camelot book falls back to `rank` / `maxRank` when both are 0
- Every skill line (professions, weapon skills, Defense): `C_SkillInfo.GetNumSkillLines()` and `C_SkillInfo.GetSkillLineInfo(index)` (`skillID`, `name`, `rank`, `maxRank`, `isHeader`, `parentSkillLineID`, ...), event `SKILL_LINES_CHANGED` (`Blizzard_UIPanels_Game/Camelot/SkillsFrame.lua`)

## Auction House

Verified against wow-ui-source `forever` (1.60.1) for FRV-7. In game ForeverMarket already calls the functions below, and what it found there is marked "seen in game by ForeverMarket":

- the full scan: `ReplicateItems`, the `GetReplicateItem...` getters and `GetNumReplicateItems`, `REPLICATE_ITEM_LIST_UPDATE`
- searches of one item: `MakeItemKey`, `SendSearchQuery`, the commodity and item search result getters, `HasFullCommoditySearchResults` / `HasFullItemSearchResults`, `COMMODITY_SEARCH_RESULTS_UPDATED`, `ITEM_SEARCH_RESULTS_UPDATED`
- commodity purchases: `StartCommoditiesPurchase`, `ConfirmCommoditiesPurchase`, `CancelCommoditiesPurchase`, `GetQuoteDurationRemaining`, `COMMODITY_PRICE_UPDATED`, `COMMODITY_PRICE_UNAVAILABLE`, `COMMODITY_PURCHASE_SUCCEEDED`, `COMMODITY_PURCHASE_FAILED`
- your auctions as Blizzard's window asks for them: `OWNED_AUCTIONS_UPDATED`, `GetNumOwnedAuctions`, `GetOwnedAuctionInfo`
- `CalculateCommodityDeposit`, `IsThrottledMessageSystemReady` with `AUCTION_HOUSE_THROTTLED_SYSTEM_READY`, `AUCTION_HOUSE_AUCTION_CREATED`, and `hooksecurefunc` on `PostItem` / `PostCommodity`

Everything else in this section is verified against the source only (not yet verified in game): posting, confirming, cancelling and bidding from an AddOn's own button, `QueryOwnedAuctions`, `SendSellSearchQuery`, `CalculateItemDeposit`, the item key functions other than `MakeItemKey`, every browse and favorites function, and every call into Blizzard's `AuctionHouseFrame`.

- The Auction House is Mainline's `Blizzard_AuctionHouseUI` on `C_AuctionHouse` (item keys, commodities, a quote before a commodity purchase); Camelot's only own file is the category list `Blizzard_AuctionHouseUI/Camelot/Blizzard_AuctionData.lua`
  - The Classic Era functions (`QueryAuctionItems`, `GetAuctionItemInfo`, `PostAuction`) are called nowhere in the branch
- `HasRestrictions` (only from a click or a key press, never in combat): `PostItem`, `PostCommodity`, `ConfirmPostItem`, `ConfirmPostCommodity`, `CancelAuction`, `PlaceBid`, `StartCommoditiesPurchase`
  - Not flagged: `ConfirmCommoditiesPurchase`, `CancelCommoditiesPurchase`, `CancelSell`, `ReplicateItems` and the search, browse, owned auction and deposit functions
  - Seen in game by ForeverMarket: `StartCommoditiesPurchase` is accepted from an override binding that clicks an AddOn's hidden button (the sniper's mouse wheel)
- Posting
  - `PostCommodity(item, duration, quantity, unitPrice)` and `PostItem(item, duration, quantity, bid, buyout)` take an `ItemLocation` (`ItemLocation:CreateFromBagAndSlot(bagID, slotIndex)`) and return `needsConfirmation`
  - When that is true, Blizzard's sell frame keeps the arguments (`CachePendingPost`) and `AuctionHouseFrame` shows the `AUCTION_HOUSE_POST_WARNING` popup on the event of that name, whose Accept calls `ConfirmPostCommodity` / `ConfirmPostItem` with the kept arguments; `AUCTION_HOUSE_POST_ERROR` shows an error popup instead (`Blizzard_AuctionHouseFrame.lua`, `Blizzard_AuctionHouseCommoditiesSellFrame.lua`, `Blizzard_AuctionHouseItemSellFrame.lua`)
    - The frame registers both events when it loads, so the popup also appears for a post an AddOn started. Its Accept confirms only what one of Blizzard's own sell frames still keeps as its pending post: usually nothing, but a warning the player cancelled leaves that post kept (the popup has no cancel handler, only `ClearPost` drops it). Such an AddOn has to confirm itself and must not leave that popup to the player
  - `AUCTION_HOUSE_AUCTION_CREATED(auctionID)` follows a created auction
  - Before a post: `IsSellItemValid(item, displayError)`, `GetItemCommodityStatus(item)` (`Enum.ItemCommodityStatus`: `Unknown` 0, `Item` 1, `Commodity` 2; Blizzard treats `Unknown` as item data not loaded yet), `GetAvailablePostCount(item)` (Blizzard's sell frame takes it as the largest quantity), `CalculateCommodityDeposit(itemID, duration, quantity)` / `CalculateItemDeposit(item, duration, quantity)`, `IsThrottledMessageSystemReady()` (Blizzard's Post button is disabled without it)
  - `duration` is the index of Blizzard's duration menu, 1 to 3 (`AUCTION_DURATION_ONE` .. `AUCTION_DURATION_THREE`, CVar `auctionHouseDurationDropdown`); seen in game by ForeverMarket: 1 = 2 hours, 2 = 8 hours, 3 = 24 hours
  - Blizzard's item sell frame follows a post of several units with the multisell events `AUCTION_MULTISELL_START(numRepetitions)`, `AUCTION_MULTISELL_UPDATE(createdCount, totalToCreate)` and `AUCTION_MULTISELL_FAILURE` (its progress bar reads `AUCTION_CREATING`); `CancelSell()` exists
  - Blizzard's sell frame suggests a price only while `ShouldAutoPopulatePrice()` is true (else it starts at 0): the price of the cheapest listing (a commodity's first search result, an item's cheapest buyout of the same item level; no undercut), and before the search arrives 1.5 times the vendor price (`Constants.AuctionConstants.DEFAULT_AUCTION_PRICE_MULTIPLIER`) rounded up to the next silver (`AuctionHouseSellFrameMixin:GetDefaultPrice`)
  - A right-click on a bag item while the Auction House is shown goes to `AuctionHouseFrame:SetPostItem(itemLocation)` (`ContainerFrameItemButton_OnClick`, `Blizzard_UIPanels_Game/Mainline/ContainerFrame.lua`; Camelot's own `ContainerFrame.lua` does not change it)
  - `SupportsCopperValues()` tells whether prices may end in copper: without it Blizzard's Auction House money inputs hide the copper box (`LargeMoneyInputFrameMixin` with `useAuctionHouseCopperValue`) and the sell frame rounds the deposit up to silver
  - Seen in game by ForeverMarket: an auction of an item that does not stack needs at least 1 silver, a cheaper post is dropped without an error and the post hangs ("Creating 0/15"); the deposit is max(1 silver, share x vendor sell price x units) with a share of 20% for 8 hours and 60% for 24 hours; the Auction House keeps 5% of a sale
- Your auctions: `QueryOwnedAuctions(sorts)`, then `OWNED_AUCTIONS_UPDATED`, `GetNumOwnedAuctions()` and `GetOwnedAuctionInfo(index)` (`auctionID`, `itemKey`, `itemLink`, `status`: `Enum.AuctionStatus.Active` 0 or `Sold` 1, `quantity`, `timeLeftSeconds`, `buyoutAmount`, `bidAmount`, `bidder`)
  - Blizzard's window asks for the list only from its Auctions tab: `AuctionHouseAuctionsFrameMixin:RefreshSearchResults` and the list's refresh call `AuctionHouseFrame:QueryAll(AuctionHouseSearchContext.AllAuctions)` (`Blizzard_AuctionHouseAuctionsFrame.lua`); opening the Auction House asks for the favorites and the bids only (`AuctionHouseFrameMixin:OnShow`, `OnEvent`). An AddOn that only listens to `OWNED_AUCTIONS_UPDATED` therefore holds a list as old as the last look at that tab (or another AddOn's query): ForeverMarket adds its own posts made since (`FM.OwnListings`)
  - `QueryAll` passes the tab's sorts from Blizzard's saved global `g_auctionHouseSortsBySearchContext[AuctionHouseSearchContext.AllAuctions]` (default: name, then price; `Blizzard_AuctionHouseFrame.lua`). Since 1.23 (FRV-57) ForeverMarket calls `C_AuctionHouse.QueryOwnedAuctions` with a copy of those sorts once per AH visit and after posts, not while `IsThrottledMessageSystemReady()` is false, its deep scan waits for `ReplicateItems` or Blizzard's Auctions tab is shown. Not yet verified in game: that the query is accepted from AddOn code, and what it does to a deep scan, a search or Auctionator's queue running at the same time
  - Cancelling: `CanCancelAuction(ownedAuctionID)`, `GetCancelCost(ownedAuctionID)` (Blizzard's `CANCEL_AUCTION` popup shows it and changes its text when it is above 0), `CancelAuction(ownedAuctionID)`, then `AUCTION_CANCELED(auctionID)`
- Searches of one item: `SendSearchQuery(itemKey, sorts, separateOwnerItems, minLevelFilter, maxLevelFilter)` and `SendSellSearchQuery(itemKey, sorts, separateOwnerItems)` (the sell page's search by item ID: "ItemKey should have its iLVL and suffix cleared before calling"); their documentation limits them to 100 calls per minute
  - Results: `COMMODITY_SEARCH_RESULTS_UPDATED(itemID)` with `GetNumCommoditySearchResults(itemID)` / `GetCommoditySearchResultInfo(itemID, index)` (`unitPrice`, `quantity`, `auctionID`, `numOwnerItems`, `containsOwnerItem`, `owners`, ...); `ITEM_SEARCH_RESULTS_UPDATED(itemKey, newAuctionID)` with `GetNumItemSearchResults(itemKey)` / `GetItemSearchResultInfo(itemKey, index)` (`auctionID`, `buyoutAmount`, `bidAmount`, `quantity`, `containsOwnerItem`, `owners`, `timeLeftSeconds`, ...)
  - A long result comes in batches: `HasFullCommoditySearchResults(itemID)` / `HasFullItemSearchResults(itemKey)` tell whether it is complete, `RequestMoreCommoditySearchResults(itemID)` / `RequestMoreItemSearchResults(itemKey)` ask for the next batch (both return `hasFullResults`; Blizzard's lists call them as they are scrolled toward their end), and `COMMODITY_SEARCH_RESULTS_ADDED(itemID)` / `ITEM_SEARCH_RESULTS_ADDED(itemKey)` follow (`Blizzard_AuctionHouseCommoditiesList.lua`, `Blizzard_AuctionHouseItemBuyFrame.lua`)
  - Item keys: `MakeItemKey(itemID, itemLevel, itemSuffix, battlePetSpeciesID)`, `GetItemKeyFromItem(item)`, `GetItemKeyInfo(itemKey)` (`itemName`, `quality`, `isCommodity`, `isEquipment`, ...)
  - Sorts are tables `{ sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false }` (`Price` 0, `Name` 1, `Level` 2, `Bid` 3, `Buyout` 4, `TimeRemaining` 5)
- Browse lists: `SendBrowseQuery(query)` (`searchString`, `sorts`, `minLevel`, `maxLevel`, `filters`, `itemClassFilters`), `SearchForFavorites(sorts)` and `SearchForItemKeys(itemKeys, sorts)`, read with `GetBrowseResults()` after `AUCTION_HOUSE_BROWSE_RESULTS_UPDATED`
  - That is the first batch only: while `HasFullBrowseResults()` is false, Blizzard's list calls `RequestMoreBrowseResults()` as it is scrolled toward its end and appends the payload of `AUCTION_HOUSE_BROWSE_RESULTS_ADDED(addedBrowseResults)` (`Blizzard_AuctionHouseBrowseResultsFrame.lua`)
  - `SearchForItemKeys` is documented, but Blizzard's Lua on the branch never calls it: check it in game before building on it
  - Blizzard's own search from another window is the profession window's gamepad action for a reagent: `AuctionHouseFrame:SetSearchText(itemName)`, then `AuctionHouseFrame.SearchBar.SearchButton:Click()`, which runs `SearchBar:StartSearch()` (`Blizzard_Professions/Blizzard_ProfessionsFrame.lua`); `SetSearchText` returns false outside the Buy pages
  - `AuctionHouseFrame:SelectBrowseResult(browseResult)` opens the Buy page of `browseResult.itemKey` (a commodity's with `browseResult.minPrice`)
  - Favorites: `FavoritesAreAvailable()`, `IsFavoriteItem(itemKey)`, `SetFavoriteItem(itemKey, setFavorite)`, `HasMaxFavorites()`; Blizzard's favorites search is `AuctionHouseFrame:QueryAll(AuctionHouseSearchContext.AllFavorites)`
- A call into `AuctionHouseFrame` from AddOn code runs tainted: `SetDisplayMode` writes `displayMode` and selects the tab (`PanelTemplates_SetTab`), and Blizzard's bag button reads `AuctionHouseFrame:IsListingAuctions()` on a right-click while the frame is shown (`ContainerFrameItemButton_OnClick`). Whether that blocks anything is not yet verified in game: after such a call, check with `/console taintLog 1` that a right-click on a bag item still works. The `C_AuctionHouse` functions alone leave the frame untouched
- Commodity purchases: `StartCommoditiesPurchase(itemID, quantity)`, then the quote `COMMODITY_PRICE_UPDATED(updatedUnitPrice, updatedTotalPrice)` or `COMMODITY_PRICE_UNAVAILABLE`, `GetQuoteDurationRemaining()`, `ConfirmCommoditiesPurchase(itemID, quantity)` or `CancelCommoditiesPurchase()`, then `COMMODITY_PURCHASE_SUCCEEDED` or `COMMODITY_PURCHASE_FAILED`; none of these four events names the item
  - `COMMODITY_PURCHASED(itemID, quantity)` and `ITEM_PURCHASED(itemID)` are documented and would name it, but Blizzard's Lua on the branch never registers them: check in game whether they fire before building on them
- An auction of an item that is no commodity is bought with `PlaceBid(auctionID, bidAmount)`: the buyout as the amount buys it (Blizzard's `BUYOUT_AUCTION` popup), `AUCTION_HOUSE_PURCHASE_COMPLETED(auctionID)` follows
- Full scans: `ReplicateItems()`, then `REPLICATE_ITEM_LIST_UPDATE`, `GetNumReplicateItems()`, `GetReplicateItemInfo(index)`, `GetReplicateItemLink(index)`, `GetReplicateItemTimeLeft(index)`
  - Seen in game by ForeverMarket: the server allows it once per 15 minutes and the event fires many times while the list arrives
  - The seller (`owner` / `ownerFull` of `GetReplicateItemInfo`) is given only for your own auctions, as your first name and surname ("Elfiehu Ntress", no realm); every other auction has none. Seen in game in the maintainer's saved variables (FRV-56): in the deep scan of 2026-11-19 20:59, 46 of 313,085 auctions carried a seller, all of them his. Whether the auctions of your other characters are named too is not known. ForeverMarket recognizes the logged-in character's full name (`FM.IsOwnChar`, FRV-70) and finds the rest of yours from the owned list and its posts

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
