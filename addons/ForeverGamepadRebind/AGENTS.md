# ForeverGamepadRebind (`addons/ForeverGamepadRebind/`)

> **Scope:** the ForeverGamepadRebind AddOn. The root [`AGENTS.md`](../../AGENTS.md) and [`addons/AGENTS.md`](../AGENTS.md) apply here and are not repeated.
>
> **Maintenance:** update this guide when a file, the default layout, a rule of Save, the override keybindings, the saved settings, a slash command or the Gamepad UI facts it rests on change; the user-facing description lives in the root [`README.md`](../../README.md).

The keyboard layout on the gamepad (FRV-227; label `forever-gamepad-rebind`, shortname FGR, `/fgr`): each row of a table gives the action a keyboard key runs a pad button or chord as its **second** keybinding. The API facts it rests on are in [`docs/forever-api-notes.md`](../../docs/forever-api-notes.md#gamepad-and-keybindings); none of them is verified in game yet.

## Files

| File | Holds |
| --- | --- |
| `JimsForeverAddOns.lua` | The shared file of every first-party AddOn (login line, `/jfa`, minimap button): an identical copy, never edited here alone ([`addons/AGENTS.md`](../AGENTS.md#shared-file-jimsforeveraddonslua)) |
| `Media/JimsForeverAddOns.tga` | The minimap button's icon (an orange J) that the shared file takes from this AddOn's folder when its copy runs: an identical copy in every first-party AddOn, never edited here alone ([`addons/AGENTS.md`](../AGENTS.md#shared-file-jimsforeveraddonslua)) |
| `Locale.lua` | Every shown text (`ns.L`), the pad's button names (Xbox names) and the keyboard keys' |
| `Core.lua` | Pure logic, no game calls (tested in `tests/forevergamepadrebind/core_test.lua`): the default layout `ns.DEFAULT_ROWS`, chords (`ns.ParseChord`, `ns.BuildChord`, `ns.ChordLabel`, `ns.KeyLabel`), the saved rows' cleanup, the plan of a Save (`ns.Plan`, `ns.RemovalPlan`), the overrides and blocked keys, the statuses |
| `ForeverGamepadRebind.lua` | Messages, saved settings, the keybinding reader, Save and the removal (`ns.Save`, `Sync`), the override keybindings (`ns.RefreshOverrides`), `/fgr debug`'s monitor, events, slash commands, the key binding's name |
| `Window.lua` | The table's window `ForeverGamepadRebindFrame`: rows, pressing a chord on the pad, the pick list, Save, Revert, Reset to default layout |
| `SettingsPanel.lua` | `Esc -> Options -> AddOns -> Jim's Forever AddOns -> Gamepad Rebind`; the overview page's button opens the window, not the page |
| `Bindings.xml` | `FOREVERGAMEPADREBIND_TOGGLE` (show or hide the window), no key by default |

`tests/forevergamepadrebind/addon_test.lua` loads the whole AddOn over a faked keybinding store.

## Why the pad's keybindings did not fire

- With the Gamepad UI on (`InputDeviceInterfaceStyle` = `Enum.InputDeviceInterfaceType.Gamepad`), `Blizzard_Gamepad/Core.lua` activates the binding context `Enum.BindingContext.GamepadModeInGameCore`. Keybindings of an active context hide the normal ones of the same key (Blizzard's housing code reads the normal one with `C_KeyBindings.GetBindingByKey(key, Enum.BindingContext.None)` when its context does not want the key), and the context holds the Gamepad UI's own actions (`GAMEPADACTIONBUTTON1`-`8`, `GAMEPADLEFTMOD`, `GAMEPADRIGHTMOD`, `GAMEPADLEFTTARGETMODIFIER`, ...). So a second keybinding set in Options on X never reached the game
- The Gamepad UI's menus drive the pad with priority override keybindings on `UIParent` (`Blizzard_GamepadSharedUtility/InputBindingStack/`, `SetOverrideBinding(UIParent, true, ...)`), which win over the context: the AddOn uses the same tool
- The Gamepad UI names chords with LT as `SHIFT` and RT as `CTRL` (`GAMEPAD_MOD_LEFT`, `GAMEPAD_MOD_RIGHT` in `Blizzard_SharedXML/Shared/GamepadConstants.lua`): LT + X is `SHIFT-PAD3`

## Save

- The window edits a copy of the saved rows (`{ [keyboard key] = chord or "" }`); **Save** stores them and writes the plan into the keybinding set in use (`GetCurrentBindingSet()`), then `SaveBindings(GetCurrentBindingSet())`, so Options > Keybindings shows them
- **Nothing is ever overwritten** (`ns.Plan`): a row is written only when its chord runs nothing (`GetBindingAction(chord)` is `""`) and the action has at most one keybinding besides it (the keyboard key, which stays first: `SetBinding` adds a key after those the action has). Not written, red in the table: nothing bound to the keyboard key, the chord in another row too, the chord running another action, the action with two keybindings already. A chord that runs the action already is "bound" (green when this AddOn wrote it, orange when it was set in Options: the AddOn never removes that one)
- **Removing:** only keybindings this AddOn wrote (`written` in the saved settings, per keybinding set), and only while the chord still runs the action it wrote; one changed in Options since is forgotten, never touched. A cleared or moved row, and `/fgr off` (`ns.RemovalPlan`), remove that way; `/fgr on` writes the saved table again
- Every read and write names the normal keybindings' context, `Enum.BindingContext.None` (`GetBindingAction(key, false, None)`, `GetBindingKey(action, nil, None)`, `SetBinding(chord, action or nil, None)`): while the Gamepad UI's context is active, a call without one may answer the Gamepad UI's own action for a pad key (review round 2), and the plan, the overrides and the removal all rest on the normal ones
- Each write and removal is read back with `GetBindingAction` before it counts (an error line otherwise)
- **The right mouse button's row:** a keybinding cannot click a mouse button, so its chord (LT + X) runs Interact With Mouseover (`INTERACTMOUSEOVER`, `Blizzard_FrameXML/Bindings_Camelot.xml`: the unit under the cursor, else the soft target); no right click on the interface (a bag item is not used by it). When Interact With Mouseover has no key, the chord is its first keybinding
- **Combat:** `SetBinding`, `SaveBindings` and the override functions are never called in combat (`InCombatLockdown()`): Save keeps the rows waiting and says so, `/fgr on` / `off` and the overrides change at `PLAYER_REGEN_ENABLED`
- No keybinding is written at login: the table reaches a keybinding set only by Save or `/fgr on`. Turning the AddOn off in the AddOn list leaves what it wrote in place (only `/fgr off` removes it)
- The AddOn changes no CVar

## The override keybindings

- Owner: the AddOn's frame `ForeverGamepadRebindOwner`; `ClearOverrideBindings(owner)` then `SetOverrideBinding(owner, true, chord, action)` for every row whose chord runs its action in the normal keybindings, so the table wins over the Gamepad UI's context
- **Blocked keys:** with the Gamepad UI on and `block` set, the triggers' keys (`PADLTRIGGER` and `PADRTRIGGER`, alone and with the other modifier held, `ns.TRIGGER_KEYS`) click the do-nothing button `ForeverGamepadRebindBlocker` while a bound chord holds that trigger, so LT and RT do not switch the Gamepad UI's action sets. LB and RB are rows of the table themselves
- **Gamepad menus:** while the Gamepad UI's binding stack holds more than its core set (`GamepadSharedUtility.InputBindingManager:IsOnlyCoreBindingSetActive()` false: a window it navigates), all overrides are cleared, so the pad works the menu; they come back when it closes. The AddOn post-hooks the manager's `AddBindingSet`, `RemoveSet`, `ClearBindings` and `AssumeCoreBindingsAreUsable` (`hooksecurefunc`, nothing replaced) and checks every 0.5 s (`C_Timer.NewTicker`) as a safety net; in combat the change waits for its end
- Set again (only when the set changed, compared as one signature text, so `UPDATE_BINDINGS` from its own calls ends there) at `PLAYER_LOGIN`, `PLAYER_ENTERING_WORLD`, `BINDINGS_LOADED`, `UPDATE_BINDINGS`, `INPUT_DEVICE_INTERFACE_TRANSITION`, after Save and option changes
- Options: `override` off sets none (the rows are then plain keybindings, which fire only without the Gamepad UI), `block` off blocks no trigger

## The window

- `BasicFrameTemplateWithInset`, strata `HIGH`, movable (its place saved), closes with Escape (`UISpecialFrames`); not keyboard-enabled, so the game stays playable while it is open
- Columns: keyboard key, the action it runs now (`GetBindingName`; the icon of an action bar slot, `C_ActionBar.GetActionTexture` of the button's `action`, read only), the gamepad cell `ForeverGamepadRebindFrameChord<n>` with its clear button `...Clear<n>`, the status (full text in its tooltip)
- **Pressing a chord:** a click on a cell sets `EnableGamePadButton(true)` on the window (Blizzard's binding buttons do the same, `Blizzard_SharedXML/CustomBindingButtonMixin.lua`) until a pad button comes in `OnGamePadButtonDown` (a trigger only marks itself held; LT held = `SHIFT`, RT = `CTRL`, also read from `IsShiftKeyDown` / `IsControlKeyDown`), a second click, the window hiding or 10 s pass. **Right-click** on a cell: the pick list (`MenuUtil.CreateContextMenu`): the buttons alone, with LT, with RT, or none
- Save (`...Save`), Revert (`...Revert`) drops the edits, Reset to default layout (`...Reset`) puts `ns.DEFAULT_ROWS` into the edits (Save writes it); the state line names unsaved edits, a Save waiting for the end of combat, the AddOn off, a gamepad menu holding the pad, and the keybinding set Save writes into

## `/fgr debug`

Prints the state once (interface style, the context, the gamepad, the keybinding set, the overrides and blocked keys and why none, the CVars `InputDeviceInterfaceStyle`, `GamePadEnable`, `GamePadEmulateShift`, `GamePadEmulateCtrl`, `GamePadEmulateAlt`, `GamePadCursorLeftClick`, `GamePadCursorRightClick` (read only, "missing" when the client has none), the context's keys of the Gamepad UI's trigger and shoulder actions, the table's counts), then every pad button that goes down until it is typed again: the chord with the modifiers held and what it runs with the overrides, in the normal keybindings and in the Gamepad UI's context. It reads `C_GamePad.GetDeviceMappedState()` from `OnUpdate`, so it takes no input from the game (`ButtonIndexToBinding` is called 0 based, like Blizzard's `StickIndexToConfigName`)

## Saved settings

- `ForeverGamepadRebindSettings` (account): `enabled`, `override`, `block` (booleans, default true), `rows` (`{ [keyboard key] = chord or "" }`, every key of the table; a broken chord takes its default), `written` (`{ account = { [chord] = action }, ["char:Name-Realm"] = {...} }`; an empty set is left out), `window` (`point`, `relPoint`, `x`, `y`); cleaned at load
- Defaults (the settings page's button) resets the options, not the rows
