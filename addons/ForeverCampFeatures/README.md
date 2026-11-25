# Forever Camp Features

An AddOn for **WoW: Forever** that tells you when a camp object is near: a campfire, Cookie's Feast, the Iron Oven, the Tanning Rack, a forge, a loom and every other camp feature of Forever's camping. It shows where the object is, puts a [TomTom](https://www.curseforge.com/wow/addons/tomtom) arrow on it, and shares what it finds with the other players who run it.

You can use another player's camp object when you know the recipe that needs it (an Iron Oven for the most advanced cooking recipes, a Master Forge, an Arcane Forge, ...). Placed objects only stay about 15 minutes, so knowing where one stands right now is what counts.

## How it finds objects

The game gives AddOns no list of the objects around you, so the AddOn learns about them in three ways. Each has its limits.

| Way | Range | What it needs | Limits |
| --- | --- | --- | --- |
| **In range** | Where you stand | A recipe you know that needs the object nearby ("Requires: Iron Oven") | Only objects a recipe of yours needs; open each profession window once so the AddOn learns your recipes. Anvils are skipped: a city anvil answers the same |
| **Hover** | As far as you can see | Point your cursor at the object | The game tells the AddOn the object's name, not where it is, so the place shown is where you stood, and the alert puts the coordinates in the chat instead of a TomTom waypoint. Anvils are skipped here too |
| **Shared** | The whole zone and beyond | Other players who run the AddOn | Only what others placed or found in range |

When you place a camp object yourself, or find one in range, the AddOn sends it to the other players who run the AddOn (see Privacy below); an object you stay in range of goes out again every 5 minutes, for players who arrive later.

## The alert

For an object in your current zone:

- A text on a grey rounded background, a quarter of the screen above its center (above your character), for example `Iron Oven at 38.5, 73.6, Ironforge`, with the distance and the age for a shared one; the font, its size, both colors and the place can be changed in the settings
- A sound, Raid Warning unless you pick another one of the game's sounds in the settings
- With TomTom: a waypoint on it. Without TomTom: the coordinates in the chat. An object found by hovering always gets the chat line instead of a waypoint: the game only tells the AddOn where you stood
- The same object alerts once. It alerts again when it moved, or after you left the zone and came back. An object that expired is dropped and its waypoint removed

Placing an object does not alert you at once; finding it in range or by hovering it does, like any other object.

## Privacy

With "Share the camp features I place or find" on (the default), the AddOn sends a short AddOn message whenever you place a camp object or find one in range (and every 5 minutes while you stay in range of it): **which object, the map, its coordinates and when it was placed or seen**. Nothing else is in the message. Other players' AddOns see your character as the sender, as with every AddOn message.

The messages go through a hidden chat channel the AddOn joins by itself (`ForeverCampFeatures`; it appears in no chat window). When the channel cannot be joined, they go to your guild and your party or raid instead. Turn sharing off in the settings to send nothing; turn "Show camp features others found" off to ignore what others send.

Like any chat channel, `ForeverCampFeatures` has a member list: anyone who joins it (`/join ForeverCampFeatures`) can see your character there, so they can tell that you run the AddOn and are online. The AddOn stays in the channel while either "Share the camp features I place or find" or "Show camp features others found" is on; with both off, or with `/fcf off`, it leaves the channel at once (in a fight, once the fight is over).

Disabling or deleting the AddOn does not leave the channel by itself: the game keeps the channels you joined and joins them again at every login. Type `/fcf off` before you disable it, or `/leave ForeverCampFeatures` once afterwards.

## Commands

| Command | What it does |
| --- | --- |
| `/fcf` (or `/campfeatures`) | Lists the known camp objects of your zone with their coordinates, distance and age |
| `/fcf on`, `/fcf off` | Enables or disables the AddOn without a reload |
| `/fcf test` | Shows a test alert |
| `/fcf options` | Opens the settings |
| `/fcf debug` | Prints what each way of finding objects sees right now (for bug reports) |
| `/fcf debug objects` | Prints every camp object with its item and placement spell |
| `/fcf help` | Shows the commands |

## Settings

`Esc -> Options -> AddOns -> Jim's Forever AddOns -> Camp Features`:

- Enable the AddOn
- Alerts: the text in the middle of the screen, the sound, and a TomTom waypoint instead of the coordinates in the chat (each on by default)
  - Sound: a list of every sound of the game, A-Z, that scrolls; picking one plays it, resting the mouse on one plays it after a moment, and the ▶ button next to it plays the chosen one. Default: Raid Warning. Greyed out while "Sound" is off
  - Under the text: Font (the game's fonts, plus LibSharedMedia's when another AddOn loaded it), Size (10-40, default 20), Text color, Background (color and opacity; opacity 0 shows no background; default grey at 50%). Move shows the alerts as a preview you drag anywhere; Done (or a right-click on the preview) keeps the place, Reset position puts it back a quarter of the screen above the center. Test shows a sample alert. All greyed out while the text is off
  - The page scrolls; Defaults (top right) also resets the sound, the look and the place
- Sharing: "Share the camp features I place or find" and "Show camp features others found" (both on by default), with a note on what is sent and who can see that you run the AddOn
- Features: every camp feature of every profession, each on or off (all on by default), one group per profession with a line between the groups
  - All on and All off switch every feature; a click on a profession's name switches that profession's features on, or off when all of them are on
  - Search: type a part of a name and every feature that does not match is greyed out, so the ones you look for stand out; a profession's name matches its whole group. The search only helps you find a feature: it changes no setting, and it is empty again when you leave the page

## Good to know

- Only English texts so far; every text is in `Locale.lua`, ready for translations
- Object names are read from your game client for every object whose recipe or item the AddOn knows, so hover and in range work in any client language; the Fishing, Herbalism, Mining and Skinning objects are matched by their English names for now
- The in-range check pauses in combat; whatever the game hides from AddOns (secret values) is skipped, never read
- TomTom is optional

## Bugs and ideas

Please report them on GitHub, not in the comments, so nothing gets lost:

- A bug: [bug report](https://github.com/matejkadlec/forever-addons/issues/new?template=bug_report.yml) (the AddOn's version, the game's version, what happened, and the output of `/fcf debug` when it is about finding objects)
- An idea: [feature request](https://github.com/matejkadlec/forever-addons/issues/new?template=feature_request.yml)

## License

MIT, see `LICENSE`. Source: https://github.com/matejkadlec/forever-addons
