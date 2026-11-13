# Blind Driver

**One drives. One sees the way.** A playable, code-built Godot prototype of a two-player road trip through an endless low-poly forest.

The driver has extremely blurred vision. The navigator sits beside them, sees the road clearly, and unfolds a live map to give directions. Every approaching fork extends into more roads. One branch at each fork ends at a marked cliff. Read the map, watch the road, and survive as far as you can.

## Play it

1. Open **Godot 4.7** (developed and tested with 4.7.2).
2. Import this folder's `project.godot`, or open the project if it is already in your project list.
3. Press **F6** with `scenes/main.tscn` open, or **F5** from anywhere in the project.
4. For online play, agree on a **lobby name**, enter it on both computers, then choose **Drive** or **Navigate**. The name, last seat, and server address are saved on each computer. Either player can arrive first; the ride starts when both are there.
5. For offline play, choose **Play on this computer**, then **Two players / two windows**, **Two players / shared screen**, or **Solo practice**.

Local play needs no additional packages or accounts. Models, forest, terrain, map, UI, and engine audio are generated in GDScript. The Compatibility renderer is enabled. Internet rooms use the small Node relay in `server/`.

### Controls

| Input | Action |
| --- | --- |
| W / Up | Accelerate; brake first if reversing |
| S / Down | Brake; reverse once stopped |
| A D / Left Right | Steer |
| Space | Handbrake; loosens the rear tires |
| M / Tab | Navigator: unfold/fold map |
| C | Navigator/solo: switch seat and chase cameras |
| H | Headlights |
| V | Mute/unmute motor and tire audio |
| F | Fullscreen/windowed |
| F8 | Connection check, live network metrics, and logs |
| Escape | Menu; driver applies brakes while the menu is open |

Gamepad: left stick steers, right trigger accelerates, left trigger brakes/reverses, A applies the handbrake, Y toggles the map, and Start opens the menu. Keyboard and gamepad can be used together. **Settings** has the driver-blur slider. There is no recovery shortcut. Use **Start a new ride** in the pause menu if you overturn, or **Drive again** after Game Over; both reset the run and trip odometer.

Talk to each other in person or over your preferred voice call. The navigator sees only the top edge of a folded map at the bottom of their view. **M / Tab** slides it up to cover their entire screen (their half in shared-screen mode), so checking the map means looking away from the road. Red **X / CLIFF** marks a fatal dead end. Lakes and construction zones are mapped; small obstacles are not. The navigator must also watch the clear road view and call out rocks, trees, ramps, bumps, and cones.

## Two windows or two computers

**One computer:** choose **Play on this computer → Two players / two windows**. Your current game becomes the driver host; a second Godot process opens the navigator and joins `127.0.0.1` automatically. The two windows are placed side by side when running outside the editor. They use real WebSocket networking and separate worlds, with the driver owning physics and the navigator interpolating snapshots.

Click the driver window to drive and the navigator window to use its map; keyboard focus follows the active window. Both processes keep running when unfocused. You can move either window to another monitor. Closing the driver or changing its play mode closes the navigator it automatically launched; manually opened game instances are independent. Repeating the local co-op action resumes an already-connected pair.

If Godot embeds the running game in its editor, the driver remains in that Game panel while the navigator opens separately. Turn off the editor's Embed Game option if you prefer two floating windows. **Two players / shared screen** remains available for one-keyboard play without switching window focus.

**Two computers on the same network**, or manual two-instance testing:

1. Open **Settings → Advanced connection settings** in both games. These controls are only for direct LAN play; normal online play needs no IP or URL entry.
2. In the first game instance, choose **Direct LAN / host driver**.
3. In the second instance, enter **127.0.0.1** and choose **Direct LAN / join navigator** if both run on this computer. `127.0.0.1` means “this same computer.”
4. On another computer on the same network, enter the host computer's local IP instead. Both computers need the same project version and Godot.

The host listens on TCP port **18765**. A second host on the same port will show an error. A third player is rejected. The operating system may ask to allow Godot's local network connection. Use split-screen when sharing one keyboard; separate windows have normal desktop keyboard-focus behavior.

The driver owns physics. The navigator receives 30 snapshots per second, renders with a 100 ms interpolation buffer, receives road graph changes, and snaps to the start when a new ride begins. Connection failures/stalls are shown on screen. A disconnected LAN navigator automatically retries its host for up to two minutes; restarting the host creates a new world. This is a local development connection, not a deployed public service.

For **different networks**, use the lobby name and **Drive / Navigate** buttons on the start screen. The online server is already configured as **https://blind-driver-relay.onrender.com** and is hidden under advanced settings. Names ignore case and treat spaces like hyphens: `Forest Friends` and `forest-friends` enter the same lobby. Use 3–40 letters, numbers, spaces, or hyphens. No code or link needs to be copied between rides. Follow [deployment.md](deployment.md) to update or deploy the backend. Both clients connect outward to the relay; no router port forwarding is needed. This path uses an explicit JSON protocol, while the direct LAN mode retains native Godot RPC.

**This revision requires protocol 4 on Render and both clients.** Deploy the updated backend before online play; protocol 4 adds reusable named lobbies and lets the navigator wait for the driver. This change does not deploy Render. The backend retains both seats through temporary disconnects and the games automatically reconnect and resync. A server or game-process restart ends the current run, but the same locally saved name works for the next ride. Lobby names are rendezvous points, not saved games or permanent reservations. A seat from a crashed client can remain reserved for up to two minutes.

Press **F8** for a 75-second connection test, live latency/retry metrics, and **Open network logs folder**. The deployed server also provides `/diagnostics` for a browser-based check. Client JSONL logs and Render's structured logs record timeouts, close codes, retries, validation failures, and stalls. See [connection checks and logs](deployment.md#connection-checks-and-logs) for instructions. Browser export and browser invite links remain future work. The original architecture research is preserved in [docs/ONLINE_PLAN.md](docs/ONLINE_PLAN.md).

### Command-line launch

Replace `godot` with your Godot executable. On this Mac it is currently `/Users/aa/Downloads/Godot.app/Contents/MacOS/Godot`.

```sh
godot --path .
godot --path . -- --solo
godot --path . -- --split
godot --path . -- --local-coop

# Run these in two terminals for a local network session:
godot --path . -- --host
godot --path . -- --join=127.0.0.1
```

## What's in the prototype

- A physical 1,050 kg car with four raycast suspension springs, tire grip, rear-wheel handbrake slip, braking, reverse, aerodynamic drag, and a low center of mass. It can bounce, slide, collide, and overturn. Starting a new ride resets the car and score.
- Gravel and off-road grip/rolling resistance, physical road surfaces, gentle hills, collidable trunks and rocks, working steering/wheel visuals, primitive occupants, headlights, and synthesized engine/tire sound.
- Two independent seat cameras sharing one simulation, a low-resolution blurred driver render, a clear navigator render, a heading-relative map, and a solo chase view.
- A survival run: wrong forks end in bounded 24 m pits, roadside lakes are fatal, and Game Over reports the distance driven. The driver can restart with **Drive again** without leaving the room. There is no recovery key or gamepad binding.
- Faster acceleration and a 158 km/h engine cutoff (about 111 km/h sustained on a flat test road), physical boulders, tree chicanes, half-width ramps that can overturn the car, speed bumps, and construction cones/barriers. Obstacles are static and collide; they are not independently simulated debris.
- A seeded branching road graph. Roads grow near the car, distant sections are removed, and forest tiles load incrementally. Trees use MultiMesh rendering; nearby-road queries use a spatial index.
- A streamlined lobby/start menu, analog 0–160 km/h speedometer, mechanical-style trip odometer, route prompts, fullscreen, gamepad support, and local networking. The trip counter shows kilometers driven in this run; it resets for a new ride.

## Development flow

Agents should read [AGENTS.md](AGENTS.md) for branch ownership, merge compatibility,
and playtesting from the latest `main`. Upcoming gameplay ideas are recorded in
[docs/NEXT_STEPS.md](docs/NEXT_STEPS.md); they are not implemented yet.

The project intentionally builds almost everything in code. The editor's main scene is a small entry point, so an empty-looking 3D editor is expected: **run the project to see the world**.

| File | Responsibility / useful tuning |
| --- | --- |
| `scenes/main.tscn` | Entry scene |
| `scripts/main.gd` | Lighting, cameras, inputs, modes, route instructions |
| `scripts/car.gd` | Car geometry and physical controller; spring, damping, grip, engine and steering tuning |
| `scripts/procedural_world.gd` | Road graph, terrain, forest streaming, collision, world seed |
| `scripts/road_hazards.gd` | Physical obstacles, bounded cliff pits, and lakes |
| `scripts/geometry.gd` | Shared low-poly mesh/material helpers |
| `scripts/game_ui.gd` | Remembered lobby menu, settings, and split-screen interface |
| `scripts/dashboard.gd`, `scripts/lobby_settings.gd` | Speed gauge, trip odometer, and local lobby preferences |
| `scripts/route_map.gd` | Navigator's map |
| `scripts/session.gd` | Direct/relayed sessions and shared snapshot interpolation |
| `scripts/relay_client.gd`, `scripts/wire_protocol.gd` | Resumable internet rooms, diagnostics, and explicit JSON state protocol |
| `scripts/network_log.gd` | Rotating per-process network event logs |
| `server/`, `render.yaml` | Node relay and Render deployment configuration |
| `scripts/engine_audio.gd` | Procedural engine/tire audio |
| `shaders/driver_blur.gdshader` | Driver's vision |

Edit a script, save, stop the running game, and press F5 again. Start with Solo practice to tune the handling, then test the same change with two people in local co-op. Use the Debugger and Output panels for errors. Godot's generated `.godot/` cache stays out of Git; script `.uid` files belong in Git.

### Verification

```sh
# Physics, steering, braking, recovery, streaming, and real two-process networking:
python3 tests/run_checks.py

# Add the public-relay transport to the local integration checks:
npm --prefix server ci
npm --prefix server test
python3 tests/run_checks.py --relay

# Sustained drive with forced failures for both seats:
python3 tests/run_checks.py --resilience

# Set the executable explicitly if needed:
GODOT=/path/to/godot python3 tests/run_checks.py

# Just the fast driving/streaming checks:
godot --headless --path . --fixed-fps 60 --script tests/drive_smoke.gd
```

The checks bind only to localhost and close their test processes afterwards. They also verify saved lobby settings, name-based joining in either order, removed recovery controls, dashboard values, map animation and screen coverage, physical falls and lake deaths, ramp overturns, higher sustained speed, hazard serialization, and matching Game Over/restart state after navigator reconnection over LAN and relay. They cover the automatic second-window launcher as well as physical behavior and real snapshot delivery. Add `--relay` to test the Node relay too. Manual playtesting is still necessary to judge handling and camera comfort.

## Prototype boundaries

This is an early handling/cooperation sandbox. Roads can cross or overlap; there are no traffic systems, car-part damage, save games, or finish line. Ordinary obstacle collisions can spin or overturn the car; fatal pits/lakes end the run. Use the pause menu to start a new ride if the car is stuck or overturned. Generation favors forward travel; old roads beyond the retention distance are discarded rather than saved, so it is not a persistent world to backtrack through forever. Very long runs still use ordinary floating-point world coordinates. The world seed is currently a code constant.

The next useful milestone is deploying the relay using [deployment.md](deployment.md) and testing from two different networks. Then improve handling/junctions and verify a real browser export.
