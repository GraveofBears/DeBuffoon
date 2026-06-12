# DeBuffoon

**DeBuffoon** is a lightweight, high-performance debuff tracker for World of Warcraft (Classic/TBC era). It allows you to track specific debuffs on your target and display a customizable overlay marker directly over your action bar buttons or as a floating icon.

## Features
* **Action Bar Integration:** Automatically anchors tracking icons to specific spell buttons on your bars. If the spell disappears (e.g., swapping forms), the icon hides automatically.
* **Floating Icons:** If not attached to a button, icons can float anywhere on your screen.
* **Multi-Instance Tracking:** Track the same debuff multiple times to monitor its application across different abilities or positions.
* **Customizable Markers:** Choose from a variety of built-in raid icons and textures.
* **Configurable:** Simple `/dbf` interface to add, remove, and lock your trackers.

## Getting Started

### Installation
1. Download the repository as a ZIP file.
2. Extract the folder into your `World of Warcraft/_classic_/Interface/AddOns/` directory.
3. Ensure the folder is named **`DeBuffoon`**.
4. Log into the game.

### Usage
* **/dbf**: Opens the configuration window to add, remove, or modify your tracked debuffs.
* **/dbf lock / unlock**: Toggle edit mode. When unlocked, you can drag floating icons or use your mouse wheel to scale them.
* **/dbf debug**: Displays diagnostic info in your chat window to help troubleshoot missing buttons or debuffs.

### How to Attach to Spells
1. Open the configuration window (`/dbf`).
2. Add the name of the debuff you want to track (e.g., "Mangle").
3. In the "Attach to spell" column, type the exact name of the spell button currently on your action bar (e.g., "Mangle (Bear)").
4. If the button is found, the icon will automatically snap to it. If you swap bars or forms and the button disappears, the icon will hide until the spell is available again.

## Support & Feedback
If you encounter any issues or have feature requests, please open an issue in this repository.

---
*Created by GraveBear*
