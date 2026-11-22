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
- Shift+click of an item (a bag slot, a chat link, a row of the Auction House) goes through `HandleModifiedItemClick` to `ChatFrameUtil.InsertLink(link)` (`Blizzard_ChatFrameBase/Mainline/ChatFrameUtilOverrides.lua`; `ChatEdit_InsertLink` is its deprecated alias in `Blizzard_DeprecatedChatInfo`). It fills the macro text, the profession search, the communities chat or the active chat box (and gives that box the focus), else, while `AuctionHouseFrame` is visible, the AH's search box (`SetSearchText`). Verified against the source only: ForeverMarket 1.34 (FRV-41) puts the item into its sniper's item box with `hooksecurefunc(ChatFrameUtil, "InsertLink", ...)` while that box has the focus (not yet verified in game)

## Minimap / world map

- The minimap has no `SetPlayerTexture` / `SetPlayerTextureHeight`, the engine player arrow cannot be resized
- World map player arrow: `GroupMembersPinTemplate` pins, `pin.dataProvider:GetUnitPinSizesTable().player`, then `pin:SynchronizePinSizes()`
- The map hierarchy (verified against wow-ui-source `forever` for FRV-99, not yet verified in game; ForeverMarket 1.36's place filter, `trade/Places.lua`):
  - `C_Map.GetMapInfo(uiMapID)` returns `UiMapDetails` (`mapID`, `name`, `mapType`, `parentMapID`, `flags`) or nothing; `C_Map.GetMapChildrenInfo(uiMapID, mapType, allDescendants)` the maps under one; `C_Map.GetBestMapForUnit("player")` the map you are in ("only works for the player and party members"), nilable (`MapDocumentation.lua`). None is flagged secret or `HasRestrictions` (only `OpenWorldMap` is); their `SecretArguments = "AllowedWhenUntainted"`, so an AddOn passes plain numbers
  - `Enum.UIMapType`: `Cosmic` 0, `World` 1, `Continent` 2, `Zone` 3, `Dungeon` 4, `Micro` 5, `Orphan` 6 (`MapConstantsDocumentation.lua`); Blizzard's world map walks `parentMapID` up while it is above 0 (`Blizzard_WorldMap/Blizzard_WorldMapTemplates.lua`)
  - Events `ZONE_CHANGED`, `ZONE_CHANGED_INDOORS`, `ZONE_CHANGED_NEW_AREA` (no payload)
  - ForeverArtisan_Contacts saves a vendor's map as `mapID` (zone level: 1438 Teldrassil for a vendor in Dolanaar, whose `subzone` is "Dolanaar"; 1457 Darnassus) with `mapName` and `zone`; in the maintainer's saved data of 2026-11-22 one vendor of 137 has no `mapID` (zone "Deeprun Tram"). Whether the game puts Darnassus under Teldrassil (and Stormwind City under Elwynn Forest) or right under its continent is not known outside the game: ForeverMarket follows `parentMapID` either way

## Character names

Verified against wow-ui-source `forever` (1.60.1) for FRV-10, not yet verified in game by this repository.

- Characters have a first name and a surname: Camelot's own `Blizzard_FrameXMLUtil/Camelot/NameUtil.lua` reads `local name, surname = UnitName(unit)` (and the same from `UnitNameUnmodified`), so the second return is the surname here, where retail has the realm; the full name is `name .. Constants.CharacterNameSeparatorConsts.CHARACTERNAME_SURNAME_SEPARATOR .. surname` (a space)
- Character creation takes both and checks them together (`C_CharacterCreation.CreateCharacter(name, surname, ...)`, `CheckName(name, surname)` in `Blizzard_CharacterCreate/Camelot/Blizzard_CharacterCreate.lua`) while `C_CharacterCreation.AreRegionalUniqueNamesEnabled()`; in game `RegionalUniqueNamesEnabled()` tells whether surnames are on
- So a character is identified by both names together (or by `UnitGUID("player")`); a first name alone may repeat, also among one player's characters on a realm
  - Read the two parts with `UnitNameUnmodified("player")` and guard a missing surname: AceDB-3.0 builds its character key that way, `name .. " " .. surname` while `RegionalUniqueNamesEnabled()` (the copy in `backports/Skada/lib/AceDB-3.0/AceDB-3.0.lua`)
  - The source does not settle whether the first return of `UnitName("player")` is the first name alone (`NameUtil.GetUnitFirstName` in the same Camelot file splits it at the separator, "name can be both name + surname"). Seen in game (the maintainer's saved variables, 1.60.1, FRV-56): it is the first name alone, as ForeverArtisan says (`ForeverArtisan_Core/Alts.lua`): ForeverMarket's character key is "Elfiehu", while AceDB's key from `UnitNameUnmodified("player")` in Skada's and Quartz's saved variables is "Elfiehu Ntress" (first name, space, surname)
  - ForeverMarket keys its per-character data by that first return; since 1.23 (FRV-35) a second character with the same first name on one realm and faction gets its full name as its key, and each key remembers its character's `UnitGUID("player")` (`FM.PlayerName()`, `R.charInfo`); `FM.PlayerFullName()` builds the full name from `UnitNameUnmodified("player")` (FRV-70). `UnitGUID` is flagged `SecretWhenUnitIdentityRestricted` and guarded with `issecretvalue`
- `GetRealmName()` (documented in `ConnectionDocumentation.lua`, a `cstring`, no secret flag) returns an empty string on Forever since the client 1.60.1.71037 (2026-11-20). Seen in game (FRV-92): ForeverMarket's first session on that build saved its data under the key "-Alliance" (realm part empty) next to the old "CAMWOW EU4 Realm 2 PvP-Alliance", and ForeverArtisan, which keys characters "Name-Realm-GUIDPART", started a second entry "Elfiehu--00CB83C3" in every profession DB. The same build's Blizzard Lua stopped comparing realm names: `C_BattleNet.IsGameAccountOnSameRealm(gameAccountID)` and the new `hasRealmInfo` field of the game account info replace them (`Blizzard_FriendsFrame/Camelot/FriendsFrame.lua`, `UnitPopupSharedUtils.lua`)
  - `UnitGUID("player")` still names the server: "Player-<server>-<hex>" ("Player-6842-00CB83C3"); ForeverArtisan's GUIDPART is its last part. ForeverMarket 1.30.2 (`FM.RealmName`) finds the realm from the saved data by the character's GUID or its server when the name is empty
  - `UnitClass("player")` returns the class name and the class file (`"HUNTER"`): `local _, class = UnitClass and UnitClass("player")` keeps only the first return (a Lua `and` expression is one value), which is why every `R.chars` entry of ForeverMarket before 1.23 is `true`

## Bags and bank

Verified against wow-ui-source `forever` (1.60.1) for FRV-10. In game ForeverMarket already reads bags and the character bank through `C_Container` with `BANKFRAME_OPENED`, `BANKFRAME_CLOSED` and `PLAYERBANKSLOTS_CHANGED`; the `C_Bank` functions, `BANK_TABS_CHANGED` and everything about the account bank are verified against the source only (ForeverMarket 1.23 uses them for the account bank, below; not yet verified in game).

- Containers: `C_Container.GetContainerNumSlots(bag)` and `C_Container.GetContainerItemInfo(bag, slot)` (a table with `itemID`, `stackCount`, `isBound`, `hyperlink`, ...; nothing for an empty slot); neither is flagged secret
- `Enum.BagIndex`: `Backpack` 0, `Bag_1`..`Bag_4` 1-4, `ReagentBag` 5, `CharacterBankTab_1`..`9` 6-14, `AccountBankTab_1`..`9` 15-23; `Keyring` is -1, and `Characterbanktab` -2 / `Accountbanktab` -3 are the bank's bag slots themselves (the bag in a slot, not its items)
- The bank is Camelot's own frame (`Blizzard_UIPanels_Game/Camelot/BankFrame.lua`) on Mainline's bank panel (`Mainline/BankFrameTemplates.lua`): what retail calls bank tabs are bank bag slots to buy here, and each bought one is a container
  - `C_Bank.FetchPurchasedBankTabIDs(bankType)` lists the containers, `C_Bank.FetchPurchasedBankTabData(bankType)` adds their data (`ID` = the container); bank types: `Enum.BankType.Character` 0, `Guild` 1, `Account` 2
  - Events: `BANKFRAME_OPENED`, `BANKFRAME_CLOSED`, `PLAYERBANKSLOTS_CHANGED(slot)`, `BANK_TABS_CHANGED(bankType)`
  - ForeverMarket scans the character bank slot by slot (`CharacterBankTab_1`..`9` through `C_Container`) only while the bank is open and keeps the last reading per character (`R.bank`, `trade/Sources.lua`, `scan/Worth.lua`)
- Account bank: the Camelot frame also handles `Enum.BankType.Account` (page tabs with the `UI_Warbands` icon, containers `AccountBankTab_1`.., event `PLAYER_ACCOUNT_BANK_TAB_SLOTS_CHANGED(slot)`) and shows its tab only when `C_Bank.CanViewBank(Enum.BankType.Account)` is true
  - Whether the live game gives characters an account bank is not yet verified in game: ask `CanViewBank` at runtime, never assume either way
  - ForeverMarket (1.23, FRV-35) reads it while the bank is open: `C_Bank.CanViewBank(Enum.BankType.Account)`, then the containers of `C_Bank.FetchPurchasedBankTabIDs(Enum.BankType.Account)` through `C_Container`, when the bank opens, after every `BAG_UPDATE_DELAYED` while it is open (items moving in the bank fire `BAG_UPDATE`, which the bank panel refreshes on: `Mainline/BankFrameTemplates.lua`) and on `BANK_TABS_CHANGED`; never as it closes; every call in `pcall` (not yet verified in game)
  - `PLAYER_ACCOUNT_BANK_TAB_SLOTS_CHANGED(slot)` is about the bags in the account bank's slots (Camelot's `BankItemButtonBagMixin` refreshes `Enum.BagIndex.Accountbanktab` on it), not about the items in them
- `C_Item.GetItemCount(itemInfo, includeBank, includeUses, includeReagentBank, includeAccountBank)`: the account bank is a flag of its own (the fifth argument), every flag defaults to false
  - Whether `includeBank` counts the character bank tabs while the bank is closed (and right after a login) is not yet verified in game. ForeverMarket 1.35 (FRV-98, `trade/Sources.lua`) does not assume it: with the bank closed it asks whether some item of its last bank reading shows in the bank part (count with - without the bank) and uses the client's count only then (and when that reading holds no item), else its own last reading (`R.bank`); `/fm item <item>` says which one counted
- An empty bags reading was seen in game (FRV-73, 2026-11-20): ForeverMarket 1.23.5 saved `"t|"` (no item) for a character at a logout after a short session, while Bagnon's `BagBrother.lua`, written at the same logout, held items in bags 0 to 4. Its stamp was the logout's, so the read at `PLAYER_LOGOUT` found nothing: either the containers are gone by then, or the bag index was cached before the bags had loaded at login (no `BAG_UPDATE_DELAYED` after it). Which of the two is not known yet: since 1.31 ForeverMarket keeps the last reading instead, reads the bags afresh at login, and notes every skipped read (`charInfo[key].bagsEmpty` = `login,<t>` or `logout,<t>`, shown by `/fm chars`); a `bagsEmpty` of `logout` next to bags that did hold items settles it

## Equipment

Verified against wow-ui-source `forever` (1.60.1) for FRV-93, not yet verified in game. ForeverMarket 1.31 reads what the logged-in character wears to find AH purchases equipped as own gear (`scan/Worth.lua`).

- `PLAYER_EQUIPMENT_CHANGED(equipmentSlot, hasCurrent)` (`PaperDollInfoDocumentation.lua`, synchronous, no secret flag); Camelot's paper doll (`Blizzard_UIPanels_Game/Camelot/PaperDollFrame.lua`) registers it
- `GetInventoryItemID("player", slot)` and `GetInventoryItemLink("player", slot)` are not in `Blizzard_APIDocumentationGenerated/`, but Camelot's `PaperDollFrame.lua` and `PaperDollFrameStats.lua` use both, so they exist; the link names the item with its suffix ("... of the Monkey")
- Slots: `INVSLOT_FIRST_EQUIPPED` (1, head) to `INVSLOT_LAST_EQUIPPED` (19, tabard) in `Blizzard_FrameXMLBase/Constants.lua`; 0 is ammo, the bag slots come after 19
- ForeverMarket reads slots 1 to 19 five seconds after `PLAYER_LOGIN` and a second after every `PLAYER_EQUIPMENT_CHANGED` (it counts all slots again, the payload is not used); every call in `pcall`

## Mail

Verified against wow-ui-source `forever` (1.60.1) for FRV-37. In game ForeverMarket already reads the inbox (`GetInboxNumItems`, `GetInboxHeaderInfo`, `GetInboxInvoiceInfo`, `GetInboxItem` on `MAIL_INBOX_UPDATE`); everything about sending is verified against the source only (not yet verified in game).

- The mail frame is Mainline's `Blizzard_MailFrame` on the global mail functions (they are not in `Blizzard_APIDocumentationGenerated/`, Blizzard's Lua uses them): `SendMail(recipient, subject, body, replyMailID)`, `GetSendMailItem(slot)` -> `itemName, itemID, itemTexture, stackCount, quality`, `HasSendMailItem(slot)`, slots 1 to `ATTACHMENTS_MAX_SEND` (12)
- `GetInboxNumItems()` returns the mails the inbox shows and the mails it holds in all (`numItems, totalItems`): the inbox can hold more than it shows
- Events (`MailInfoDocumentation.lua`): `MAIL_SEND_SUCCESS` after the server took a mail (the frame resets its send slots on it), `MAIL_FAILED(itemID)`, `MAIL_SEND_INFO_UPDATE` when the send slots change, `MAIL_INBOX_UPDATE`, `MAIL_SHOW`, `MAIL_CLOSED`
- A mail with money goes through the secure transfer confirmation (`C_SecureTransfer.SendMail` after `SendMail`), so `MAIL_SEND_SUCCESS` can come long after the `SendMail` call
- ForeverMarket (1.24, FRV-37) hooks `SendMail` with `hooksecurefunc`, reads the send slots right after the call and logs them on `MAIL_SEND_SUCCESS` for a mail to another character of the player
  - Assumed, not yet verified in game: the send slots still hold the items right after `SendMail` returns (the frame keeps them until `MAIL_SEND_SUCCESS`, and on `MAIL_FAILED` only re-enables its Send button), and the recipient is typed as the first name or the full name

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
- The character level needed to learn a recipe (FRV-91, ForeverMarket 1.29; the maintainer: "the level that's needed to learn the recipe"; the sources checked against wow-ui-source `forever` and the maintainer's saved variables of 2026-11-20, which recipes it hides not yet verified in game):
  - A recipe item (a vendor's or one on the AH) needs its own required level to be used: `C_Item.GetItemInfo(itemID)` returns it as the fifth value `itemMinLevel` (`ItemDocumentation.lua`: not flagged secret, `SecretArguments = "AllowedWhenUntainted"`, nothing until the client has the item: `C_Item.RequestLoadItemDataByID`; a recipe without one gives 0 or 1)
  - A recipe item's tooltip also shows the item it makes, with that item's own lines: "Pattern: Green Whelp Bracers" in the saved data reads "\nGreen Whelp Bracers", "Wrist", "47 Armor", ..., "Requires Level 33", "Use: Teaches you how to craft Green Whelp Bracers.", its reagents, "Requires Leatherworking (165)". The 33 is the bracers' level, not the pattern's: the recipe's own requirements come after its "Use: Teaches you how to ..." line. Lobster Stew's 45 is most likely the food's own level, the same way; whether the game asks a level to learn its recipe shows in game
  - ForeverArtisan_Contacts saves a vendor's recipe items with every "Requires ..." line of that tooltip in `requires` (the made item's included, so they cannot tell the recipe's own level), the whole tooltip in `tooltip`, and, when the item info was cached at the merchant, `levelReq` (the recipe item's own `itemMinLevel`, only when above 1); in the saved data of 2026-11-20 no recipe item has `levelReq` although its `type` and `quality` from the same `GetItemInfo` call are there: none of those patterns needs a level of its own
  - The client's global string `ITEM_MIN_LEVEL` is not in the source; ForeverMarket reads "Requires Level N" with it when it is there, else in English
  - Trainers: ForeverArtisan_Contacts saves `levelReq` per service from `GetTrainerServiceLevelReq(index)` (guarded by its existence). The function is neither in the generated documentation nor in Blizzard's Lua of the `forever` branch, but the client has it: the saved data holds `levelReq = 10` for the rank-ups Journeyman Leatherworking and Journeyman Fishing; none of the saved profession recipes of trainers carries one
  - Your own level: `UnitLevel("player")` (`UnitDocumentation.lua`: a number, not flagged secret)

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
  - Such a binding fires only where no frame under the cursor takes the wheel (`EnableMouseWheel(true)`: scroll lists, the chat, AddOn tables). ForeverMarket 1.30 (FRV-82) puts a plain full-screen frame above everything while sniping (TOOLTIP strata, `EnableMouseWheel(true)`, `SetMouseClickEnabled(false)`, `SetMouseMotionEnabled(false)`; all three are documented on `ScriptRegion`, protected only for protected frames) and calls `StartCommoditiesPurchase` from its `OnMouseWheel`. Seen in game (the maintainer's in-game test of ForeverMarket 1.30.3, 2026-11-21, FRV-82): a wheel step on such a frame counts as a hardware event for that call (the sniper bought over the market table, a profession window, the chat and the world, nothing scrolled), and clicks, hover tooltips and dragging pass through it to the windows below. A blocked call (`ADDON_ACTION_BLOCKED`, which Blizzard answers with a chat message, no popup: `GameEvent.HandleActionBlocked`) switches the frame off and the binding buys again
  - ForeverMarket 1.34 (FRV-40) also calls `StartCommoditiesPurchase` (and, in its click-confirm mode, `ConfirmCommoditiesPurchase`) from the `OnClick` of a visible button of its own (the sniper's Buy per row). A mouse click on it is a hardware event like the binding's click, but that the call is accepted from it is not yet verified in game; a blocked call turns those buttons off until `/reload` and the wheel buys
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
  - A sold row (seen in the maintainer's saved lists of 2026-11-22, FRV-106): `status` Sold, `quantity` = the units of that sale, `buyoutAmount` = the sale's total (12 Mageweave Cloth posted at 5s 14c: 61s 68c), `timeLeftSeconds` = the time until its mail goes out (at most an hour); a running row's `buyoutAmount` of a commodity is its unit price. A stack sold in parts has one sold row per part, all with the auction's `auctionID` (11 Silk Cloth: rows of 6 and 5). The list can be read while it is still loading: a list of 2026-11-20 lacked auctions that the next one, two minutes later, held again (`HasFullOwnedAuctionResults` exists in the documentation; ForeverMarket does not use it yet)
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
  - `SearchForItemKeys` is documented, but Blizzard's Lua on the branch never calls it
    - Seen in game on 2026-11-21 (ForeverMarket 1.33.1, FRV-47): the server answers it, and Blizzard's Buy list showed exactly the two searched items, with its search box left empty
    - ForeverMarket 1.33 (FRV-47, `FM.SearchAH` in `ui/AHButton.lua`) calls it for a row click of its market table and for "Search all at the AH" on Favorites when Auctionator is not loaded (with Auctionator, Auctionator's shopping list): one call with `MakeItemKey(itemID)` per item (no item level, no suffix) and a copy of `g_auctionHouseSortsBySearchContext[AuctionHouseSearchContext.BrowseAll]` (Blizzard's browse default: price, then name). `AuctionHouseBrowseResultsFrameMixin` registers `AUCTION_HOUSE_BROWSE_RESULTS_UPDATED` in its `OnLoad` and reads `GetBrowseResults()` on it whatever query sent it, so the Buy list shows the results. Not yet verified in game: how many item keys one call takes, and whether the item key of a bare item ID finds an item's random suffix variants
  - Blizzard's own search from another window is the profession window's gamepad action for a reagent: `AuctionHouseFrame:SetSearchText(itemName)`, then `AuctionHouseFrame.SearchBar.SearchButton:Click()`, which runs `SearchBar:StartSearch()` (`Blizzard_Professions/Blizzard_ProfessionsFrame.lua`); `SetSearchText` returns false outside the Buy pages
  - `AuctionHouseFrame:SelectBrowseResult(browseResult)` opens the Buy page of `browseResult.itemKey` (a commodity's with `browseResult.minPrice`)
  - Favorites: `FavoritesAreAvailable()`, `IsFavoriteItem(itemKey)`, `SetFavoriteItem(itemKey, setFavorite)`, `HasMaxFavorites()`; Blizzard's favorites search is `AuctionHouseFrame:QueryAll(AuctionHouseSearchContext.AllFavorites)`
- A call into `AuctionHouseFrame` from AddOn code runs tainted: `SetDisplayMode` writes `displayMode` and selects the tab (`PanelTemplates_SetTab`), and Blizzard's bag button reads `AuctionHouseFrame:IsListingAuctions()` on a right-click while the frame is shown (`ContainerFrameItemButton_OnClick`). Whether that blocks anything is not yet verified in game: after such a call, check with `/console taintLog 1` that a right-click on a bag item still works. The `C_AuctionHouse` functions alone leave the frame untouched
  - ForeverMarket 1.33 (FRV-47) calls `AuctionHouseFrame:SetDisplayMode(AuctionHouseFrameDisplayMode.Buy)` after its search only when `GetDisplayMode()` is another page (a Buy page, Sell, Auctions), like Blizzard's own `QueryAll(AuctionHouseSearchContext.AllFavorites)`; on the Buy list it touches nothing. Not yet verified in game
- Commodity purchases: `StartCommoditiesPurchase(itemID, quantity)`, then the quote `COMMODITY_PRICE_UPDATED(updatedUnitPrice, updatedTotalPrice)` or `COMMODITY_PRICE_UNAVAILABLE`, `GetQuoteDurationRemaining()`, `ConfirmCommoditiesPurchase(itemID, quantity)` or `CancelCommoditiesPurchase()`, then `COMMODITY_PURCHASE_SUCCEEDED` or `COMMODITY_PURCHASE_FAILED`; none of these four events names the item
  - `COMMODITY_PURCHASED(itemID, quantity)` and `ITEM_PURCHASED(itemID)` are documented and would name it, but Blizzard's Lua on the branch never registers them, and seen in game they do not fire (FRV-54: ForeverMarket 1.25 to 1.29 registered both and logged every purchase event at the AH; on 2026-11-20, 29 commodity purchases and one item purchase, none of either)
  - Seen in game in the same log: every commodity purchase sent `COMMODITY_PRICE_UPDATED`, then `COMMODITY_PURCHASE_SUCCEEDED` (no arguments) and `AUCTION_HOUSE_PURCHASE_COMPLETED(0)` (auction ID 0) within a few milliseconds, in either order; the item purchase sent `AUCTION_HOUSE_PURCHASE_COMPLETED(auctionID)` only. No failed purchase happened, so `COMMODITY_PURCHASE_FAILED` and `COMMODITY_PRICE_UNAVAILABLE` were not seen
- Seen in the maintainer's saved variables (2026-11-22, FRV-106): `GetInboxInvoiceInfo` gives an AH mail's other player (`playerName`) only a moment after the mail is first listed: of 1,149 sale mails 673 were read without a name, and 416 of those were read again seconds later with it. A key for "this mail was seen before" must not hold the name (ForeverMarket's did until 1.37 and logged those mails twice). `GetMoney()` answers 0 at `PLAYER_LOGOUT`: every session's last gold record was 0 (13 of 73 readings)
- Seen in the maintainer's saved variables (2026-11-22, FRV-102): every commodity purchase sends one "Auction won" mail whose invoice (`GetInboxInvoiceInfo`, type `buyer`) holds the units and the total paid, also for units from several sellers (the player field is empty then); the sums of a day's mails matched the sniper's own count of what it confirmed. ForeverMarket 1.36.3 mends its purchase log from these mails once
- Handlers of one event run in the order AddOn code registered them (ForeverMarket's `FM.On` keeps a list in TOC order): code that calls `ConfirmCommoditiesPurchase` inside its own `COMMODITY_PRICE_UPDATED` handler runs before a later handler has seen that quote, so a hook on the confirm cannot rely on a quote stored by such a handler (FRV-102: the confirm waits for the quote that follows its start instead)
- An auction of an item that is no commodity is bought with `PlaceBid(auctionID, bidAmount)`: the buyout as the amount buys it (Blizzard's `BUYOUT_AUCTION` popup), `AUCTION_HOUSE_PURCHASE_COMPLETED(auctionID)` follows
- Full scans: `ReplicateItems()`, then `REPLICATE_ITEM_LIST_UPDATE`, `GetNumReplicateItems()`, `GetReplicateItemInfo(index)`, `GetReplicateItemLink(index)`, `GetReplicateItemTimeLeft(index)`
  - Seen in game by ForeverMarket: the server allows it once per 15 minutes and the event fires many times while the list arrives
  - The seller (`owner` / `ownerFull` of `GetReplicateItemInfo`) is given only for your own auctions, as your first name and surname ("Elfiehu Ntress", no realm); every other auction has none. Seen in game in the maintainer's saved variables (FRV-56): in the deep scan of 2026-11-19 20:59, 46 of 313,085 auctions carried a seller, all of them his. Whether the auctions of your other characters are named too is not known. ForeverMarket recognizes the logged-in character's full name (`FM.IsOwnChar`, FRV-70) and finds the rest of yours from the owned list and its posts

## Merchants

Verified against wow-ui-source `forever` (1.60.1) for FRV-48, not yet verified in game. ForeverMarket 1.33 reads the open merchant's offers for its vendor prices (`FM.ReadMerchant` in `trade/Sources.lua`).

- Camelot loads Mainline's merchant window: `Blizzard_UIPanels_Game.toc` lists `[Family]\MerchantFrame.lua` for `mainline` (the `Vanilla\` copy with the old `GetMerchantItemInfo` is for the vanilla game type), and `[Family]` resolves to `Mainline` (Client identity above)
- `GetMerchantNumItems()` and `GetMerchantItemLink(index)` are not in `Blizzard_APIDocumentationGenerated/`, but Mainline's `MerchantFrame.lua` calls both, so they exist
- `C_MerchantFrame.GetItemInfo(index)` (`MerchantFrameDocumentation.lua`: `MayReturnNothing`, `SecretArguments = "AllowedWhenUntainted"`, no secret returns) returns `MerchantItemInfo`: `name`, `texture`, `price` (for `stackCount` units), `stackCount`, `numAvailable`, `isPurchasable`, `isUsable`, `hasExtendedCost`, `currencyID`, `spellID`, `isQuestStartItem`
  - Stock: `SetItemButtonStock` (`Blizzard_ItemButton/Mainline/ItemButtonTemplate.lua`) shows a number only when `numAvailable` is above 0, and the merchant frame greys an item at 0 (sold out); a negative value is unlimited stock
  - A price in items or a currency shows as `hasExtendedCost`: with `price` 0 it costs only those, with `price` above 0 gold plus those (`MerchantFrame_UpdateMerchantInfo`); `currencyID` is not the price: it marks an offer that sells a currency (the frame shows that currency's name, icon and amount instead, `CurrencyContainerUtil.GetCurrencyContainerInfo(info.currencyID, info.numAvailable, ...)`), and it stays nil on items paid in a currency
- Events (`MerchantFrameDocumentation.lua`, all synchronous): `MERCHANT_SHOW`, `MERCHANT_UPDATE` (the frame redraws its list on it), `MERCHANT_CLOSED`, `MERCHANT_FILTER_ITEM_UPDATE(itemID)`
- The merchant's name: `UnitName("npc")` (the portrait uses the `npc` unit, `SetPortraitToUnit("npc")`); an NPC's unit identity can be secret (Secret values above), so ForeverMarket guards it with `issecretvalue` and keeps the price without a name then

## AddOn list

- `Blizzard_AddOnList/AddonList.lua` reads these `.toc` fields:
  - `## IconTexture:` (texture path or file ID) or `## IconAtlas:` puts an icon before the title, without them the list shows `INV_Misc_QuestionMark`
  - `## Category:` puts AddOns under one collapsible category header (categories are sorted alphabetically above the uncategorized AddOns, the header's right-click menu has Enable all / Disable all / Reset to default); no AddOn depends on another for this
  - `## Group:` nests an AddOn under another *installed* AddOn whose folder name matches exactly (seen in game with the multi-part ForeverArtisan and its "Core"); the client sets it automatically for AddOns with similar names and dependencies, children with a missing parent fall back to the top level outside any category
- SavedVariables files are named after the AddOn folder (`WTF/Account/<account>/SavedVariables/<AddOnName>.lua`, seen on the maintainer's client), so a renamed AddOn starts with a new file and the old one stays unused; the variable name inside must match the `## SavedVariables:` name too

## Misc

- AddOn metadata: `C_AddOns.GetAddOnMetadata(addonName, "Version")`
- Blizzard's shared widgets exist on the branch (verified against the source; ForeverMarket's sniper window uses them since 1.34, not yet verified in game): `SearchBoxTemplate` (`Blizzard_SharedXML/Shared/InputBox/InputBoxTemplates.xml`: magnifier, `Instructions`, `clearButton`; its `OnTextChanged` / focus scripts drive the clear button, so an AddOn hooks them), `MoneyInputFrameTemplate` (`Blizzard_MoneyFrame/Mainline/MoneyInputFrame.xml`: boxes `$parentGold` / `Silver` / `Copper`, silver and copper two digits, `MoneyInputFrame_GetCopper` / `SetCopper` / `ResetMoney` / `ClearFocus` / `SetPreviousFocus` / `SetNextFocus` / `SetOnValueChangedFunc`; its own Enter and Tab only move the focus), `WowScrollBoxList` with `CreateScrollBoxListLinearView`, `MinimalScrollBar` (`CreateFrame("EventFrame", ..., "MinimalScrollBar")`), `ScrollUtil.InitScrollBoxListWithScrollBar`, `CreateDataProvider`; both the box and the bar take the mouse wheel (`OnMouseWheel` in their XML) until `EnableMouseWheel(false)`
- Dragged items: `GetCursorInfo()` returns `"item", itemID, itemLink` for an item on the cursor (Blizzard's own drop targets read it so), `ClearCursor()` puts it back where it came from, `CursorHasItem()`
- New files, new AddOns and `.toc` changes that the client reads at startup (the file list and any field but `## Version:`, for example `## Interface:`, `## SavedVariables:`, dependencies), also a new or removed `Bindings.xml`, need a **full game restart**, Lua-only changes only `/reload`; a `## Version:` bump alone needs no restart, the client only keeps showing the old number until the next one

## Taint

- Never write fields onto Blizzard frames (for example `SomeBlizzardFrame.RegisterEvent = function() end`) that handle secret data, it taints Blizzard code and causes secret value errors or "AddOn has been blocked from an action" popups
- Use `hooksecurefunc` / `frame:HookScript` instead of replacing Blizzard functions or scripts
- Debugging: Lua errors with stack traces end up in `_forever_/Logs/General.log`; `/console taintLog 1` writes `Logs/taint.log`
