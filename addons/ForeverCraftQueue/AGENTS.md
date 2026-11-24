# ForeverCraftQueue (`addons/ForeverCraftQueue/`)

> **Scope:** the ForeverCraftQueue AddOn. The root [`AGENTS.md`](../../AGENTS.md) and [`addons/AGENTS.md`](../AGENTS.md) apply here and are not repeated.
>
> **Maintenance:** update this guide when a file, a step of Process queue, the saved data, a slash command or the hooks into Blizzard's profession window change; the user-facing description lives in the root [`README.md`](../../README.md).

A crafting queue across all professions (FRV-131, label `forever-craft-queue`, shortname FCQ, `/fcq`). The idea comes from Advanced Trade Skill Window (ATSW, 3.3.5), which has no license: **take ideas only, never its code**. Nothing of ATSW is copied, ported or translated into this folder; every line is written for Forever's API.

## Files

| File | Holds |
| --- | --- |
| `Locale.lua` | Every shown text (`ns.L`) |
| `Core.lua` | Pure queue logic, no game calls (tested in `tests/forevercraftqueue/core_test.lua`): rows and their cleanup, adding and merging, moving, counts, what the bags allow, `ns.NextStep`, `ns.OnCrafted`, the summaries |
| `ForeverCraftQueue.lua` | Messages, saved data, the profession window's state (`ns.OpenSkillLine`, `ns.IsCrafting`), the steps of Process queue (`ns.Process`), counting crafts, events, key binding globals, slash commands |
| `ProfessionButton.lua` | "Add to queue" and "Open queue" on `ProfessionsFrame.CraftingPage`, created when `Blizzard_Professions` loads |
| `Panel.lua` | The queue panel (scroll list, Process queue, Clear queue with its in-panel confirmation), docking to `ProfessionsFrame` |
| `SettingsPanel.lua` | `Esc -> Options -> AddOns -> Jim's Forever AddOns -> Craft Queue` |
| `Bindings.xml` | "Forever Craft Queue: process queue" and "show or hide the queue" |

`tests/forevercraftqueue/addon_test.lua` loads the whole AddOn on faked client APIs (the profession window, `C_TradeSkillUI`, bags, casts).

## The profession window

- Forever's profession window is Mainline's `ProfessionsFrame` (`Blizzard_Professions`, load on demand) with Camelot overrides, not the classic `TradeSkillFrame`; its crafting page has `CreateAllButton`, `CreateMultipleInputBox` (the count box) and `CreateButton` at the bottom right, the recipe list (304 px) on the left, and side tabs past the window's right edge
- The AddOn only reads that page (`SchematicForm:GetRecipeInfo()`, the count box's `GetValue()`, `CreateButton:IsShown()`) and hooks it with `hooksecurefunc(page, "ValidateControls", ...)` and `HookScript`; it writes no field onto Blizzard's frames
- "Add to queue" and "Open queue" are child buttons of the page in a row above Create All, made from the page's own button template (`page:GetButtonTemplate()`, Camelot's `SharedButtonSmallTemplate`: the red three-slice button with the golden border that Create All uses)
  - Add to queue spans Create All's left and right edge, so it is as wide as Create All (which only grows, with its count's digits), and as high; its vertical middle is the Track Recipe checkbox's (`SchematicForm.TrackRecipeCheckbox`, the maintainer's choice after his test of 1.0.3). Two invisible frames of the AddOn carry the anchors: one from Create All's bottom left corner to the middle of the checkbox's right edge, one cut from it to Create All's width; without the checkbox the row sits 4 px above Create All
  - Open queue sits right of it, as wide as its text plus the template's padding: a Create All wide one would reach the Track Recipe checkbox at the schematic form's bottom right
  - Their frame level is the schematic form's + 2: the first build sat at the page's level left of Create All, over the recipe list, and the game showed only its text, not its red textures (most likely the list's art at the same level drawn over them)
  - Add to queue shows while Blizzard shows Create (a learned recipe in your own window); Open queue whenever the AddOn is on
- The panel opens only when asked for (Open queue, `/fcq`, the binding, Clear queue's confirmation), or with the option `autoOpen` ("Open queue window automatically", off by default) also with the profession window and on Add to queue; an open panel docks when the profession window opens and a docked one closes with it
- The count box reads 0 while the materials are short (Blizzard disables it): Add to queue then adds 1, the row's count is changed in the panel

## Process queue

- One step per press (the panel's button or the binding): the press is the hardware event; never a loop, never a timer that crafts
- The next row is the first one with materials for at least one craft and not on cooldown (`ns.NextStep`; a cooldown is `C_TradeSkillUI.GetRecipeCooldown` with no charges left, what Blizzard's Create checks in `Professions.IsRecipeOnCooldown`; transmutes, Mooncloth, Cured Rugged Hide). Blizzard asks it only for the open profession's recipes, so the AddOn remembers when each cooldown it saw ends and uses that while the recipe's own profession is closed (else Process queue would open that profession only to pass the row over and switch back); its own open window saying ready forgets it
  - Its profession open for your own crafting (`TRADE_SKILL_SHOW` seen and no `TRADE_SKILL_CLOSE` since, `GetBaseProfessionInfo().professionID` is the row's skill line, not loading, not linked, guild or NPC crafting): `C_TradeSkillUI.CraftRecipe(recipeID, casts)` with `casts` = the row's count or what the bags allow; a requirement of `GetRecipeRequirements` that is not met stops it with a chat line
  - Else `C_TradeSkillUI.OpenTradeSkill(skillLine)` (the base profession's ID, as Blizzard's `OpenProfessionUIToSkillLine` passes it). The ticket asked for a secure action button; this route needs no protected frame (none can then freeze the panel in combat), but it rests on weaker proof than a spell cast:
    - for it: the generated documentation has no `HasRestrictions` on it, Blizzard calls it outside secure templates (`OpenProfessionUIToSkillLine`, `ProfessionsUtil.OpenProfessionFrameToRecipe`, alert frames), and two live Forever AddOns in the maintainer's AddOns folder call it from their own code (ForeverFishing opens Cooking with it, ForeverArtisan_Camping in `pcall`)
    - against: the documentation does not flag every protected call (`C_SpellBook.CastSpellBookItem` has no `HasRestrictions` either), and Camelot's own side tabs open a profession by casting its spellbook item (`ProfessionsLargeRightTabMixin:CastProfessionSpell`)
    - the maintainer's in-game test of 1.0 decides (opening with no window and with another profession open, no blocked popup); if the game refuses it, the fallback is a secure action button that casts the profession's spellbook item
  - No row that can be crafted: a chat line names what the first row lacks, or its cooldown
- Refused: in combat (the button is disabled and reads "In combat"), while a trade skill cast runs or a batch has casts left (`UnitCastingInfo` `isTradeskill`, `GetRemainingRecasts`), while the AddOn is off
- Crafts leave the queue on the player's `UNIT_SPELLCAST_SUCCEEDED` whose spell ID is a queued recipe ID (secret IDs are ignored); any successful cast of a queued recipe counts, also one from Blizzard's Create
- Material counts come from `ItemUtil.GetCraftingReagentCount(itemID, false)`, the count Blizzard's Create buttons use, else `C_Item.GetItemCount(itemID)`

## Saved data

- `ForeverCraftQueueSettings` (account): `enabled`, `dock`, `autoOpen` (false by default), `confirmClear`, `doneSound` (booleans), `panelPos` (`{ point, relPoint, x, y }` of the free panel, nil = centered)
- `ForeverCraftQueueDB` (per character): `queue`, a list of rows `{ recipeID, name, icon, count, skillLine, profession, reagents = { { itemID, need, name } } }`; cleaned at load (`ns.CleanQueue`: broken rows dropped, a recipe twice merged, counts 1 to 9999)
- A change of the row format needs a migration in `InitializeSavedData` and tests; the queue is the player's plan, not data that cannot be recreated

## Not in this version (FRV-131, to decide with the maintainer)

- More of ATSW's window: recipe search and filters, sorting by skill-up color, a reagent overview of the whole queue, "what can I craft from my bags"
- A shopping list of the queue's missing materials
- A link with ForeverMarket ("Add to craft queue" on a pick), only if both stay standalone
