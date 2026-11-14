# Blind Driver

**One drives. One sees the way.** A playable, code-built Godot prototype of a two-player road trip through an endless low-poly forest.

The driver has extremely blurred vision. The navigator sits beside them, sees the road clearly, and unfolds a live map to give directions. Road choices include a longer, quieter route, a hazardous shortcut, cul-de-sacs, and marked cliffs. Through routes rejoin, and the next stretch gets harder as your trip grows. Read the map, watch the road, and survive as far as you can.

## Play it

**Browser:** open the deployed frontend URL and click **Get in the car**. One
player picks **Drive** or **Navigate** and presses **Create a room**, then shares
the 6-character code (or the invite link). The friend types the code and presses
**Join**, or just opens the link, and gets the other seat. No Godot
installation is needed. Solo and shared-screen play are also available; automatic
two-window and direct-LAN modes are desktop-only. See [Render browser deployment](deployment.md#add-the-playable-frontend-in-the-render-dashboard)
to add the frontend as a **Web Service / Docker** alongside your relay. The
[Railway setup](docs/RAILWAY.md) is also available.

**Desktop / editor:**

1. Open **Godot 4.7** (developed and tested with 4.7.2).
2. Import this folder's `project.godot`, or open the project if it is already in your project list.
3. Press **F6** with `scenes/main.tscn` open, or **F5** from anywhere in the project.
4. For online play, one player chooses **Drive** or **Navigate** and presses **Create a room**. Send the 6-character code that appears (for example `K7Q4MZ`; **Copy code** puts it on the clipboard). The friend types it into **Room code** and presses **Join**, and gets whichever seat is left. The ride starts when both are in. The preferred seat and server address are saved on each computer. After a run ends online, either player can press **Swap roles** on the Game Over card: both seats swap at once and the new driver starts a fresh ride.
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
| B (hold) | Navigator/solo: look behind and check police distance |
| H | Headlights |
| V | Mute/unmute motor, tire, and siren audio |
| F | Fullscreen/windowed |
| F8 | Connection check, live network metrics, and logs |
| Escape | Menu; driver applies brakes while the menu is open |

Gamepad: left stick steers, right trigger accelerates, left trigger brakes/reverses, A applies the handbrake, Y toggles the map, holding the right shoulder button (RB) looks behind, and Start opens the menu. Keyboard and gamepad can be used together. **Settings** has the driver-blur slider. There is no recovery shortcut. Use **Start a new ride** in the pause menu, or **Drive again** after Game Over; both reset the run and trip odometer while keeping your personal best. Landing on the roof/side ends the run automatically. A badly damaged car keeps driving, slowly, until three tires are broken (or the engine and two tires), which ends the run.

Talk to each other in person or over your preferred voice call. The navigator sees only the top edge of a folded map at the bottom of their view. **M / Tab** slides it up to cover their entire screen (their half in shared-screen mode), so checking the map means looking away from the road. Red **X / CLIFF** marks a fatal dead end. A circular **DEAD END / TURN AROUND** marks a solid cul-de-sac. Green **LONG / QUIETER** and amber **SHORT / HEAVY HAZARDS** routes rejoin; check the map to choose between extra distance and more dodging. Jump gaps, timed bridges, lakes, and construction zones are mapped; small obstacles are not. The navigator must also watch the clear road view and call out rocks, trees, ramps, bumps, and cones.

Hold **B / RB** or the on-screen **Hold to look back** button for the full passenger rear view. This folds the map and shows the patrol’s distance along the route, whether it is closing, and an approximate catch time at the current pace. Release to face forward again. The driver keeps their forward view in shared-screen play.

### Car damage

Crashes and thorns break the car. A damaged car limps on, slower and slower, but the police never follow you into the forest, so the car **breaks down and the run ends** once three tires are broken, or the engine is blown and two tires are broken.

Hits under about 13 km/h are harmless. Harder hits on rocks, trees, barriers and walls dent parts and play a crash sound on both seats. Damage grows faster than speed (like crash energy), and the bumpers soak up most of a hit while they last. The car is fragile: a 30 km/h hit dents the bumper, a 50 km/h hit tears it off, an 80 km/h corner hit knocks that wheel off, and one head-on hit at top speed wrecks the engine. A damaged part only looks and sounds worse. It costs nothing until it **breaks**:

| Part | When it breaks | Top speed afterwards (healthy: ~106 km/h) |
| --- | --- | --- |
| Tires (4) | **Thorns** tear any tire touching them; a tire pops flat (with a bang) after about 1 s in the brambles. A flat stays on the car but slides and pulls toward its side. A hard crash can knock a wheel right off instead, leaving the hub dragging and halving steering for a front wheel. Each broken tire also costs 15% of power and 12% of top speed. | 1 flat ~82 km/h, 2 flats ~62, 1 wheel lost ~64 |
| Engine (under the hood) | The hood flies off, the engine smokes and knocks, and power drops to 45%. | ~56 km/h; with 2 flats ~32; everything broken ~18 |
| Front bumper | Falls off. Front hits reach the engine, windshield and front wheels at full strength, and the headlights break. | |
| Rear bumper | Falls off. Rear hits reach the rear wheels at full strength. | |
| Windshield | Cracks spread across both seat views (blurred for the driver, like the road), then shatter into a hazy web. | |

Damage lasts the whole run. **Start a new ride** or **Drive again** gives you a fresh car. The driver's game decides the damage and sends it to the navigator in each snapshot. Tuning lives at the top of `scripts/car_damage.gd` (`SAFE_SPEED`, `CURVE`, `RATE`, breakdown penalties) and `scripts/car.gd` (`THORN_WEAR`, `FLAT_TIRE_DRAG`, `HUB_SCRAPE`).

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

The driver owns physics. It sends a small car pose (position, rotation, motion, steering) 30 times a second and the full state (police, damage, run state, crossing clock) 10 times a second, or at once when the run changes. The navigator does not wait for the past: it predicts where the driver's car is *now* from the latest pose, keeps it moving and turning through network stalls of up to 0.6 s, and eases any correction in over about 0.1 s instead of jumping. Police and other slow state are interpolated 200 ms behind. It receives road graph changes, and snaps to the start when a new ride begins. Connection failures/stalls are shown on screen. A disconnected LAN navigator automatically retries its host for up to two minutes; restarting the host creates a new world. This is a local development connection, not a deployed public service.

For **different networks**, use **Create a room** and **Room code / Join** on the start screen. The online server is already configured as **https://blind-driver-relay.onrender.com** and is hidden under advanced settings. Codes are 6 characters from an alphabet without lookalikes (no 0/O or 1/I/L). Typing ignores case, spaces and dashes. In the browser, **Copy invite link** gives `https://…/?room=K7Q4MZ`; opening it loads the game and joins that room. Desktop builds accept `-- --room=K7Q4MZ` on the command line. Follow [deployment.md](deployment.md) to update or deploy the backend. Both clients connect outward to the relay; no router port forwarding is needed. This path uses an explicit JSON protocol, while the direct LAN mode retains native Godot RPC.

**This revision requires protocol 10 on Render and both clients.** Deploy the updated relay **and** browser frontend before online play. Protocol 10 adds WebRTC peer-to-peer negotiation; protocol 9 added short room codes, choosing your seat when creating a room, seat assignment on join, and swapping seats between rides (the relay swaps seats, including their reconnection credentials; the new driver's game takes over the physics). Route profiles, rejoining connections, heat levels, the shared crossing clock, patrol, hazards and car damage are unchanged. The relay still accepts the older lobby-name messages, but the game no longer shows them. This change does not deploy Render. The backend retains both seats through temporary disconnects and the games automatically reconnect and resync. A server or game-process restart ends the current run; create a new room for the next ride. Room codes are rendezvous points, not saved games or permanent reservations; a code stops working when its room closes. A seat from a crashed client can remain reserved for up to two minutes.

**Which version am I on?** The header (top left) and the start screen show **PROTOTYPE NN**. Every change merged to `main` increases it by one (see `AGENTS.md`). Before playing together, check you both see the same number. Once you are in a room, the start screen also tells you if your partner is on a different version.

**Direct connection (peer-to-peer): smoother online play.** Turn on **Direct connection (peer-to-peer)** on the **start screen, under the room code box** (not in Settings; Settings → Advanced only has the older manual LAN buttons). Either player can turn it on, also mid-ride from the pause menu; the partner's game follows and the choice is remembered. The relay is still used to meet and to negotiate, then the car's data goes straight between the two games and the header shows `DIRECT LINK / …`. If the link drops, the game falls back to the relay at once and keeps retrying. Which kind of link depends on where you both play:

- **Both in the browser (the main way to play): WebRTC.** The games trade WebRTC offers and network candidates through the relay, then talk browser to browser. Poses travel on an unordered, no-retransmit channel (like UDP), so one late message never holds up newer ones; the road map uses a reliable channel. It works on the same network, and often across different networks too, using Google's public STUN server (`stun.l.google.com`) to discover addresses; very strict networks can still block it, and then the relay carries the game as before. Browser traffic is encrypted by WebRTC.
- **Both in the desktop game: local network link.** Each game sends its private IPv4 addresses (such as `10.0.33.210`), a port in 18770–18779 and a random key through the relay. Then **both games listen and both try to connect**, so it works even when only one direction is allowed, common when one Mac's firewall is in stealth mode. Same network only, not encrypted. (Desktop Godot has no built-in WebRTC.)
- **One in the browser, one on desktop:** no direct link is possible; the game says so and uses the relay.

The browser build publishes a read-only `window.blindDriverStatus` (version, seat, room, link type, updates received) for checking a session from the developer console.

If the desktop link never connects: on each Mac, check **System Settings → Network → Firewall**. When macOS asks whether Godot (or Blind Driver) may accept incoming network connections, choose **Allow**. Only one of the two computers needs to accept connections. Some guest/office Wi-Fi networks block traffic between devices entirely ("client isolation"); then the relay is the only option.

Press **F8** for a 75-second connection test, live latency/retry metrics, and **Open network logs folder** (**Download network logs** in the browser). The deployed server also provides `/diagnostics` for a browser-based check. Client JSONL logs and the relay's structured logs record timeouts, close codes, retries, validation failures, and stalls. See [connection checks and logs](deployment.md#connection-checks-and-logs) for instructions. Browser export and Railway hosting are configured in [docs/RAILWAY.md](docs/RAILWAY.md); room invite links remain future work. The original architecture research is preserved in [docs/ONLINE_PLAN.md](docs/ONLINE_PLAN.md).

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
- Breakable wheels, hood, bumpers and windshield. Each one has health, its own handling penalty, and debris when it breaks.
- Two independent seat cameras sharing one simulation, a low-resolution blurred driver render, a clear navigator render, a heading-relative map, and a solo chase view.
- A survival run: wrong forks end in broad, 36 m deep ravines (up to 160 × 112 m), with broken rims, layered rock walls around the whole drop, and rubble below, roadside lakes are fatal, and Game Over reports the distance driven. The driver can restart with **Drive again** without leaving the room. There is no recovery key or gamepad binding.
- Faster acceleration and a 158 km/h engine cutoff (about 111 km/h sustained on a flat test road), physical boulders, tree chicanes, half-width ramps that can overturn the car, speed bumps, and construction cones/barriers. Roadside clutter is static and collides; it is not independently simulated debris. Each road's obstacles are seeded but random: their kinds, spacing and shoulder side change from road to road. Roads are one continuous surface through bends, with a round pad where branches meet.
- Two arcade crossing challenges alternate on clear, straight connector roads. A full-width ramp launches you over a 16 m gap: line up and approach at **65+ km/h** for a forgiving takeoff assist, then land using the normal car physics. A sliding bridge initially opens for six seconds in a twelve-second cycle, warns for the last two seconds, and retracts sideways to expose a real pit. Roadside signals, the navigator’s route card, and live map markers show when to go. Miss either crossing and you fall, crash, and receive Game Over. The patrol jumps the ramp and waits for the bridge too.
- Bridge motion, lights, map countdowns, and failure states follow the driver’s run clock, interpolated with the car on the navigator. Driver menus, connection recovery, and Game Over pause the clock; starting a new ride resets it. These challenges replace ordinary clutter on their road, leaving room to line up or wait.
- Dense thorn bushes start roughly 18 m from the road center, leaving room to dodge obstacles on the shoulder. Deep-forest brambles wear down any tire touching them until it pops flat, slowing the car (see Car damage). Flat tires, part damage and the failure reason synchronize to the navigator.
- Roof and cabin collision protect the seats when the car flips. A car resting on its roof or side for 0.65 seconds ends the run; an airborne flip can still land safely.
- A seeded road graph with one growth frontier. After the introductory cliff fork, three-way junctions offer a longer, quieter road, a shorter road with more hazards, and a cul-de-sac or cliff. From the second three-way junction on, about 40% put a pit straight ahead in the middle, with both through routes swinging around it on either side. Both through routes rejoin the same continuation. Cul-de-sacs have a broad, solid turning circle and a no-through-road sign. Other forks offer one continuing road and a cul-de-sac. Dead ends and the forest cannot spawn extra routes. Distant sections are removed and forest tiles load incrementally. Trees use MultiMesh rendering; nearby-road queries use a spatial index.
- Five heat levels, shown on the dashboard, increase every **750 m** of trip distance, reaching level five at 3 km. New rough shortcuts grow from three to six obstacles while quieter alternatives grow from one to three. Future bridge windows shorten by half a second per level, down to four seconds. Existing road layouts and bridge timing stay fixed; restarting resets heat. The patrol also increases its normal cruising speed with distance.
- A police pursuit with an 85 m initial gap and a six-second head start. The patrol navigates the connected road network, takes rejoining routes, turns back through junctions if you change branches, steers around obstacles, and slows for bumps and bends. Its cruising speed starts at 50 km/h and rises steadily through the chase (about 1 km/h every 7 s) to a cap of 111 km/h, a healthy car's sustained top speed, so driving perfectly is never overtaken while damaged cars are eventually reeled in. A rubber band stops the lead growing: from about 150 m behind it starts matching your pace, and by 240 m it is fully leashed (briefly up to 126 km/h to make up corners), so it stays at the back instead of being lost. It brakes earlier for obstacles and junctions at catch-up speed and does not teleport forward.
- Sirens grow louder with physical proximity and switch to a faster wail nearby. Police can catch you on the shoulder: capture reaches 24 m across the ground when they are within 14 m along your route and 4 m in height. Staying in that range for 2 seconds ends the run with **The police caught you**. Route and height checks prevent captures across separate branches or into a pit. Driver menus and connection recovery freeze pursuit. A new ride resets it. The patrol uses route steering and proximity capture.
- A streamlined lobby/start menu, analog 0–160 km/h speedometer, mechanical-style trip odometer, route prompts, fullscreen, gamepad support, and local networking. The trip counter shows kilometers driven in this run; it resets for a new ride. Your personal best stays visible on the start screen, dashboard, and failure screen, with a new-record callout. It is saved locally in `user://records.cfg` during the ride, on failure, on restart, and on a normal exit. Both players record the shared distance on their own computer; this is not a saved world or an online leaderboard.

## Development flow

Agents should read [AGENTS.md](AGENTS.md) for branch ownership, merge compatibility,
and playtesting from the latest `main`. Upcoming gameplay ideas are recorded in
[docs/NEXT_STEPS.md](docs/NEXT_STEPS.md); they are not implemented yet.

The first [visual-agent harness](docs/AI_HARNESS.md) runs one game engine with two complete seat views,
accepts keyboard inputs from both agents, and records a recap video with dialogue
and metrics. It supports scripted/Cohere agents, adjustable simulation speed, and
model/role/speed comparisons, a live terminal timeline for both agents, and recaps
that restore normal game speed. It includes a large-display profile with sound
captions, background conversation recaps, safety scoring, and local Stop/Restart
controls. The basic AI course restores roadside thorns and ends on four punctures.
Cohere runs default to Command A Vision in both seats at 25% speed, with up to 60 seconds
of game time, 200,000 tokens and 100 requests per run. The navigator is coached to
give actionable directions, respond to the driver, and reassess after crashes;
recent dialogue and accepted-control feedback accompany each screenshot.
The [research plan](docs/AI_HARNESS_PLAN.md) describes
the longer path toward reinforcement learning.

The project intentionally builds almost everything in code. The editor's main scene is a small entry point, so an empty-looking 3D editor is expected: **run the project to see the world**.

| File | Responsibility / useful tuning |
| --- | --- |
| `scenes/main.tscn` | Entry scene |
| `scripts/main.gd` | Lighting, cameras, inputs, modes, route instructions |
| `scripts/car.gd` | Car geometry and physical controller; spring, damping, grip, engine and steering tuning |
| `scripts/procedural_world.gd` | Road graph, terrain, forest streaming, collision, world seed |
| `scripts/road_hazards.gd`, `scripts/road_challenge.gd` | Physical obstacles, pits, ramp jumps, sliding bridge geometry and timing |
| `scripts/geometry.gd` | Shared low-poly mesh/material helpers |
| `scripts/game_ui.gd` | Room code menu, settings, and split-screen interface |
| `scripts/dashboard.gd`, `scripts/lobby_settings.gd`, `scripts/run_records.gd` | Speed gauge, trip odometer, local seat/server preferences, and persistent personal best |
| `scripts/route_map.gd` | Navigator's map |
| `scripts/session.gd` | Direct/relayed sessions and shared snapshot interpolation |
| `scripts/relay_client.gd`, `scripts/wire_protocol.gd` | Resumable internet rooms, diagnostics, and explicit JSON state protocol |
| `scripts/network_log.gd` | Rotating per-process network event logs |
| `server/`, `render.yaml` | Node relay and Render deployment configuration |
| `frontend/`, `export_presets.cfg`, `tools/export_web.sh` | Browser loading page, Web export, static server, and browser checks |
| `Dockerfile`, `server/Dockerfile`, `.railway/` | Railway frontend/relay containers and infrastructure blueprint |
| `scripts/engine_audio.gd`, `scripts/police_siren.gd` | Procedural engine/tire sound and distance-based stereo siren |
| `scripts/police_pursuit.gd` | Driver-owned patrol navigation, obstacle avoidance, gap estimates, and capture |
| `scripts/impact_audio.gd` | Synthesized crash and tire-pop sounds |
| `scripts/car_damage.gd` | Part health, impact zones, dents, breakdown penalties, debris; `SAFE_SPEED` and `RATE` tune how fragile the car is |
| `scripts/windshield_cracks.gd` | Crack overlay drawn over both seat views |
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

The checks bind only to localhost and close their test processes afterwards. They select a free LAN port through `BLIND_DRIVER_LAN_PORT` and set `BLIND_DRIVER_RECORDS_PATH` to a temporary file, so checks leave running games and your real PB alone. They also verify saved seat settings, room codes (creating as either seat, joining by code, typos and full rooms), swapping seats after a run over a real relay, navigator smoothness through a relay that injects realistic jitter and 0.15–0.75 s stalls (`tests/relay_jitter_server.mjs`, `tests/lag_report.py`: the shown car must stay within 3 m of the real one at the 99th percentile and freeze on under 5% of frames; the old interpolation scored 11.7 m and 10%), pose prediction maths, direct same-network links (both sides listening, and each side refusing incoming connections), removed recovery controls, dashboard values, map animation and screen coverage, physical falls and lake deaths, thorn tire wear and flats, crash damage, debris, crash/pop sounds and crippled-car speed, roof clearance, rollover failure, PB persistence, a single growth frontier with rejoining route choices, solid cul-de-sacs, heat progression, patrol navigation/avoidance/capture, rear-view controls, ramp overturns, successful and failed gap jumps, timed bridge crossings and falls, shared bridge motion after reconnect, higher sustained speed, hazard serialization, and matching patrol and Game Over/restart state after navigator reconnection over LAN and relay. They cover the automatic second-window launcher as well as physical behavior and real snapshot delivery. Add `--relay` to test the Node relay too. Manual playtesting is still necessary to judge handling and camera comfort.

## Prototype boundaries

This is an early handling/cooperation sandbox. There are no traffic systems, repair mechanics, saved worlds, or finish line. Obstacle collisions can spin or overturn the car; ravines, lakes, grounded rollovers, and police capture end the run; broken parts only slow the car down. Use the pause menu to start a new ride if the car is stuck. Generation favors forward travel; old roads beyond the retention distance are discarded rather than saved, so it is not a persistent world to backtrack through forever. Very long runs still use ordinary floating-point world coordinates. The world seed is currently a code constant.

Deploy the browser frontend and relay using [the Render guide](deployment.md)
or [the Railway guide](docs/RAILWAY.md), then test the public
frontend from two different computers/networks. Keep game tabs visible during a
ride; browsers throttle background tabs and the driver owns the simulation.
