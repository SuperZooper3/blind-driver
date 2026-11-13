# Blind Driver

**One drives. One sees the way.** A playable, code-built Godot prototype of a two-player road trip through an endless low-poly forest.

The driver has extremely blurred vision. The navigator sits beside them, sees the road clearly, and unfolds a live map to give directions. Every approaching fork extends into more roads. Both routes work; leave the road and you'll find grass, rocks, and solid trees.

## Play it

1. Open **Godot 4.7** (developed and tested with 4.7.2).
2. Import this folder's `project.godot`, or open the project if it is already in your project list.
3. Press **F6** with `scenes/main.tscn` open, or **F5** from anywhere in the project.
4. Choose **Start local co-op / two windows** to open an independent driver host and navigator client automatically. Choose **Shared screen** for the original split-screen view, or **Solo drive** for a clear chase camera while tuning the car.

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
| R | Recover onto the nearest road |
| H | Headlights |
| V | Mute/unmute motor and tire audio |
| F | Fullscreen/windowed |
| Escape | Menu; driver applies brakes while the menu is open |

Gamepad: left stick steers, right trigger accelerates, left trigger brakes/reverses, A applies the handbrake, Y toggles the map, Back recovers, and Start opens the menu. Keyboard and gamepad can be used together. The menu has a driver-blur slider.

Talk to each other in person or over your preferred voice call. The next-turn card gives the navigator a suggested route; the orange map line marks that branch. There is no penalty for choosing another road yet.

## Two windows or two computers

**One computer:** click **Start local co-op / two windows**. Your current game becomes the driver host; a second Godot process opens the navigator and joins `127.0.0.1` automatically. The two windows are placed side by side when running outside the editor. They use real WebSocket networking and separate worlds, with the driver owning physics and the navigator interpolating snapshots.

Click the driver window to drive and the navigator window to use its map; keyboard focus follows the active window. Both processes keep running when unfocused. You can move either window to another monitor. Closing the driver or changing its play mode closes the navigator it automatically launched; manually opened game instances are independent. Repeating the local co-op action resumes an already-connected pair.

If Godot embeds the running game in its editor, the driver remains in that Game panel while the navigator opens separately. Turn off the editor's Embed Game option if you prefer two floating windows. **Shared screen** remains available for one-keyboard play without switching window focus.

**Two computers on the same network**, or manual two-instance testing:

1. In the first game instance, choose **Host driver**.
2. In the second instance, enter **127.0.0.1** and choose **Join navigator** if both run on this computer. `127.0.0.1` means “this same computer.”
3. On another computer on the same network, enter the host computer's local IP instead. Both computers need the same project version and Godot.

The host listens on TCP port **18765**. A second host on the same port will show an error. A third player is rejected. The operating system may ask to allow Godot's local network connection. Use split-screen when sharing one keyboard; separate windows have normal desktop keyboard-focus behavior.

The driver owns physics. The navigator receives 30 snapshots per second, renders with a 100 ms interpolation buffer, receives road graph changes, and snaps on recovery. Connection failures/stalls are shown on screen; a disconnected navigator can rejoin the still-running host. A lost host requires hosting/joining again. This is a local development connection, not a deployed public service.

For **different networks**, use **Play online…** and the included Render-ready room relay. Follow [deployment.md](deployment.md) to deploy it, then have the driver create a room and the navigator join with its code. Both clients connect outward to the relay; no router port forwarding is needed. This path uses an explicit JSON protocol, while the direct LAN mode retains native Godot RPC.

The relay and game integration are tested locally; a public Render service has not been deployed yet. Browser export and browser invite links remain future work. The original architecture research is preserved in [docs/ONLINE_PLAN.md](docs/ONLINE_PLAN.md).

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

- A physical 1,050 kg car with four raycast suspension springs, tire grip, rear-wheel handbrake slip, braking, reverse, aerodynamic drag, and a low center of mass. It can bounce, slide, collide, and overturn; R recovers it.
- Gravel and off-road grip/rolling resistance, physical road surfaces, gentle hills, collidable trunks and rocks, working steering/wheel visuals, primitive occupants, headlights, and synthesized engine/tire sound.
- Two independent seat cameras sharing one simulation, a low-resolution blurred driver render, a clear navigator render, a heading-relative map, and a solo chase view.
- A seeded branching road graph. Roads grow near the car, distant sections are removed, and forest tiles load incrementally. Trees use MultiMesh rendering; nearby-road queries use a spatial index.
- A start/pause menu, speed/distance display, route prompts, recovery, fullscreen, gamepad support, and local networking.

## Development flow

The project intentionally builds almost everything in code. The editor's main scene is a small entry point, so an empty-looking 3D editor is expected: **run the project to see the world**.

| File | Responsibility / useful tuning |
| --- | --- |
| `scenes/main.tscn` | Entry scene |
| `scripts/main.gd` | Lighting, cameras, inputs, modes, route instructions |
| `scripts/car.gd` | Car geometry and physical controller; spring, damping, grip, engine and steering tuning |
| `scripts/procedural_world.gd` | Road graph, terrain, forest streaming, collision, world seed |
| `scripts/geometry.gd` | Shared low-poly mesh/material helpers |
| `scripts/game_ui.gd` | Menu and split-screen interface |
| `scripts/route_map.gd` | Navigator's map |
| `scripts/session.gd` | Direct/relayed sessions and shared snapshot interpolation |
| `scripts/relay_client.gd`, `scripts/wire_protocol.gd` | Internet rooms and explicit JSON state protocol |
| `server/`, `render.yaml` | Node relay and Render deployment configuration |
| `scripts/engine_audio.gd` | Procedural engine/tire audio |
| `shaders/driver_blur.gdshader` | Driver's vision |

Edit a script, save, stop the running game, and press F5 again. Start with Solo drive to tune the handling, then test the same change with two people in local co-op. Use the Debugger and Output panels for errors. Godot's generated `.godot/` cache stays out of Git; script `.uid` files belong in Git.

### Verification

```sh
# Physics, steering, braking, recovery, streaming, and real two-process networking:
python3 tests/run_checks.py

# Add the public-relay transport to the local integration checks:
npm --prefix server ci
npm --prefix server test
python3 tests/run_checks.py --relay

# Set the executable explicitly if needed:
GODOT=/path/to/godot python3 tests/run_checks.py

# Just the fast driving/streaming checks:
godot --headless --path . --fixed-fps 60 --script tests/drive_smoke.gd
```

The checks bind only to localhost and close their test processes afterwards. They cover the automatic second-window launcher as well as physical behavior and real snapshot delivery. Add `--relay` to test the Node relay too. Manual playtesting is still necessary to judge handling and camera comfort.

## Prototype boundaries

This is an early handling/cooperation sandbox. Roads can cross or overlap; there are no authored junction rules, traffic, goals, damage, save games, or strict route scoring. Generation favors forward travel; old roads beyond the retention distance are discarded rather than saved, so it is not a persistent world to backtrack through forever. Very long runs still use ordinary floating-point world coordinates. The world seed is currently a code constant.

The next useful milestone is deploying the relay using [deployment.md](deployment.md) and testing from two different networks. Then improve handling/junctions and verify a real browser export.
