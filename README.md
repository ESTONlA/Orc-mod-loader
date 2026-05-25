# OrcKit

OrcKit is a mod loader for **Sir, We Have an Orc Problem Playtest**.

It loads mods from the game folder, adds a native **Mods** button to the main menu, and provides a simple in-game UI for enabling mods and changing load order.

## Features

- Loads mods from the game's `mods` folder
- Supports `.pck` and `.vmz` mod packages
- Adds a native **Mods** button to the main menu
- Enable and disable mods from the OrcKit UI
- Load order controls
- Developer Mode for loose folder mod testing
- Uses `OrcLoader.gd` as the loader entrypoint

## mod template
https://github.com/ESTONlA/modmenu


## Supported Game

This loader targets:

```text
Sir, We Have an Orc Problem Playtest
```

Default Steam path:

```text
C:\Program Files (x86)\Steam\steamapps\common\Sir, We Have an Orc Problem Playtest
```

## Install

1. Download Release
2. Copy these files into the game folder:

```text
OrcLoader.gd
override.cfg
mod folder
```
4. Put `.pck` or `.vmz` mods into the `mods` folder.
5. Launch the game.

Mods folder:

```text
C:\Program Files (x86)\Steam\steamapps\common\Sir, We Have an Orc Problem Playtest\mods
```

## Using Mods

After OrcKit loads, the game's main menu gets a **Mods** button.

Use it to:

- enable or disable installed mods
- change load order
- open the mods folder
- toggle Developer Mode for loose folder testing

Higher load order values load later and win when multiple mods touch the same files.

## Mod Formats

OrcKit currently supports:

- `.pck`
- `.vmz`

Loose folder mods are available through Developer Mode.


## Repository

GitHub:

```text
https://github.com/ESTONlA/Orc-mod-loader
```

## License

OrcKit is source-available, but not open-source in the permissive redistribution sense.

You may use it personally and contribute to the project, but publishing, rehosting, repacking, or distributing OrcKit requires permission from Estonia.

See [LICENSE.md](LICENSE.md).

## Notes

- Keep `OrcLoader.gd` and `override.cfg` together in the game folder.
- If the loader does not appear in game, check that `override.cfg` contains:

```ini
[autoload]
OrcKit="*res://OrcLoader.gd"
```
