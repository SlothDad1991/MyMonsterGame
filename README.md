# Monster Game (prototype)

A small multiplayer monster-catching game for family and friends, made in Godot 4.7.

## Play it
1. Open the project in Godot and press Play.
2. Type a name, pick a starter.
3. **Host on this computer** runs the shared world here (you play too).
   Others on the same Wi-Fi press **Join game** and type this computer's local IP (e.g. `192.168.1.20`).
   To test alone, run a second copy of the game and join `localhost`.

## Play online with family (phones)
1. On the PC: open the game, click **Host on this computer**.
2. Double-click `host_online.bat` (first time it installs Cloudflare's free tunnel tool).
   Copy the address it prints that ends in `.trycloudflare.com`. It changes every time you run it.
3. Everyone opens https://slothdad1991.github.io/mymonstergame/ on their phone
   (Share → Add to Home Screen to install it), pastes that address, and taps **Join game**.
The world only exists while the game and that window stay open on the PC.

## Controls
- Arrow keys / WASD, or the on-screen pad on touch screens.
- Walk into a wild monster in the tall grass to battle it. Use **Catch** to catch it.
- Tap another player: **Battle**, **Trade**, or **Watch** (when they are battling or trading).
- Tap yourself or press **Party** to see your monsters. Heal on the pink pad in town.

## Project layout
- `data/monsters.json`, `data/moves.json` – creatures and moves (edit freely; placeholder originals).
- `scripts/GameData.gd` – map, stats, type chart, placeholder monster drawing.
- `scripts/Net.gd` – all networking RPCs (WebSocket, so it also works from a browser build).
- `scripts/Server.gd` – the authoritative world: wild monsters, battles, trades, saves.
- `scripts/World.gd` – client view, movement and in-game menus.

## Dedicated server
`godot --headless --path . -- --server` (uses `PORT` env var if set, default 9080).
Saves are kept in Godot's `user://server_save.json` on the server machine.
