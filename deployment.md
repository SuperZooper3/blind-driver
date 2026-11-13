# Deploy Blind Driver on Render

This guide gets **two people on different internet connections playing the desktop game together**. Render runs a small relay; each player runs the Godot game on their own computer.

The existing relay is **https://blind-driver-relay.onrender.com**, now the game's default address. You can override it in the menu, through the saved preference, or with `BLIND_DRIVER_RELAY_URL`.

## Upgrade the existing service first

This revision uses **protocol 6** for the shared police pursuit, alongside punctured tires, ravines, named lobbies, navigator-first joining, and resumable seats. Both clients and the relay must be updated together. The backend is verified locally; this change does not deploy Render.

1. Push these commits to the branch linked to your existing Render service (`git push origin main` if it uses main).
2. Open **blind-driver-relay** in Render, then **Manual Deploy → Deploy latest commit**. Auto-deploy is off in the supplied configuration.
3. Wait for Live. Open [health](https://blind-driver-relay.onrender.com/healthz) and confirm `"ok":true` and `"protocol":6`.
4. Update/restart **both games** from this same revision. Old clients and old servers cannot use the new protocol together.
5. Both players enter the same **lobby name** on the start screen, then choose **Drive** or **Navigate**. The online server is already configured. The name is saved locally for next time.

No new service, database, router settings, or environment variables are needed. Deployment ends existing rooms, so do it between rides. The initial-service instructions below are retained for setting up another relay.

## 1. Understand what is being deployed

```text
Driver's Godot game                     Navigator's Godot game
  - Simulates the car                     - Shows the clear view
  - Generates the roads                   - Shows the map
           |                                       |
           +------ secure WebSocket connections ---+
                              |
                     Render Node.js relay
                  Rooms + forwarding game state
```

Both players initiate an outbound connection to Render. Nobody needs to open a port on their router. The relay does not run Godot, render graphics, or simulate the car. It pairs one driver with one navigator and forwards the driver's updates.

The networking modes are:

| Mode | Buttons | Address | Intended use |
| --- | --- | --- | --- |
| Automatic local pair | Play on this computer → Two players / two windows | Automatic `127.0.0.1` connection | Two independent game processes on this computer |
| Direct local connection | Settings → Advanced connection settings → Direct LAN | `127.0.0.1` or a local network IP | Same computer or same network |
| Online lobby | Saved lobby name → Drive / Navigate | Your Render service URL | Different computers, including different networks |

`127.0.0.1` always means **the computer you are using**. The automatic local pair uses the same networking path as the LAN mode, but traffic stays inside your computer instead of passing through the router. Giving that address to a friend does not connect them to your computer. For internet play, both of you use the configured online server and the same saved lobby name.

## 2. Get the code onto GitHub

The configured repository is [SuperZooper3/blind-driver](https://github.com/SuperZooper3/blind-driver). Render must have access to the branch containing the new files.

From this project folder, after reviewing your local changes:

```sh
git status
git push origin main
```

The implementation commits contain the deployment files. Check that `render.yaml` and `server/package-lock.json` are visible on GitHub before continuing. If your repository is private, authorize Render to access this repository when connecting GitHub.

## 3. Create the Render service

The shortest route is a **Blueprint**: Render reads the included [`render.yaml`](render.yaml) and fills in the service settings for you. This is Render's supported configuration-file workflow. [Render Blueprint reference](https://render.com/docs/blueprint-spec)

1. Open the [Render dashboard](https://dashboard.render.com/) and sign in or create your account.
2. Choose **New → Blueprint**.
3. Connect the `SuperZooper3/blind-driver` repository and select the branch containing these commits, normally `main`.
4. Use the repository-root `render.yaml` file.
5. Review the proposed **blind-driver-relay** service. The supplied plan is **Free**, with **Frankfurt** as the region. Change the region before creating the service if another region is closer to both players.
6. Create/deploy the Blueprint and wait for the service to become **Live**.
7. Copy the actual `https://…onrender.com` address from its dashboard. Render may add a suffix to the service name; use the address Render displays.

No database, disk, Docker image, Godot installation, or API key is required on Render.

### Manual setup instead of a Blueprint

If you prefer **New → Web Service**, use these same values:

| Setting | Value |
| --- | --- |
| Repository | `SuperZooper3/blind-driver` |
| Branch | `main` (or your deployment branch) |
| Runtime / language | Node |
| Root directory | `server` |
| Build command | `npm ci --omit=dev` |
| Start command | `npm start` |
| Health check path | `/healthz` |
| Instance plan | Free for the first test |
| Region | Frankfurt by default; choose near both players |
| Environment variable | `NODE_VERSION=24` |
| Environment variable | `NODE_ENV=production` |
| Environment variable | `MAX_ROOMS=100` |
| Environment variable | `MAX_CONNECTIONS=256` |
| Auto-deploy | Off initially |

The service reads Render's `PORT` environment variable and listens on `0.0.0.0`. HTTP health checks and WebSocket upgrades share that port, as Render requires. Do not set the public game address to port `18765` or `10000`. Render supplies the public HTTPS/WSS endpoint. [Render web services](https://render.com/docs/web-services), [WebSockets on Render](https://render.com/docs/websocket)

Node 24 is selected explicitly so a change to Render's default runtime does not switch the service to another major version. [Render Node version configuration](https://render.com/docs/node-version)

## 4. Check that the relay is awake

For the existing service, open:

```text
https://blind-driver-relay.onrender.com/healthz
```

Open that address in your browser. A ready relay returns:

```json
{"ok":true,"protocol":6,"instance":"example-instance","uptime_seconds":123}
```

Or check from Terminal:

```sh
curl --fail https://blind-driver-relay.onrender.com/healthz
```

The base URL returns a small JSON service description. **That is expected: this URL is the backend, not a playable webpage.**

A free service can sleep after inactivity and take roughly a minute to wake. Open `/healthz` and wait for the response before your first game. A failed initial game connection during wake-up can be retried. For less waiting, consider a paid service instance after checking the current price and usage allowances. Free services have restart, usage, and availability limits. [Render free-service limitations](https://render.com/docs/free)

## 5. Give both players the updated game

For the first online playtest, the simplest approach is:

1. Both players install the same Godot version used by this project, **4.7.2**.
2. Both get the same revision of this project, through Git or a project ZIP.
3. Both import `project.godot`, open the project, and press **F5**. On some Macs, use **Fn+F5**.

The friend does **not** need Node, npm, a Render account, or access to your Render dashboard. Those are for deploying/developing the relay, not playing.

You can later distribute exported desktop builds instead of the source project: install matching export templates in Godot, add a desktop target under **Project → Export**, and export into `builds/`. Distribute all files produced by that export. Each platform has its own packaging/signing requirements; using Godot on both machines avoids making that a prerequisite for this first test. [Godot exporting projects](https://docs.godotengine.org/en/stable/tutorials/export/exporting_projects.html)

## 6. Connect the two players

1. Agree on a lobby name, such as `forest-friends`. Use 3–40 letters, numbers, spaces, or hyphens. Names ignore case and treat spaces as hyphens.
2. Enter that name on both start screens. One player chooses **Drive**, the other **Navigate**.
3. Either player can arrive first. The lobby waits for the other seat, then opens the ride automatically.
4. Next time, the lobby name, preferred seat, and server address are already remembered locally. Choose your seat again; no code or link needs pasting.

The server URL is under **Settings → Advanced connection settings**. Leave it at the default unless you run another relay. Both computers must use the same server. The game accepts HTTPS/WSS URLs for public play and HTTP/WS for localhost, adding `/ws` automatically.

The name identifies a meeting place, not a saved world or permanent account. Leaving as the driver closes the active ride; a later visit creates a fresh room using the same name. A relay restart also ends the run, but both clients retain their name. A crashed client’s seat stays reserved during the existing two-minute recovery window. Another player who knows the name can join a vacant seat.

Preferences are stored in Godot’s `user://network.cfg` on each computer. Resume credentials remain in memory and are not written there. Cancel or leave keeps the saved name. Clear or change the name on the start screen to choose another lobby.

Use a voice call or talk in person; voice chat is not built into the game.

## 7. Do a first internet playtest

Use two computers, ideally on different networks, and check:

- The navigator sees the car move when the driver accelerates and steers.
- The navigator receives newly generated roads on the safe branch, and sees the same rocks, trees, ramps, bumps, construction, cliffs, and lakes.
- There is no R/gamepad recovery shortcut. **Start a new ride** in the driver’s pause menu resets both views and the trip odometer.
- Headlights, suspension, impacts, and car rotation remain in sync.
- Drive deep into the thorn forest: both players see punctured tires and the same failure reason. Roll onto the roof: the cabin stays above the ground and the failure screen appears after landing.
- Check the small rear-view mirror, then hold B / RB on the navigator: the full rear view reveals the patrol and its gap/closing estimate. The driver’s forward view stays unchanged.
- Both players should see the same patrol position and flashing lights, hear a louder siren as it approaches, and see the same police-capture Game Over. Pause on the driver or disconnect temporarily: pursuit must freeze instead of catching you during recovery.
- Each computer saves its own PB from the shared run distance. Restart and relaunch to check that the best remains while the trip resets.
- Drive over a marked cliff: both players see the fall, Game Over, and the same distance. Reconnect a navigator during Game Over and check that the result remains. Choose Drive again on the driver and confirm both return to the start in the same room.
- Temporarily interrupt either computer's network. The driver brakes once the outage is detected; the navigator holds the last received view. The same running games reconnect automatically and resync the road/car state.
- A silent connection is detected after 15 seconds without application heartbeat replies. A clean socket failure is detected sooner. Let the connection return within the two-minute recovery window.
- **Cancel / leave lobby** is intentional: the driver ends the room; the navigator releases their seat. Closing/crashing the game loses its in-memory resume credential. A reserved navigator seat expires after two minutes; a closed driver cannot recover the ride after restarting the application.

The driver's physics stays local and responsive. The navigator sees an interpolated view with network delay; testing from separate networks is still necessary to judge how well spoken directions work.

## Updates, restarts, and costs

Auto-deploy is initially off so every code push does not interrupt an active drive. To deploy a backend change:

1. Run the checks below.
2. Commit and push the change to the linked branch.
3. In the Render service, choose **Manual Deploy → Deploy latest commit**.
4. Wait for Live, check `/healthz`, and join your saved lobby again.

Keep this service at **one instance**. Rooms live in that process's memory. Multiple instances would need shared room coordination, because two clients can otherwise reach different instances. A restart or deployment ends active rooms; temporary connection recovery works only while the same server process and game processes remain alive. Render can also replace instances during platform maintenance. [Render WebSocket lifecycle and scaling behavior](https://render.com/docs/websocket)

The supplied Blueprint requests a Free instance. Review Render's current plan, included bandwidth, and account spending settings before changing it. Relayed game traffic counts toward outbound bandwidth. A free-tier service is suitable for an initial experiment, not a guarantee of uninterrupted availability. [Render pricing](https://render.com/pricing), [free limits](https://render.com/docs/free)

There are no accounts, saved games, automatic host migration, or public room listings. Empty rooms expire after 30 minutes. The relay checks payload sizes, state shapes, sending roles, message rates, and total capacity, and uses heartbeats to clean up dead connections. These are prototype safeguards, not a complete production abuse-prevention system.

## Local development and verification

To run the same relay on your own computer:

```sh
cd server
npm ci
npm start
```

It normally listens at `http://localhost:10000`; the game accepts `http://127.0.0.1:10000` or `ws://127.0.0.1:10000/ws`. Open two game instances, set the local URL in advanced settings, and use the same lobby name with Drive / Navigate. Stop the relay with Ctrl+C.

From the repository root:

```sh
# Relay behavior: rooms, roles, invalid messages, capacity, and disconnects.
npm --prefix server test

# Existing driving and direct-LAN tests.
python3 tests/run_checks.py

# Also launch the Node relay and two Godot processes through a real room.
python3 tests/run_checks.py --relay

# 75-second drive with driver drop, navigator drop, and a silent traffic stall.
python3 tests/run_checks.py --resilience
```

If Godot isn't found automatically, set `GODOT` to its executable path. The integration checks bind only to localhost and clean up their test processes. The relay checks require `npm ci` in `server` first. Node 24 is the deployment target; the scripts also work with the existing local Node 20 installation.

The relay test does not verify Render's public TLS endpoint. That is covered by the health check and two-computer playtest after deployment.

## Connection checks and logs

**In either game:** press **F8** (on some Macs, Fn+F8), or open **Settings → Connection check & logs**. The panel shows live ride metrics and offers a separate **75-second connection check**. It uses the same WebSocket endpoint without occupying a room. You can run it during a ride. Keep the computer awake. Hiding the panel with F8 leaves a running check active; **Stop check / close** cancels it.

**In a browser:** open [the relay diagnostics page](https://blind-driver-relay.onrender.com/diagnostics), start the 75-second check, and use **Save results** to download JSONL events. Run it from each player's computer, keeping the tab visible. This page becomes available after deploying protocol 2. `/healthz` checks the running server; `/diagnostics` tests the actual WebSocket round trips.

**From a terminal**, including a server's shell or another machine with this repository and Node:

```sh
cd server
npm ci
npm run check -- https://blind-driver-relay.onrender.com 75
# Save JSONL output without npm's banner:
node check.mjs https://blind-driver-relay.onrender.com 75 > connection-check.jsonl
```

The CLI exits 0 for a completed check with sufficient replies and no missed probes, 1 for failed/interrupted checks, and 2 for invalid arguments. Run it locally against `http://127.0.0.1:10000` to test a development relay. A server checking itself does not measure a player's internet connection.

Latency is round-trip time; p95 is the slower end of recent replies, and jitter measures variation between them. Missed probes are replies that did not arrive within five seconds, **not a measurement of raw IP packet loss**. A high maximum game frame gap points to the game/computer stalling. A browser timer gap includes its normal one-second sampling interval. Low local latency cannot predict internet latency. “No interruption observed” describes only that test period; it does not guarantee the next drive.

### Client logs

Use **F8 → Open network logs folder**. Each game process writes timestamped JSONL files under Godot's `user://network_logs/`, alongside ordinary Godot console/output logs. On this Mac:

```text
~/Library/Application Support/Godot/app_userdata/Blind Driver/network_logs/
```

Files rotate at approximately 2 MiB. Old files are pruned when another log opens; recent files from other processes are retained for 24 hours so two clients do not delete each other's active logs. Logs contain process IDs, socket close codes/reasons, retry timing, send errors, heartbeat measurements, frame stalls, and periodic snapshot/graph counters. They never intentionally record room codes, resume tokens, or game payloads. Logs stay on the computer until you choose to share them.

### Server logs and interpreting a drop

Open the Render service's **Logs** view. The relay writes JSON events to standard output: each has a UTC timestamp and server instance ID. Connection IDs are also reported to the client, so you can correlate both sides. Room log IDs are separate from join codes. Connection summaries appear every 30 seconds; this is a logging interval, not a disconnect deadline.

| Event | Meaning / next check |
| --- | --- |
| `protocol_rejected` | A message failed size, rate, or state validation. The event includes the reason, message kind, and failing field; fix the offending client data. A 1008/1009 closure is shown instead of endlessly retrying invalid data. |
| `heartbeat_timeout` | No valid client traffic or control pong for 45 seconds. Check the client log for frame stalls and network loss. |
| `socket_closed` / `disconnected` | Actual close code. Godot -1 or WebSocket 1006 means no complete close handshake; inspect adjacent events rather than assuming a cause. |
| `reconnect_scheduled` / `seat_reserved` | Client is retrying; the server retains that player's seat for 120 seconds after disconnect detection. |
| `seat_resumed` / `ride_restored` | The original seat was restored and the game requests a fresh road graph and snapshots. |
| `backpressure_close` | A receiver is too slow. New snapshots are dropped before the queue grows; sustained congestion triggers recovery. |
| `event_loop_delay` / `client_poll_stall` | Server/game processing paused, which can resemble a bad network. |
| `shutdown`, changed instance ID, or `resume_expired` | Deployment, process restart, expired reservation, or invalid resume credential. A restarted server has lost its rooms; join the saved lobby again. |

For another unexplained drop, retain **both clients' logs** plus the Render logs from the same UTC minute. Note who was driving and whether either window froze. This distinguishes transport failures from a server rejection or a stalled game. The initial 75-second idle check against the public protocol-1 service survived; the reported active-driving drop was not conclusively reproduced, so these events are designed to capture its actual cause.

Recovery uses application heartbeats every two seconds, a 15-second client reply timeout, retry delays growing from roughly 1 to 8 seconds with jitter, and a two-minute retry budget after loss detection. The relay also sends control pings every 10 seconds and counts valid game traffic as liveness. Rate limits tolerate bounded delivery bursts after network jitter. Both seats use private in-memory resume credentials. Road state is resent after either seat returns; the navigator clears its old interpolation buffer. Direct-LAN navigators also retry their existing host for up to two minutes; restarting a LAN host creates a new world.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Render cannot find `package.json` | Root Directory must be `server`, or deploy the supplied Blueprint. |
| Render says no open port | Start command is `npm start`; don't override `HOST` to localhost. Inspect service logs. |
| `/healthz` is loading or unavailable | Give a free instance time to wake; inspect the latest deploy and runtime logs if it stays unavailable. |
| Game immediately disconnects from the public relay | Use the public HTTPS or WSS URL, not HTTP/WS. Don't append `:10000` or `:18765`. |
| Health check works, but joining fails | Use the lobby name and Drive / Navigate on the start screen, not direct LAN. Both players need the updated game. |
| Room not found | Both players must use the same service URL. Check the copied code. A restart or departed driver invalidates the room. |
| Both seats are taken | Use Back / leave online room in the old navigator; otherwise its seat remains reserved for two minutes after a drop. |
| Navigator lost connection | Leave the running game open for automatic retry. For an expired room or a restarted game, join your saved lobby again. |
| Root Render URL shows JSON | Correct: the relay is a backend, not the browser game. |
| No lobby-name field | Update the project/build to the revision containing the relay client and restart the game. |

## Browser play is a separate next step

This deployment works with desktop Godot clients. It does not export or host the game as a webpage, and it does not produce clickable browser-game invite links.

A browser release would add a Godot Web export on a static host, use this same WSS relay, and test browser rendering, performance, input, and audio. In particular, the generated engine audio needs Godot's Stream playback mode on web; the default web Sample mode does not support procedural audio. Start with a single-threaded export and test it before enabling threads and the corresponding cross-origin isolation headers. [Godot web export documentation](https://docs.godotengine.org/en/stable/tutorials/export/exporting_for_web.html)

The original broader plan is in [docs/ONLINE_PLAN.md](docs/ONLINE_PLAN.md). The deployable files added for this step are:

- `render.yaml`: one Render Node web service.
- `server/`: relay, pinned dependency lockfile, protocol checks, and tests.
- `scripts/relay_client.gd`: outbound WebSocket connection and room messages.
- `scripts/wire_protocol.gd`: explicit JSON conversion for Godot transforms and road points.
- `scripts/session.gd`: shared interpolation for direct LAN and relayed internet connections.
