# Deploy Blind Driver on Render

This guide gets **two people on different internet connections playing the desktop game together**. Render runs a small relay; each player runs the Godot game on their own computer.

The relay, Render configuration, and the game's **Play online…** menu are implemented. They have been tested locally with two separate Godot processes going through the relay. **A public Render service has not been created or tested yet.** The remaining account-specific steps are below.

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

There are two different networking modes:

| Mode | Buttons | Address | Intended use |
| --- | --- | --- | --- |
| Direct local connection | Host driver / Join navigator | `127.0.0.1` or a local network IP | Same computer or same network |
| Online room | Play online… → Create room / Join room | Your Render service URL | Different computers, including different networks |

`127.0.0.1` always means **the computer you are using**. Giving that address to a friend does not connect them to your computer. For internet play, both of you use the Render URL and the same room code.

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

Replace `YOUR-SERVICE` with the actual service name:

```text
https://YOUR-SERVICE.onrender.com/healthz
```

Open that address in your browser. A ready relay returns:

```json
{"ok":true,"protocol":1}
```

Or check from Terminal:

```sh
curl --fail https://YOUR-SERVICE.onrender.com/healthz
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

### Driver

1. Choose **Play online…** from the game's main menu.
2. Paste the Render service URL into **Relay address**, for example:
   `https://YOUR-SERVICE.onrender.com`
3. Click **Create room / I am driving**.
4. Wait for the **Room code** field to fill with an 18-character code.
5. Click **Copy** and share the code with your navigator, along with the Render URL.
6. Keep the game open. The driving view opens automatically when the navigator joins.

### Navigator

1. Open the same game version and choose **Play online…**.
2. Enter the **same Render URL** in Relay address.
3. Paste the driver's code into **Room code**.
4. Click **Join room / I am navigating**.
5. The navigator's view opens automatically. Press **M** to unfold the map and talk the driver through the route.

The game remembers the relay address on each computer. It converts an HTTPS address to `wss://YOUR-SERVICE.onrender.com/ws` automatically. You can also enter that complete WSS address yourself. Public Render connections use **WSS**, which is encrypted WebSocket traffic; ordinary `ws://` is for local testing. [Render WebSocket connection guidance](https://render.com/docs/websocket)

Only two seats are available per room. Each new driver can create a different room on the same service. The room code grants access to the navigator's seat, so share it with the intended player.

Use a voice call or talk in person; voice chat is not built into the game.

## 7. Do a first internet playtest

Use two computers, ideally on different networks, and check:

- The navigator sees the car move when the driver accelerates and steers.
- The navigator receives newly generated roads after taking either fork.
- Pressing **R** on the driver moves both views to the recovered car.
- Headlights remain in sync.
- Closing the navigator applies the driver's brakes and shows a disconnect message. The navigator can rejoin using the same code while the driver stays connected.
- Closing the driver ends the room. Start a new room to play again.

The driver's physics stays local and responsive. The navigator sees an interpolated view with network delay; testing from separate networks is still necessary to judge how well spoken directions work.

## Updates, restarts, and costs

Auto-deploy is initially off so every code push does not interrupt an active drive. To deploy a backend change:

1. Run the checks below.
2. Commit and push the change to the linked branch.
3. In the Render service, choose **Manual Deploy → Deploy latest commit**.
4. Wait for Live, check `/healthz`, and create a new room.

Keep this service at **one instance**. Rooms live in that process's memory. Multiple instances would need shared room coordination, because two clients can otherwise reach different instances. A restart or deployment ends active rooms; there is no persistent session recovery. Render can also replace instances during platform maintenance. [Render WebSocket lifecycle and scaling behavior](https://render.com/docs/websocket)

The supplied Blueprint requests a Free instance. Review Render's current plan, included bandwidth, and account spending settings before changing it. Relayed game traffic counts toward outbound bandwidth. A free-tier service is suitable for an initial experiment, not a guarantee of uninterrupted availability. [Render pricing](https://render.com/pricing), [free limits](https://render.com/docs/free)

There are no accounts, saved games, automatic host migration, or public room listings. Empty rooms expire after 30 minutes. The relay checks payload sizes, state shapes, sending roles, message rates, and total capacity, and uses heartbeats to clean up dead connections. These are prototype safeguards, not a complete production abuse-prevention system.

## Local development and verification

To run the same relay on your own computer:

```sh
cd server
npm ci
npm start
```

It normally listens at `http://localhost:10000`; the game accepts `http://127.0.0.1:10000` or `ws://127.0.0.1:10000/ws`. Open two game instances and use **Play online…** to create and join a room. Stop the relay with Ctrl+C.

From the repository root:

```sh
# Relay behavior: rooms, roles, invalid messages, capacity, and disconnects.
npm --prefix server test

# Existing driving and direct-LAN tests.
python3 tests/run_checks.py

# Also launch the Node relay and two Godot processes through a real room.
python3 tests/run_checks.py --relay
```

If Godot isn't found automatically, set `GODOT` to its executable path. The integration checks bind only to localhost and clean up their test processes. The relay checks require `npm ci` in `server` first. Node 24 is the deployment target; the scripts also work with the existing local Node 20 installation.

The relay test does not verify Render's public TLS endpoint. That is covered by the health check and two-computer playtest after deployment.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Render cannot find `package.json` | Root Directory must be `server`, or deploy the supplied Blueprint. |
| Render says no open port | Start command is `npm start`; don't override `HOST` to localhost. Inspect service logs. |
| `/healthz` is loading or unavailable | Give a free instance time to wake; inspect the latest deploy and runtime logs if it stays unavailable. |
| Game immediately disconnects from the public relay | Use the public HTTPS or WSS URL, not HTTP/WS. Don't append `:10000` or `:18765`. |
| Health check works, but joining fails | Use **Play online…**, not the direct-LAN Join navigator button. Both players need the updated game. |
| Room not found | Both players must use the same service URL. Check the copied code. A restart or departed driver invalidates the room. |
| Both seats are taken | Close the old navigator and wait briefly for disconnect detection, or create a new room. |
| Navigator lost connection | Reopen Play online… and join the existing code if the driver is still connected. Otherwise create a new room. |
| Root Render URL shows JSON | Correct: the relay is a backend, not the browser game. |
| No Play online… button | Update the project/build to the revision containing the relay client and restart the game. |

## Browser play is a separate next step

This deployment works with desktop Godot clients. It does not export or host the game as a webpage, and it does not produce clickable browser-game invite links.

A browser release would add a Godot Web export on a static host, use this same WSS relay, and test browser rendering, performance, input, and audio. In particular, the generated engine audio needs Godot's Stream playback mode on web; the default web Sample mode does not support procedural audio. Start with a single-threaded export and test it before enabling threads and the corresponding cross-origin isolation headers. [Godot web export documentation](https://docs.godotengine.org/en/stable/tutorials/export/exporting_for_web.html)

The original broader plan is in [docs/ONLINE_PLAN.md](docs/ONLINE_PLAN.md). The deployable files added for this step are:

- `render.yaml`: one Render Node web service.
- `server/`: relay, pinned dependency lockfile, protocol checks, and tests.
- `scripts/relay_client.gd`: outbound WebSocket connection and room messages.
- `scripts/wire_protocol.gd`: explicit JSON conversion for Godot transforms and road points.
- `scripts/session.gd`: shared interpolation for direct LAN and relayed internet connections.
