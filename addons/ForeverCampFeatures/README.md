# Forever Camp Features

An AddOn for **WoW: Forever** that tells you when a camp object is near: a campfire, Cookie's Feast, the Iron Oven, the Tanning Rack, a forge, a loom and every other camp feature of Forever's camping. It shows where the object is, puts a [TomTom](https://www.curseforge.com/wow/addons/tomtom) arrow on it, and shares what it finds with the other players who run it.

You can use another player's camp object when you know the recipe that needs it (an Iron Oven for the most advanced cooking recipes, a Master Forge, an Arcane Forge, ...). Placed objects only stay about 15 minutes, so knowing where one stands right now is what counts.

## How it finds objects

The game gives AddOns no list of the objects around you, so the AddOn learns about them in three ways. Each has its limits.

| Way | Range | What it needs | Limits |
| --- | --- | --- | --- |
| **In range** | Where you stand | A recipe you know that needs the object nearby ("Requires: Iron Oven") | Only objects a recipe of yours needs; open each profession window once so the AddOn learns your recipes. Anvils are skipped: a city anvil answers the same |
| **Hover** | As far as you can see | Point your cursor at the object | The game tells the AddOn the object's name, not where it is, so the place shown is where you stood |
| **Shared** | The whole zone and beyond | Other players who run the AddOn | Only what others placed or found in range |

When you place a camp object yourself, or find one in range, the AddOn sends it to the other players who run the AddOn (see Privacy below); an object you stay in range of goes out again every 5 minutes, for players who arrive later.

## The alert

For an object in your current zone:

- A text in the upper middle of the screen, for example `Iron Oven at 38.5, 73.6, Ironforge`, with the distance and the age for a shared one, and a sound
- With TomTom: a waypoint on it. Without TomTom: the coordinates in the chat
- The same object alerts once. It alerts again when it moved, or after you left the zone and came back. An object that expired is dropped and its waypoint removed

Objects placed by you never alert you.

## Privacy

With "Share the objects I place or find" on (the default), the AddOn sends a short AddOn message whenever you place a camp object or find one in range (and every 5 minutes while you stay in range of it): **which object, the map, its coordinates and when it was placed or seen**. Nothing else is in the message. Other players' AddOns see your character as the sender, as with every AddOn message.

The messages go through a hidden chat channel the AddOn joins by itself (`ForeverCampFeatures`; it appears in no chat window). When the channel cannot be joined, they go to your guild and your party or raid instead. Turn sharing off in the settings to send nothing; turn "Show objects others found" off to ignore what others send.

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
- Alerts: the text in the middle of the screen, the sound, the TomTom waypoint (each on by default)
- Sharing: "Share the objects I place or find" and "Show objects others found" (both on by default)
- Objects: every camp object of every profession, each on or off (all on by default)

## Good to know

- Only English texts so far; every text is in `Locale.lua`, ready for translations
- Object names are read from your game client for every object whose recipe or item the AddOn knows, so hover and in range work in any client language; the Fishing, Herbalism, Mining and Skinning objects are matched by their English names for now
- The in-range check pauses in combat; whatever the game hides from AddOns (secret values) is skipped, never read
- TomTom is optional

## License

MIT, see `LICENSE`. Source: https://github.com/matejkadlec/forever-addons
