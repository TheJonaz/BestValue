# Changelog

## 1.3.0 - 2026-10-20

- Sell dungeon and raid loot: items you loot in a dungeon or raid can be queued for the next vendor.
  Choose the mode in `/bv`: Off, Ask per item (a popup with Sell at vendor / Keep) or Automatic.
- Choose which qualities count: Poor, Common, Uncommon, Rare/Epic. Quest items and items
  that can't be sold are skipped.
- "Sell at vendor" checkbox above group loot roll frames: if you win the item, it is sold at the next vendor.
  Starts checked in Automatic mode for the selected qualities.
- Titan Panel tooltip shows the dungeon/raid loot mode.
- One release zip for every game version: Retail reads `BestValue_Mainline.toc`, Forever and Classic read `BestValue.toc`.
- Releases are uploaded automatically to CurseForge, Wago and WoWInterface (BigWigs Packager).

## 1.2.0 - 2026-10-16

- New settings window (`/bv`): movable, closes with Escape, also available under Options -> AddOns.
- New options: highlight best reward, show sell values, announce in chat, check the sell box by default.
- Titan Panel support (LibDataBroker): shows auto-sell state or queued value; click for settings,
  shift/right-click to toggle auto-sell. Also works with ChocolateBar, Bazooka and ElvUI.
- Separate release zips for Forever and Retail (`build.sh`).
- Retail: Best Value is listed in the AddOn Compartment menu next to the minimap.
- Sell queue overview with item icons, values and total; right-click to remove an item or clear the whole queue.

## 1.1.0 - 2026-10-16

- New checkbox on the quest turn-in window: "Sell chosen reward at next vendor".
  The chosen reward is sold automatically the next time you open a vendor.
- Auto-sell can be enabled/disabled under Options -> AddOns -> Best Value, or with `/bv autosell`.
- `/bv` (or `/bestvalue`) opens the settings.

## 1.0.0 - 2026-10-15

Initial release.

- Highlights the quest reward that sells for the most at a vendor with a gold coin.
- Shows the sell value (price × quantity) on each choice, or "Not sellable".
- Works both when turning in the quest and in the quest log.
- Prints the best choice in chat on turn-in.
- Waits for item data from the server and recalculates automatically.
- Supports World of Warcraft: Forever (16001) as well as Classic and Retail clients.
- Custom logo in the AddOns list.
- MIT license.
