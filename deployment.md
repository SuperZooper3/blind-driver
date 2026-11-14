# Blind Driver — deployment and developer guide

For the game pitch, screenshots, and ways to play, see [README.md](README.md).
This guide collects hosting, controls, gameplay details, development, verification,
and [public-release security notes](#public-release-security-review).

- [Local quick start](#local-quick-start)
- [Render frontend](#add-the-playable-frontend-in-the-render-dashboard) and [relay](#3-create-the-render-service)
- [Browser builds](#browser-frontend)
- [AI navigator](#single-player-ai-navigator) and [two-agent harness](docs/AI_HARNESS.md)
- [Controls](#controls), [car damage](#car-damage), and [development](#development-reference)
- [Release security review](#public-release-security-review)

## Hosting overview

Render hosts two services: **blind-driver-frontend** is the playable webpage,
and **blind-driver-relay** connects the two players. The game runs inside each
player's browser (or in the desktop game). Both can be hosted on Render; a
Railway account is not required. The optional Railway setup is in
[docs/RAILWAY.md](docs/RAILWAY.md).

The existing relay is **https://blind-driver-relay.onrender.com**, now the game's default address. Browser hosts override it with `BLIND_DRIVER_RELAY_URL`; desktop development also supports the saved connection preference. Transport controls are hidden in the player menus.

## Add the playable frontend in the Render dashboard

Choose **New + → Web Service**. This implementation uses Render's **Docker**
runtime: the Dockerfile exports Godot and starts the small Node server that
serves the game and its deployment configuration. **Do not choose Static Site**
for this implementation. You do not need to install Docker or Godot locally.

1. On the source screen, select **Git Provider** and connect the
   **SuperZooper3/blind-driver** repository. If it is missing, connect GitHub or
   grant the Render GitHub integration access to this repository.
2. Fill out the new-service form with these values:

   | Field | Value |
   | --- | --- |
   | Name | `blind-driver-frontend` |
   | Branch | `main` |
   | Region | Frankfurt, matching the existing relay |
   | Language | **Docker** |
   | Root Directory | **Leave blank** (repository root) |
   | Dockerfile Path | `./Dockerfile` |
   | Docker Build Context Directory, if shown | `.` |
   | Docker Command | Leave blank; use the Dockerfile's command |
   | Health Check Path (under Advanced) | `/healthz` |

   There is no publish-directory value or custom build/start command to enter
   for this Docker service. Free can be used for an initial test; it has cold
   starts and the [normal Render free-service limits](https://render.com/docs/free).
3. Add these **Environment Variables**:

   | Key | Value |
   | --- | --- |
   | `PORT` | `10000` |
   | `BLIND_DRIVER_RELAY_URL` | `https://blind-driver-relay.onrender.com` |

   If your relay has a different domain, use its actual public HTTPS URL.
   Browser clients cannot use Render's internal service hostname.
4. Click **Deploy Web Service** (or **Create Web Service**, depending on the
   form). The first build downloads the Godot toolchain and can take several
   minutes. Render supplies the frontend's public `https://…onrender.com` URL
   after deployment; use the actual URL displayed on the service page.
5. Open the frontend URL. Players click **Get in the car**; one creates a room
   and shares its code or invite link (`…/?room=K7Q4MZ`), the other joins with
   it. Its `/healthz` verifies the exported files; the relay's `/healthz`
   must separately report **protocol 12** for online play.

Before online play, upgrade the existing relay using the next section. If you
already created a Static Site, create the Web Service above as a separate
service; these Docker settings do not belong in a static-site build form.

The checked-in [`render.yaml`](render.yaml) now declares **both services** with
these settings. If your relay is already managed by that Blueprint, sync the
existing Blueprint to add the frontend. For a fresh setup, **New + → Blueprint**
can create both services. If your relay was created manually, the frontend-only
steps above let you reuse it. If Render assigns a different relay domain, update
the frontend's `BLIND_DRIVER_RELAY_URL` accordingly.

References: [Render Web Services](https://render.com/docs/web-services),
[Docker on Render](https://render.com/docs/docker), and
[Blueprint fields](https://render.com/docs/blueprint-spec).

## Upgrade the existing service first

This revision uses **protocol 12**: spike strips with warning signs, WebRTC peer-to-peer negotiation between browsers, short room codes, seat choice when creating a room, and seat assignment on join, on top of route choices, cul-de-sacs, rejoining connections, and heat levels, including ramp gaps, timed bridges, and the shared crossing clock, alongside police pursuit, punctured tires, ravines, named lobbies, navigator-first joining, and resumable seats. Both clients and the relay must be updated together. The backend is verified locally; this change does not deploy Render.

1. Push these commits to the branch linked to your existing Render service (`git push origin main` if it uses main).
2. Open **blind-driver-relay** in Render, then **Manual Deploy → Deploy latest commit**. Auto-deploy is off in the supplied configuration.
3. Wait for Live. Open [health](https://blind-driver-relay.onrender.com/healthz) and confirm `"ok":true` and `"protocol":12`.
4. Update/restart **both games** from this same revision. Old clients and old servers cannot use the new protocol together.
5. One player presses **Create a room** and shares the 6-character code; the other types it and presses **Join**. The online server is already configured.

Upgrading the relay alone needs no new service, database, router settings, or environment variables. Deployment ends existing rooms, so do it between rides. The initial-service instructions below are retained for setting up another relay.

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
| Direct local connection | Developer launch: `--host` / `--join=IP` | `127.0.0.1` or a local network IP | Same computer or same network |
| Online room | Create a room → share code → Join | Your Render service URL | Different computers, including different networks |

`127.0.0.1` always means **the computer you are using**. The automatic local pair uses the same networking path as the LAN mode, but traffic stays inside your computer instead of passing through the router. Giving that address to a friend does not connect them to your computer. For internet play, both of you use the configured online server and the same room code.

## 2. Get the code onto GitHub

The configured repository is [SuperZooper3/blind-driver](https://github.com/SuperZooper3/blind-driver). Render must have access to the branch containing the new files.

From this project folder, after reviewing your local changes:

```sh
git status
git push origin main
```

The implementation commits contain the deployment files. Check that `render.yaml` and `server/package-lock.json` are visible on GitHub before continuing. If your repository is private, authorize Render to access this repository when connecting GitHub.

## 3. Create the Render service

For a fresh frontend-and-relay setup, use a **Blueprint**: Render reads the included [`render.yaml`](render.yaml) and fills in both services' settings. This is Render's supported configuration-file workflow. [Render Blueprint reference](https://render.com/docs/blueprint-spec)

1. Open the [Render dashboard](https://dashboard.render.com/) and sign in or create your account.
2. Choose **New → Blueprint**.
3. Connect the `SuperZooper3/blind-driver` repository and select the branch containing these commits, normally `main`.
4. Use the repository-root `render.yaml` file.
5. Review the proposed **blind-driver-relay** and **blind-driver-frontend** services. Both use the supplied **Free** plan and **Frankfurt** region. Change the region before creating them if another region is closer to both players.
6. Create/deploy the Blueprint and wait for the service to become **Live**.
7. Copy the actual `https://…onrender.com` address from its dashboard. Render may add a suffix to the service name; use the address Render displays.

No database, persistent disk, or API key is required. Render builds the frontend's Docker image from the repository; you do not need to build or upload it yourself.

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
{"ok":true,"protocol":12,"instance":"example-instance","uptime_seconds":123}
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

1. One player chooses **Drive** or **Navigate**, then presses **Create a room**.
2. A 6-character code appears, such as `K7Q4MZ`. Read it out, or press **Copy code**. In the browser, **Copy invite link** gives a link that joins directly.
3. The friend types the code into **Room code** and presses **Join** (case, spaces and dashes don't matter). They get whichever seat is left, and the ride opens automatically.
4. The preferred seat and server address are remembered locally. Each ride uses a fresh room and code.

Connection transport controls are hidden in the player menus. Configure another relay on the host or through the desktop development configuration. Both computers must use the same server. The game accepts HTTPS/WSS URLs for public play and HTTP/WS for localhost, adding `/ws` automatically.

The code identifies a meeting place, not a saved world or permanent account. Leaving as the driver closes the room and its code. A relay restart also ends the run; create a new room. A crashed client’s seat stays reserved during the existing two-minute recovery window. Anyone who has the code can take a vacant seat, so share it only with your co-player.

Preferences are stored in Godot’s `user://network.cfg` on each computer. Resume credentials remain in memory and are not written there.

Use a voice call or talk in person; voice chat is not built into the game.

## 7. Do a first internet playtest

Use two computers, ideally on different networks, and check:

- The navigator sees the car move when the driver accelerates and steers.
- The navigator receives newly generated roads on the safe branch, and sees the same rocks, trees, ramps, bumps, construction, cliffs, and lakes.
- There is no R/gamepad recovery shortcut. **Start a new ride** in the driver’s pause menu resets both views and the trip odometer.
- Headlights, suspension, impacts, and car rotation remain in sync.
- Drive deep into the thorn forest: both players see punctured tires and the same failure reason. Roll onto the roof: the cabin stays above the ground and the failure screen appears after landing.
- Hold B / RB on the navigator: the full rear view reveals the patrol and its gap/closing estimate. The driver’s forward view stays unchanged.
- Both players should see the same patrol position and flashing lights, hear a louder siren as it approaches, and see the same police-capture Game Over. Pause on the driver or disconnect temporarily: pursuit must freeze instead of catching you during recovery.
- Each computer saves its own PB from the shared run distance. Restart and relaunch to check that the best remains while the trip resets.
- Drive over a marked cliff: both players see the fall, Game Over, and the same distance. Reconnect a navigator during Game Over and check that the result remains. Choose Drive again on the driver and confirm both return to the start in the same room.
- Temporarily interrupt either computer's network. The driver brakes once the outage is detected; the navigator holds the last received view. The same running games reconnect automatically and resync the road/car state.
- A silent connection is detected after 15 seconds without application heartbeat replies. A clean socket failure is detected sooner. Let the connection return within the two-minute recovery window.
- **Cancel / leave room** is intentional: the driver ends the room; the navigator releases their seat. Closing/crashing the game loses its in-memory resume credential. A reserved navigator seat expires after two minutes; a closed driver cannot recover the ride after restarting the application.

The driver's physics stays local and responsive. The navigator sees an interpolated view with network delay; testing from separate networks is still necessary to judge how well spoken directions work.

## Updates, restarts, and costs

Auto-deploy is initially off so every code push does not interrupt an active drive. To deploy a backend change:

1. Run the checks below.
2. Commit and push the change to the linked branch.
3. In the Render service, choose **Manual Deploy → Deploy latest commit**.
4. Wait for Live, check `/healthz`, and create a new room.

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

It normally listens at `http://localhost:10000`; the game accepts `http://127.0.0.1:10000` or `ws://127.0.0.1:10000/ws`. For browser development, set the frontend’s `BLIND_DRIVER_RELAY_URL=http://127.0.0.1:10000`, then create a room and join it from a second browser tab. For desktop integration, use the automated relay checks below. Stop the relay with Ctrl+C.

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
| `shutdown`, changed instance ID, or `resume_expired` | Deployment, process restart, expired reservation, or invalid resume credential. A restarted server has lost its rooms; create a new room. |

For another unexplained drop, retain **both clients' logs** plus the Render logs from the same UTC minute. Note who was driving and whether either window froze. This distinguishes transport failures from a server rejection or a stalled game. The initial 75-second idle check against the public protocol-1 service survived; the reported active-driving drop was not conclusively reproduced, so these events are designed to capture its actual cause.

Recovery uses application heartbeats every two seconds, a 15-second client reply timeout, retry delays growing from roughly 1 to 8 seconds with jitter, and a two-minute retry budget after loss detection. The relay also sends control pings every 10 seconds and counts valid game traffic as liveness. Rate limits tolerate bounded delivery bursts after network jitter. Both seats use private in-memory resume credentials. Road state is resent after either seat returns; the navigator clears its old interpolation buffer. Direct-LAN navigators also retry their existing host for up to two minutes; restarting a LAN host creates a new world.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Render cannot find `package.json` | Root Directory must be `server`, or deploy the supplied Blueprint. |
| Render says no open port | Start command is `npm start`; don't override `HOST` to localhost. Inspect service logs. |
| `/healthz` is loading or unavailable | Give a free instance time to wake; inspect the latest deploy and runtime logs if it stays unavailable. |
| Game immediately disconnects from the public relay | Use the public HTTPS or WSS URL, not HTTP/WS. Don't append `:10000` or `:18765`. |
| Health check works, but joining fails | Use **Create a room** and **Room code / Join** on the start screen, not direct LAN. Check the code with your friend. Both players need the updated game. |
| Room not found | Both players must use the same service URL. Check the copied code. A restart or departed driver invalidates the room. |
| Both seats are taken | Use Back / leave online room in the old navigator; otherwise its seat remains reserved for two minutes after a drop. |
| Navigator lost connection | Leave the running game open for automatic retry. For an expired room or a restarted game, create or join a fresh room. |
| Root Render URL shows JSON | Correct: the relay is a backend, not the browser game. |
| No lobby-name field | Update the project/build to the revision containing the relay client and restart the game. |

## Browser frontend

The Render Blueprint deploys the frontend and relay. For manual setup, follow
[Add the playable frontend](#add-the-playable-frontend-in-the-render-dashboard)
above. The frontend's Dockerfile exports
the game with Godot 4.7.2; players open its URL, create a room, and share a code or invite link.
The Web export uses a single thread and Stream playback for procedural audio.
Browser-specific mode controls and downloadable logs are included. Invite links
use `?room=CODE` and preserve the invitation through the landing-page launch.
The page uses the supplied screenshots in `frontend/media/`; CSS crops their
views without altering the source images. The trailer near the top uses YouTube's
privacy-enhanced player (`youtube-nocookie.com`), loads lazily, and does not autoplay.
The README links its trailer thumbnail to the same video because GitHub does not
render embedded players.

The yellow-car logo lives in `frontend/favicon.svg`, with ICO and Apple touch icon
fallbacks. `frontend/media/social-preview.png` is the 1200 × 630 split-screen share
card. Open Graph and Twitter card metadata in `frontend/shell.html` use the public
frontend URL; update the canonical, `og:url`, and image URLs there if the domain
changes. Social services may cache an older preview until they fetch the page again.

```sh
GODOT=/path/to/godot bash tools/export_web.sh
HOST=127.0.0.1 node frontend/server.mjs
# Open http://127.0.0.1:8080
```

The export copies the launcher, CSS, favicon, and screenshot assets alongside
the engine. The Docker build includes `assets/` (the radio track is a required
resource). Serve only `build/web/`, never the repository root. Only the runtime
relay URL and protocol are exposed in `/config.js`.

The original broader plan is in [docs/ONLINE_PLAN.md](docs/ONLINE_PLAN.md). The deployable files added for this step are:

- `render.yaml`: the Node relay and Docker frontend as two Render web services.
- `server/`: relay, pinned dependency lockfile, protocol checks, and tests.
- `scripts/relay_client.gd`: outbound WebSocket connection and room messages.
- `scripts/wire_protocol.gd`: explicit JSON conversion for Godot transforms and road points.
- `scripts/session.gd`: shared interpolation for direct LAN and relayed internet connections.


## Single-player AI navigator

This developer prototype is hidden from the public launcher and game menus. A
human drives; Cohere Command A Vision sees the passenger view and map and returns
one instruction. It is separate from the [two-agent harness](docs/AI_HARNESS.md).

**The gateway is disabled by default, even if `COHERE_API_KEY` is set.** Enable it
only for local development with `BLIND_DRIVER_AI_ENABLED=1`. The command below
binds to loopback; the endpoint also rejects non-loopback clients, non-local Host
names, forwarded/proxied requests, and foreign browser origins. Do not publish
or reverse-proxy this endpoint. A public AI mode needs authenticated users,
per-user quotas, and an operator-controlled spending limit first. Origin checks
alone do not authenticate API callers.

```sh
# Terminal 1: keep this .env file ignored and on your own computer.
# Contents: COHERE_API_KEY=<your key>, with Command A Vision access.
HOST=127.0.0.1 BLIND_DRIVER_AI_ENABLED=1 node --env-file=.env frontend/server.mjs

# Terminal 2: no Web export needed for the desktop AI prototype.
godot --path . -- --ai
```

The default desktop endpoint is `http://127.0.0.1:8080/api/ai/navigate`. Node 24
is the deployment target; `--env-file` needs Node 20.6 or later. The public Docker
service should not set `BLIND_DRIVER_AI_ENABLED` or a model-provider key.

During AI play, the local gateway sends two JPEGs (clear passenger view and map),
speed, route card, previous instruction, and timing to Cohere. It uses the fixed
Command A Vision model and a 128-token output limit. Successful requests are
sequential per game, with at most four upstream requests in flight per server.
Provider quota errors apply a shared cooldown; requests time out after 60 seconds.
Screenshots and responses are not intentionally logged by the gateway; the provider
receives the submitted data. Pause, Game Over, and leaving AI mode stop requests.
Ordinary multiplayer and solo practice make no model-provider calls.

The UI shows request latency and source-image age separately. Missing credentials
or model access failures require a host configuration fix; pause/resume to retry.
The model may give late or incorrect directions. This is a game experiment, not
an autonomous-driving system.

## Local quick start

Install Godot **4.7.2**. Import `project.godot` and press F5, or run:

```sh
godot --path .
godot --path . -- --solo
godot --path . -- --split
godot --path . -- --local-coop
# In two terminals for direct LAN development:
godot --path . -- --host
godot --path . -- --join=127.0.0.1
```

Use the absolute path to your Godot executable if it is not on PATH. Local human
play needs no Node packages, API keys, or accounts. Keep direct LAN listeners on
trusted networks; do not forward port 18765 to the internet. Use the public relay
for internet rooms. Two windows and direct LAN are desktop-only.

## Controls

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
| R (hold) | Repair (navigator; the car must be under 15 km/h) |
| V | Mute/unmute driving audio, including the radio |
| F | Fullscreen/windowed |
| F8 | Connection check, live network metrics, and logs |
| Escape | Menu; driver applies brakes while the menu is open |

Gamepad: left stick steers, right trigger accelerates, left trigger brakes/reverses, A applies the handbrake, Y toggles the map, holding the right shoulder button (RB) looks behind, and Start opens the menu. Keyboard and gamepad can be used together. **Settings** has the driver-blur slider. There is no recovery shortcut. Use **Start a new ride** in the pause menu, or **Drive again** after Game Over; both reset the run and trip odometer while keeping your personal best. Landing on the roof/side ends the run automatically. A badly damaged car keeps driving, slowly, until the police catch it. In the thorn forest, where the police never follow, three broken tires (or the engine and two tires) end the run.

Talk to each other in person or over your preferred voice call. The navigator sees only the top edge of a folded map at the bottom of their view. **M / Tab** slides it up to cover their entire screen (their half in shared-screen mode), so checking the map means looking away from the road. Red **X / CLIFF** marks a fatal dead end. A circular **DEAD END / TURN AROUND** marks a solid cul-de-sac. Green **LONG / QUIETER** and amber **SHORT / HEAVY HAZARDS** routes rejoin; check the map to choose between extra distance and more dodging. Jump gaps, timed bridges, lakes, and construction zones are mapped; small obstacles are not. The navigator must also watch the clear road view and call out rocks, trees, ramps, bumps, cones, and spike strips.

Hold **B / RB** or the on-screen **Hold to look back** button for the full passenger rear view. This folds the map and shows the patrol’s distance along the route, whether it is closing, and an approximate catch time at the current pace. Release to face forward again. The driver keeps their forward view in shared-screen play.

Steering needs rolling wheels: from rest, combine **W+A** or **W+D** and release
the handbrake. While coasting, A/D can steer without more gas. Reverse steering
swings the nose the opposite way. **B** looks behind; **C** switches seat/chase view.
A large **WRONG WAY** banner appears in both seat views and on the unfolded map
when travel (or heading at rest) opposes the local road. Slow down and turn around
where clear. Short heading changes are filtered; returning from marked dead ends
is allowed.

### Car damage

The car radio starts when you first move after the opening, playing the supplied **Chip Chase**
music from the beginning. Its last half second before **2:04** crossfades into
**0:13–0:13.5**, then continues from **0:13.5**, looping indefinitely. Brief
stops keep the music going. Crashes instantly cut it with electrical static and
a tuning squeal; after a short retune it resumes when you move again. Falling
or Game Over silences it until a new ride. Damage adds progressively stronger
bitcrushing, muffling, static, pitch wobble and dropouts; repairs clean it up.
Menus and connection recovery pause the radio. Both seats hear their own radio
react to shared damage, and **V** mutes it along with the other sounds.

The prepared track is `assets/audio/driving_music.ogg`. To rebuild it from the
original supplied `music.mp3`, use `python3 tools/prepare_driving_music.py /path/to/music.mp3`
with FFmpeg on PATH. The crossfade is baked into the audio and the player loops
on the audio thread, so the transition does not depend on rendered frames.

Crashes and thorns break the car. A damaged car limps on, slower and slower, but the police never follow you into the forest, so the car **breaks down and the run ends** once three tires are broken, or the engine is blown and two tires are broken.

Hits under about 13 km/h are harmless. Harder hits on rocks, trees, barriers and walls dent parts and play a crash sound on both seats. Damage grows faster than speed (like crash energy), and the bumpers soak up most of a hit while they last. The car is fragile: a 30 km/h hit dents the bumper, a 50 km/h hit tears it off, an 80 km/h corner hit knocks that wheel off, and one head-on hit at top speed wrecks the engine. A damaged part only looks and sounds worse. It costs nothing until it **breaks**:

| Part | When it breaks | Top speed afterwards (healthy: ~106 km/h) |
| --- | --- | --- |
| Tires (4) | **Thorns** tear any tire touching them; a tire pops flat (with a bang) after about 1 s in the brambles. A flat stays on the car but slides and pulls toward its side. A hard crash can knock a wheel right off instead, leaving the hub dragging and halving steering for a front wheel. Each broken tire also costs 15% of power and 12% of top speed. | 1 flat ~82 km/h, 2 flats ~62, 1 wheel lost ~64 |
| Engine (under the hood) | The hood flies off, the engine smokes and knocks, and power drops to 45%. | ~56 km/h; with 2 flats ~32; everything broken ~18 |
| Front bumper | Falls off. Front hits reach the engine, windshield and front wheels at full strength, and the headlights break. | |
| Rear bumper | Falls off. Rear hits reach the rear wheels at full strength. | |
| Windshield | Cracks spread across the glass itself, so each seat sees them in perspective (blurred for the driver, like the road) and third person sees them from outside; they then shatter into a hazy web. | |

**Opening scene.** Every new ride, including restarts, opens outside the bank the pair just robbed: the alarm bell rings, a red light flashes, and the driver's glasses fly off and break on the road. Both players see the bank, then the broken glasses, before the camera flies into their own seat and the ride begins (about 8.5 seconds; the car and the police wait until it ends). Both opening views stay sharp; the driver becomes blurry only after entering their head. The bank's clearing stays free of trees, rocks and thorns. Pausing freezes the opening; resuming continues it.

The engine sounds only while actively accelerating or reversing. Coasting and idling have no engine sound or rolling hiss. The music, crash effects and damage-based radio interference remain separate.

**Spike strips** appear from heat 4. An oversized yellow sign with a black spike pictogram and **100 m** distance plate stands at the start of the road, and the strip is always at least 100 m past it. It lies across one half of the road, striped yellow and black with red spikes, and pops every tire that rolls over it; steer into the clear half.

The **navigator holds R** to repair while the car is under 15 km/h (on one computer, either player can press it). The car stays parked while you hold it; let go to drive on with whatever has been fixed so far. Repairs fix one part at a time, most crucial first: the engine, then the tires (worst first), the windshield, the front bumper and the rear bumper, at 5 seconds for a fully broken part. Lost wheels and bumpers go back on, and flats are reinflated.

Both seats show **REPAIRING... / You can't drive** over a translucent view of the
road. Eight progress bars show every part's repair percentage, highlight the part
being worked on, and keep completed parts visible. Looking back still works while
repairing; the navigator's map opens above the repair display. Releasing R or
finishing all repairs removes the overlay.

Police beacons grow brighter and their red/blue glow grows larger as the patrol
gets farther away, so distant flashes remain conspicuous in both camera views.
The glow still sits in the world: hills and solid obstacles can hide it.

Damage lasts until you repair it or start over. **Start a new ride** or **Drive again** gives you a fresh car. The driver's game decides the damage and sends it to the navigator in each snapshot. Tuning lives at the top of `scripts/car_damage.gd` (`SAFE_SPEED`, `CURVE`, `RATE`, breakdown penalties) and `scripts/car.gd` (`THORN_WEAR`, `FLAT_TIRE_DRAG`, `HUB_SCRAPE`).


## Gameplay implementation details


- A physical 1,050 kg car with four raycast suspension springs, tire grip, rear-wheel handbrake slip, braking, reverse, aerodynamic drag, and a low center of mass. It can bounce, slide, collide, and overturn. Starting a new ride resets the car and score.
- Gravel and off-road grip/rolling resistance, physical road surfaces, gentle hills, collidable trunks and rocks, working steering/wheel visuals, two simple occupants (a head and a body each, plus the driver's two floating sphere hands on the steering wheel), each seat camera hiding only its own occupant so the other shows in your peripheral view, headlights, and synthesized engine/tire sound.
- Breakable wheels, hood, bumpers and windshield. Each one has health, its own handling penalty, and debris when it breaks.
- Two independent seat cameras sharing one simulation, a low-resolution blurred driver render, a clear navigator render, a heading-relative map, and a solo chase view.
- A survival run: wrong forks end in broad, 36 m deep ravines (up to 160 × 112 m), with broken rims, layered rock walls around the whole drop, and rubble below, roadside lakes are fatal, and Game Over reports the distance driven. The driver can restart with **Drive again** without leaving the room. There is no recovery key or gamepad binding.
- Faster acceleration and a 158 km/h engine cutoff (about 111 km/h sustained on a flat test road), physical boulders, tree chicanes, half-width ramps that can overturn the car, speed bumps, and construction cones/barriers. Roadside clutter is static and collides; it is not independently simulated debris. Each road's obstacles are seeded but random: their kinds, spacing and shoulder side change from road to road. Roads are one continuous surface through bends, with a round pad where branches meet.
- Two arcade crossing challenges alternate on clear, straight connector roads. A full-width ramp launches you over a 16 m gap: line up and approach at **65+ km/h** for a forgiving takeoff assist, then land using the normal car physics. A sliding bridge initially opens for six seconds in a twelve-second cycle, warns for the last two seconds, and retracts sideways to expose a real pit. Roadside signals, the navigator’s route card, and live map markers show when to go. Miss either crossing and you fall, crash, and receive Game Over. The patrol jumps the ramp and waits for the bridge too.
- Bridge motion, lights, map countdowns, and failure states follow the driver’s run clock, interpolated with the car on the navigator. Driver menus, connection recovery, and Game Over pause the clock; starting a new ride resets it. These challenges replace ordinary clutter on their road, leaving room to line up or wait.
- Dense thorn bushes start roughly 18 m from the road center, leaving room to dodge obstacles on the shoulder. Deep-forest brambles wear down any tire touching them until it pops flat, slowing the car (see Car damage). Flat tires, part damage and the failure reason synchronize to the navigator.
- Roof and cabin collision protect the seats when the car flips. A car resting on its roof or side for 0.65 seconds ends the run; an airborne flip can still land safely.
- A seeded road graph with one growth frontier. After the introductory cliff fork, three-way junctions offer a longer, quieter road, a shorter road with more hazards, and a cul-de-sac or cliff. Half of three-way junctions put the dead end (pit or cul-de-sac) straight ahead in the middle, with both through routes swinging around it; the rest put it on the left or right (25% each). Both through routes rejoin the same continuation. Cul-de-sacs have a broad, solid turning circle and a no-through-road sign. Other forks offer one continuing road and a cul-de-sac. Dead ends and the forest cannot spawn extra routes. Distant sections are removed and forest tiles load incrementally. Trees use MultiMesh rendering; nearby-road queries use a spatial index.
- Five heat levels, shown on the dashboard, increase every **750 m** of trip distance, reaching level five at 3 km. New rough shortcuts grow from three to six obstacles while quieter alternatives grow from one to three. Future bridge windows shorten by half a second per level, down to four seconds. Existing road layouts and bridge timing stay fixed; restarting resets heat. The patrol also increases its normal cruising speed with distance.
- The five heat levels also change the scenery: **spring** (0–749 m) is light green, **summer** (750–1499 m) uses the original deep greens, **fall** (1500–2249 m) mixes orange/red foliage with bare trees, **winter** (2250–2999 m) has bare trees and snow, and **hell** (3000 m onward) has red earth, dead trees, and small flickering fires. Snow and fire are cosmetic: grip, collisions, thorns, and hazards keep their usual behavior. Both seats derive the season from the shared trip distance; a new ride restores spring.
- A police pursuit with an 85 m initial gap and a six-second head start. The patrol navigates the connected road network, takes rejoining routes, turns back through junctions if you change branches, steers around obstacles, and slows for bumps and bends. Its cruising speed starts at 50 km/h and rises steadily through the chase (about 1 km/h every 7 s) to a cap of 111 km/h, a healthy car's sustained top speed, so driving perfectly is never overtaken while damaged cars are eventually reeled in. A rubber band stops the lead growing: from about 150 m behind it starts matching your pace, and by 240 m it is fully leashed (briefly up to 126 km/h to make up corners), so it stays at the back instead of being lost. It brakes earlier for obstacles and junctions at catch-up speed and does not teleport forward.
- Sirens grow louder with physical proximity and switch to a faster wail nearby. Police can catch you on the shoulder: capture reaches 24 m across the ground when they are within 14 m along your route and 4 m in height. Staying in that range for 2 seconds ends the run with **The police caught you**. Route and height checks prevent captures across separate branches or into a pit. Driver menus and connection recovery freeze pursuit. A new ride resets it. The patrol uses route steering and proximity capture.
- A streamlined lobby/start menu, analog 0–160 km/h speedometer, mechanical-style trip odometer, route prompts, fullscreen, gamepad support, and local networking. The trip counter shows kilometers driven in this run; it resets for a new ride. Your personal best stays visible on the start screen, dashboard, and failure screen, with a new-record callout. It is saved locally in `user://records.cfg` during the ride, on failure, on restart, and on a normal exit. Both players record the shared distance on their own computer; this is not a saved world or an online leaderboard.


## Development reference

Read [AGENTS.md](AGENTS.md) before changes. Work on a dedicated branch/worktree,
verify the combined revision before merging, and bump the release and internal
build ID. [NEXT_STEPS.md](docs/NEXT_STEPS.md) contains ideas, not implemented features.

The project intentionally builds almost everything in code. The editor's main scene is a small entry point, so an empty-looking 3D editor is expected: **run the project to see the world**.

| File | Responsibility / useful tuning |
| --- | --- |
| `scenes/main.tscn` | Entry scene |
| `scripts/main.gd` | Lighting, cameras, inputs, modes, route instructions |
| `scripts/car.gd` | Car geometry and physical controller; spring, damping, grip, engine and steering tuning |
| `scripts/procedural_world.gd` | Road graph, terrain, forest streaming, collision, world seed |
| `scripts/season_style.gd` | Heat-based seasonal palettes, bare trees, and cosmetic tree fires |
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
| `scripts/engine_audio.gd`, `scripts/police_siren.gd` | Throttle-driven engine revs and distance-based stereo siren |
| `scripts/police_pursuit.gd` | Driver-owned patrol navigation, obstacle avoidance, gap estimates, and capture |
| `scripts/impact_audio.gd` | Synthesized crash and tire-pop sounds |
| `scripts/driving_radio.gd` | Looping driving music, crash retuning, and damage-based radio distortion |
| `scripts/car_damage.gd` | Part health, impact zones, dents, breakdown penalties, debris; `SAFE_SPEED` and `RATE` tune how fragile the car is |
| `scripts/windshield_cracks.gd` | Procedural crack pattern, painted onto the 3D windshield glass |
| `shaders/driver_blur.gdshader` | Driver's vision |

Edit a script, save, stop the running game, and press F5 again. Start with Solo practice to tune the handling, then test the same change with two people in local co-op. Use the Debugger and Output panels for errors. Godot's generated `.godot/` cache stays out of Git; script `.uid` files belong in Git.

### Verification

```sh
# Game physics, controls, world streaming, and direct LAN:
python3 tests/run_checks.py
# Relay validation plus real client/server integration:
npm --prefix server ci
npm --prefix server test
python3 tests/run_checks.py --relay
# Recovery after deliberate disconnects and stalled traffic:
python3 tests/run_checks.py --resilience
# Frontend, AI gateway boundaries, and static serving:
node --test frontend/*.test.mjs
# Harness unit tests (Pillow required; no paid model calls):
python3 -m unittest discover -s tests -p 'test_*.py'
# Dependency advisories:
npm --prefix server audit --omit=dev
```

Set `GODOT=/path/to/godot` when needed. Integration checks use localhost, temporary
ports/records, and their own game processes. They do not replace a two-computer
internet playtest after deployment. Human testing is still needed for handling,
camera comfort, and spoken coordination. A frontend change should also be checked
at desktop and narrow widths, with keyboard navigation, an invite link, the load
button, and a real Web export.

### Scope and limits

The world is an endless survival run, not a persistent saved world. Roads behind
the players are eventually discarded. There is no finish line, traffic system,
account system, public matchmaking, or host migration. Repair mechanics are
implemented. Best distance is saved locally; it is not a secure online leaderboard.
Keep browser game tabs visible: background throttling can stall the driver's
simulation. The screenshots in the README show prototype 30; the current release
comes from `scripts/version.gd`.

## Public-release security review

This is a targeted source/configuration review, not a penetration-test certification
or a guarantee against compromise. The public human-play path requires no API keys.
The review covers tracked source and reachable Git history, the HTTP frontend,
relay validation, local AI gateway/dashboard, and release packaging.

### Changes made for this release

- Disabled the billable AI gateway by default and restricted explicit opt-in to
  direct local development. A provider key alone no longer exposes an anonymous
  paid endpoint. Do not proxy the local gateway to the internet.
- Blocked dotfiles and symlink escapes from static serving, including compressed
  variants. The frontend serves only allowed file types under `build/web/`.
- Added anti-framing headers and disabled unused camera, microphone, and location
  permissions. The local research dashboard rejects foreign Host headers to
  prevent DNS rebinding from reading run data and control tokens.
- Expanded Git/Docker ignores for environment variants, private key files,
  provider folders, recordings, and virtual environments. These rules do not
  remove secrets that were already committed: inspect history before release.
- Included the required audio assets and landing-page media in browser packaging.
  Removed EXIF metadata from the supplied screenshots without changing their pixels.

### Checks and remaining boundaries

- A credential-pattern scan of 929 historical text blobs found no matches for
  common provider-token formats, private keys, or long assigned API secrets.
  Pattern scans can miss unusual credentials; this is not proof that every byte
  of history is non-sensitive. Recordings and ignored local files were not published.
- `npm audit --omit=dev` reported zero known vulnerabilities for the locked relay
  dependency on 14 November 2026. Re-run before future releases. The optional
  Python harness and Godot toolchain should also be kept current and checked
  against their advisories; this review is not a full supply-chain audit.
- The relay uses bounded JSON payloads, state/role validation, random room and
  resume tokens, rate/capacity limits, backpressure handling, and heartbeats.
  It forwards game state rather than executing player-supplied code. It remains
  an anonymous service: capacity limits mitigate abuse but do not prevent a
  determined denial of service. Use host-level traffic protection for a larger launch.
- Share room codes only with the intended co-player. A code lets someone take an
  empty seat; it is not a private account or an identity check. The driver owns
  physics, so a modified client can cheat. Do not use this for prizes or trusted scores.
- Direct/P2P modes can disclose network addresses to the other player and may
  open a desktop LAN listener. Keep those features on trusted networks/with trusted
  partners; public internet play should use the configured TLS relay. Hiding a
  transport toggle does not make the underlying feature an authentication boundary.
- Keep the research dashboard on `127.0.0.1`. Do not expose its port or upload
  run folders wholesale: recorded screenshots, dialogue, prompts, and manifests
  may contain private information or local paths. Review each artifact before sharing.
- Hosting access logs may record IP addresses and room invite URLs. Avoid public
  log dumps. Keep credentials in runtime secrets; never inject them into the
  launcher, Godot export, screenshot assets, or `/config.js`.

### Verification snapshot — release 1.0.1

On 14 November 2026: all 10 frontend tests, 23 relay tests, and 48 Python harness
unit tests passed. `tests/run_checks.py --relay` passed driving, LAN, relay,
role-swap, direct-link, hazard, and network-jitter checks. Godot emitted resource /
ObjectDB cleanup warnings when some test processes exited; the checks completed
successfully. The Godot Web export built and reached the game menu in a browser
without console errors. The landing page was checked at desktop and 390 px width,
including the room-invite CTA. Documentation links and screenshot pixel integrity
were checked. Production Docker hosting and a two-computer public internet session
still need validation after deployment.

### Release gates

The owner has chosen to keep the code **unlicensed** for now; this cleanup does
not add an open-source license. Redistribution rights and attribution requirements
for the supplied **“Chip Chase” radio track are unconfirmed**. The file remains in
the project, so the repository/build is not represented as fully cleared for public
reuse. Confirm those rights or replace/remove the track before redistribution.
The provided screenshots are project screenshots, not evidence of music rights.

Deploy the reviewed frontend, check its `/healthz`, and confirm relay protocol 12.
Then test a fresh room from two computers. Render auto-deploy is off in the checked-in
blueprint; a Git push alone does not deploy either service. Never force-push main
or rewrite history to conceal a secret: revoke it first and coordinate cleanup.
