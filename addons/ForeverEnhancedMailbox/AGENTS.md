# ForeverEnhancedMailbox (`addons/ForeverEnhancedMailbox/`)

> **Scope:** the ForeverEnhancedMailbox AddOn. The root [`AGENTS.md`](../../AGENTS.md) and [`addons/AGENTS.md`](../AGENTS.md) apply here and are not repeated.
>
> **Maintenance:** update this guide when a file, a step or stop of a collection, a safety rule, the saved settings, a slash command or the hooks into Blizzard's mail frame change; the user-facing description lives in the root [`README.md`](../../README.md).

More ways to collect mail from the default inbox (FRV-178, after the analysis FRV-166; label `forever-enhanced-mailbox`, shortname FEM, `/fem`). Mail AddOns such as Postal and Parcel gave the ideas; no code of theirs is in this folder. The API facts it rests on are in [`docs/forever-api-notes.md`](../../docs/forever-api-notes.md#mail).

## Files

| File | Holds |
| --- | --- |
| `JimsForeverAddOns.lua` | The shared file of every first-party AddOn (login line, `/jfa`, minimap button): an identical copy, never edited here alone ([`addons/AGENTS.md`](../AGENTS.md#shared-file-jimsforeveraddonslua)) |
| `Media/JimsForeverAddOns.tga` | The minimap button's icon (an orange J) that the shared file takes from this AddOn's folder when its copy runs: an identical copy in every first-party AddOn, never edited here alone ([`addons/AGENTS.md`](../AGENTS.md#shared-file-jimsforeveraddonslua)) |
| `Locale.lua` | Every shown text (`ns.L`) |
| `Core.lua` | Pure logic, no game calls (tested in `tests/foreverenhancedmailbox/core_test.lua`): `ns.NextStep` (which mail and slot a step takes), `ns.Outcome` and `ns.RecordOutcome` (what a step's answer means), `ns.Waiting` (what waits), `ns.SummaryLine` (the chat line of a run), money, the modifier's name, the hint line |
| `ForeverEnhancedMailbox.lua` | Messages, saved settings, the inbox as a collection reads it (`ns.ReadMail`, `ns.ReadInbox`, `ns.FreeSlots`), the collection (`ns.Start`, `ns.Stop`, the `OnUpdate` steps), events, slash commands |
| `MailButton.lua` | The arrow on Open All and its menu, the line in an inbox row's tooltip, the hooks into the mail frame (`ns.HookMailFrame`) |
| `SettingsPanel.lua` | `Esc -> Options -> AddOns -> Jim's Forever AddOns -> Enhanced Mailbox` |

`tests/foreverenhancedmailbox/addon_test.lua` loads the whole AddOn on a faked mail frame, inbox and server.

## The mail frame

- Forever's mail frame is Mainline's `Blizzard_MailFrame`, loaded with the game; the AddOn hooks it at `PLAYER_LOGIN`, at `ADDON_LOADED` of `Blizzard_MailFrame` or at `MAIL_SHOW`, whichever finds `OpenAllMail` and `InboxFrame` first, once
- The arrow `ForeverEnhancedMailboxButton` (22 x 22) is the AddOn's own child of `OpenAllMail`, anchored to its right edge, so it hides with Open All (also in gamepad mode). Its art is the old dropdown arrow (`Interface\ChatFrame\UI-ChatIcon-ScrollDown-*`); while a run goes it is the group loot "pass" X (`Interface\Buttons\UI-GroupLoot-Pass-*`) and a click stops the run; greyed while Open All runs
- The menu is `MenuUtil.CreateContextMenu`, built again each time it opens: a title, "Collect gold" with the gold that waits, "Collect items" with the items that wait (and the slots it keeps), each greyed when nothing waits, a divider, "Settings"
- Hooks, nothing else: `hooksecurefunc(OpenAllMail, "StartOpening", ...)` stops a run, `"StopOpening"` makes the arrow usable again; `InboxFrame:HookScript("OnHide", ...)` stops a run ("the mailbox closed" when `MailFrame` is hidden too, else "you left the inbox"); `hooksecurefunc("InboxFrameItem_OnEnter", ...)` adds the hint line (the row's `OnUpdate` builds the tooltip again every frame through that global, so the line is added each time). The row's `index` is read, never written

## A collection

- One take per step from the engine frame's `OnUpdate` (set only while a run goes): at least `STEP_DELAY` = 0.3 s after the last take and no `C_Mail.IsCommandPending()`; then the inbox is read again, the last take's answer counted, and the next step taken from the first mail that fits (top down; items from slot 16 down to 1)
- **Collect gold:** `TakeInboxMoney(index)` on every mail with money; never limited by the bags
- **Collect items:** `TakeInboxItem(index, slot)` on every attachment, only while the free slots of the `bagFamily == 0` bags (`C_Container.GetContainerNumFreeSlots`, backpack to `NUM_BAG_SLOTS`) are above `keepFree`; an item of a `MAIL_FAILED(itemID)` is skipped for the rest of the run; money stays in the mails
- **The answer** (`ns.Outcome`): `MAIL_FAILED` -> failed; `MAIL_SUCCESS`, fewer mails shown, another mail at the index, the money gone or `GetMoney()` risen, the slot emptied or changed -> success; else no effect. A mail whose target has no effect in `MAX_TRIES` = 2 answers in a row is passed over for the rest of the run, never retried in a loop. The targets are keyed by what a mail holds (sender, subject, money or the slot's stack), so identical mails (the same AH sale or win) share a key: a take that works clears the count, and the run passes over only as many of them, top down, as got stuck (`run.skip[key]` is a count)
- **Mails counted:** a success on another mail than the last success (index, sender, subject), or after a mail left the inbox
- **Stops** (each with one chat line): nothing left, the bags at the limit (items), `MAIL_CLOSED`, the inbox hiding, `PLAYER_LEAVING_WORLD`, 10 s pending without an answer, Blizzard's Open All starting, the stop sign, `/fem stop`, `/fem off`, an `ADDON_ACTION_BLOCKED` / `ADDON_ACTION_FORBIDDEN` of this AddOn, a take that raised an error, the mail at the index changing before the call five times in a row. A take made before the stop is counted when its answer is there, else the line says the answer is missing
- **Never starts** while the AddOn is off, a run goes, the inbox is not visible, Open All runs (`OpenAllMail:IsEnabled()` is false exactly then) or a command is pending
- **The chat line** (`ns.SummaryLine`): what was collected and from how many mails ("from 2 of 9 mails" when it stopped early), the COD and GM mails left alone, why it stopped (with the items and mails left at the bag limit), what could not be taken, what waits on the server (`GetInboxNumItems()` total less shown)

## Safety rules (acceptance criteria of FRV-178)

- **Never pays COD:** `ns.ReadMail` treats a mail with `CODAmount ~= 0`, from a GM, or with any secret value as one to leave alone; and right before every call the header of that very index is read again (`Take`): the call is made only when its COD is 0, it is not from a GM, and sender, subject (and the money of a money take) are still those of the step
- **Never deletes or returns:** no file of the AddOn names `DeleteInboxItem`, `ReturnInboxItem`, `TakeInboxTextItem` or `AutoLootMailItem` (a test reads the files); a letter keeps its text and stays in the inbox
- **The take calls as globals at call time:** `pcall(_G.TakeInboxMoney, index)`, `pcall(_G.TakeInboxItem, index, slot)`, never a local taken at load, so hooks made later (ForeverMarket's, at `PLAYER_LOGIN`) see every call (tested)
- **ForeverMarket:** no dependency either way; it reads the inbox at each take call through its own hooks, so one command at a time on a freshly read index is what keeps its log complete ([`addons/ForeverMarket/AGENTS.md`](../ForeverMarket/AGENTS.md))
- **Taint and secrets:** no field written onto a Blizzard frame, no Blizzard function or script replaced; every value read from the inbox, the bags, `GetMoney`, `IsCommandPending` and `GetModifiedClick` goes through `issecretvalue` before a comparison or math

## Saved settings

- `ForeverEnhancedMailboxSettings` (account): `enabled`, `hint` (booleans, default true), `keepFree` (0 to 20, default 0); cleaned at load (a broken value takes its default)

## In game

The maintainer's in-game test of 1.0.1 passed on 2026-11-25 (FRV-178). What it showed is in [`docs/forever-api-notes.md`](../../docs/forever-api-notes.md#mail):

- **Calls:** out of combat, AddOn code may call `TakeInboxMoney` and `TakeInboxItem` from `OnUpdate` (the gold arrived, the items came into the bags).
- **Shift+click:** Blizzard's Shift+click takes the whole mail.
- **Hint:** the line added through `hooksecurefunc("InboxFrameItem_OnEnter", ...)` shows at the end of the row's tooltip, with the key `GetModifiedClick("MAILAUTOLOOTTOGGLE")` names (Shift in his client).
- **ForeverMarket:** after a Collect gold run, "no longer listed" on `/fm status` did not rise. That its hooks see every take comes from the code and the tests, not from the game.
- **Layout:** the arrow covers none of the page button's "Next" text.

Not seen in game yet:

- Whether the takes are allowed in a fight. The test saw no "AddOn has been blocked" popup, but a call refused in combat shows none: `ADDON_ACTION_BLOCKED` only adds a chat line, and the run then stops with its "blocked" line.
- Which signals the live client gives for a take (`MAIL_SUCCESS`, `MAIL_FAILED`, the inbox update, `GetMoney`).
- Which emptied mails the server removes, and how many mails a list holds.

## Not in this version (FRV-179)

- By kind of mail (AH sold, won, expired, cancelled, other), items that top up a stack at the slot limit, going on after the inbox refreshed, "Collect gold and items" in one run, selecting mails, key bindings
