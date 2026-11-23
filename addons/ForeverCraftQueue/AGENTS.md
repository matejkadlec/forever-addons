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
| `ProfessionButton.lua` | "Add to queue" on `ProfessionsFrame.CraftingPage`, created when `Blizzard_Professions` loads |
| `Panel.lua` | The queue panel (scroll list, Process queue, Clear queue with its in-panel confirmation), docking to `ProfessionsFrame` |
| `SettingsPanel.lua` | `Esc -> Options -> AddOns -> Jim's Forever AddOns -> Craft Queue` |
| `Bindings.xml` | "Forever Craft Queue: process queue" and "show or hide the queue" |

`tests/forevercraftqueue/addon_test.lua` loads the whole AddOn on faked client APIs (the profession window, `C_TradeSkillUI`, bags, casts).

## The profession window

- Forever's profession window is Mainline's `ProfessionsFrame` (`Blizzard_Professions`, load on demand) with Camelot overrides, not the classic `TradeSkillFrame`; its crafting page has `CreateAllButton`, `CreateMultipleInputBox` (the count box) and `CreateButton` at the bottom right, the recipe list (304 px) on the left, and side tabs past the window's right edge
- The AddOn only reads that page (`SchematicForm:GetRecipeInfo()`, the count box's `GetValue()`, `CreateButton:IsShown()`) and hooks it with `hooksecurefunc(page, "ValidateControls", ...)` and `HookScript`; it writes no field onto Blizzard's frames
- "Add to queue" is a child button of the page, anchored left of Create All; it shows while Blizzard shows Create (a learned recipe in your own window)
- The count box reads 0 while the materials are short (Blizzard disables it): Add to queue then adds 1, the row's count is changed in the panel

## Process queue

- One step per press (the panel's button or the binding): the press is the hardware event; never a loop, never a timer that crafts
- The next row is the first one with materials for at least one craft (`ns.NextStep`)
  - Its profession open for your own crafting (`TRADE_SKILL_SHOW` seen and no `TRADE_SKILL_CLOSE` since, `GetBaseProfessionInfo().professionID` is the row's skill line, not loading, not linked, guild or NPC crafting): `C_TradeSkillUI.CraftRecipe(recipeID, casts)` with `casts` = the row's count or what the bags allow; a requirement of `GetRecipeRequirements` that is not met stops it with a chat line
  - Else `C_TradeSkillUI.OpenTradeSkill(skillLine)` (the base profession's ID, as Blizzard's `OpenProfessionUIToSkillLine` passes it); the ticket asked for a secure action button, but the API is documented without `HasRestrictions`, Blizzard's own Lua calls it from unprotected code, and the live Forever AddOn ForeverFishing opens Cooking with it, so no secure frame is needed (and none can block the panel in combat)
  - No row with materials: a chat line names what the first row lacks
- Refused: in combat (the button is disabled and reads "In combat"), while a trade skill cast runs or a batch has casts left (`UnitCastingInfo` `isTradeskill`, `GetRemainingRecasts`), while the AddOn is off
- Crafts leave the queue on the player's `UNIT_SPELLCAST_SUCCEEDED` whose spell ID is a queued recipe ID (secret IDs are ignored); any successful cast of a queued recipe counts, also one from Blizzard's Create
- Material counts come from `ItemUtil.GetCraftingReagentCount(itemID, false)`, the count Blizzard's Create buttons use, else `C_Item.GetItemCount(itemID)`

## Saved data

- `ForeverCraftQueueSettings` (account): `enabled`, `dock`, `confirmClear`, `doneSound` (booleans), `panelPos` (`{ point, relPoint, x, y }` of the free panel, nil = centered)
- `ForeverCraftQueueDB` (per character): `queue`, a list of rows `{ recipeID, name, icon, count, skillLine, profession, reagents = { { itemID, need, name } } }`; cleaned at load (`ns.CleanQueue`: broken rows dropped, a recipe twice merged, counts 1 to 9999)
- A change of the row format needs a migration in `InitializeSavedData` and tests; the queue is the player's plan, not data that cannot be recreated

## Not in this version (FRV-131, to decide with the maintainer)

- More of ATSW's window: recipe search and filters, sorting by skill-up color, a reagent overview of the whole queue, "what can I craft from my bags"
- A shopping list of the queue's missing materials
- A link with ForeverMarket ("Add to craft queue" on a pick), only if both stay standalone
