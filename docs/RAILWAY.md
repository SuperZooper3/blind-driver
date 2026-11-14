# Play Blind Driver in a browser on Railway

**Using dashboard.render.com?** Follow [the Render frontend instructions](../deployment.md#add-the-playable-frontend-in-the-render-dashboard)
instead: choose **New + → Web Service**, then **Docker**. The steps below are
only for Railway.

The frontend builds Godot **4.7.2** into WebAssembly and serves a playable page.
Players open its HTTPS address, click **Get in the car**, enter the same lobby
name, and choose **Drive** or **Navigate**. Either seat can arrive first.
They do not install Godot. Solo practice, shared screen, maps, settings,
personal bests, and network diagnostics are available in the browser.

The frontend and relay are separate services. The relay pairs the players and
forwards state; the driver's browser still simulates the car and police.
Both services can live in the same Railway project. An existing Render relay
also works, provided its `/healthz` reports **protocol 8**.

## Add the frontend to your existing Railway project

1. Open your project in Railway, choose **New → GitHub Repo**, and select
   **SuperZooper3/blind-driver**, branch **main**. Name the new service
   **blind-driver-frontend**.
2. Keep **Root Directory** at the repository root (`/`), not `frontend` or
   `server`. Railway detects the root **Dockerfile**. Leave custom Build and
   Start commands empty: the Dockerfile exports the game and starts the server.
3. Add these service variables:

   | Variable | Value |
   | --- | --- |
   | `PORT` | `8080` |
   | `BLIND_DRIVER_RELAY_URL` | Your relay's public `https://…` address |

   For a Railway relay named `blind-driver-relay`, you can use
   `https://${{blind-driver-relay.RAILWAY_PUBLIC_DOMAIN}}` after generating its
   public domain. An actual copied public HTTPS URL works too. The existing
   Render relay is `https://blind-driver-relay.onrender.com`.

   Use the **public** address: players' browsers cannot reach
   `*.railway.internal`. Do not put credentials in this variable; it is public
   configuration delivered to every player. It can be changed with a redeploy
   without rebuilding the game files. Existing browser preferences never
   override this deployment setting.
4. Set **Healthcheck Path** to `/healthz`, with a 120-second timeout.
5. Deploy. The first build downloads the official Godot editor and template
   archive (about 1.2 GB) and takes several minutes. Subsequent builds can reuse
   the cached toolchain. The runtime image contains only Node and the exported
   game, not Godot or its templates.
6. Under **Settings → Networking → Public Networking**, choose **Generate
   Domain**, targeting port **8080**. Open that HTTPS address. This is the
   playable URL to share with friends.
7. Check `<frontend URL>/healthz` returns `"ok":true`, then check
   `<relay URL>/healthz` returns `"ok":true,"protocol":8` (additional fields
   are normal). Frontend health verifies the game files, not relay reachability.

No frontend database, persistent disk, API key, manual Godot export, or upload of
build files is needed. Exported binaries stay out of Git; Railway builds them
from the same source revision on each deployment.

## Put the relay on Railway too

If your relay already works, reuse it. To create another in this project:

1. Add another GitHub service from the same repository and branch. Name it
   **blind-driver-relay** and set its **Root Directory** to **`server`**.
2. The `server/Dockerfile` supplies the build and start commands. Add
   `PORT=10000`, `NODE_ENV=production`, `MAX_ROOMS=100`, and
   `MAX_CONNECTIONS=256`. Set `/healthz` as the health check.
3. Keep **one replica** and disable serverless sleeping for the relay. Rooms
   and two-minute reconnect reservations are held in that process's memory.
4. Generate its public domain, targeting port **10000**, and use that public
   HTTPS URL in the frontend's `BLIND_DRIVER_RELAY_URL`. Redeploy the frontend
   after changing the variable.

Use each service's public HTTPS domain without appending its internal port.
Godot converts HTTPS to WSS and adds `/ws` automatically. The relay already
supports browser WebSockets; there is no additional HTTP CORS configuration.
The relay root shows service JSON, while the **frontend** root shows the game.
Desktop clients can join browser players by using the same relay and lobby.

## Checked-in Railway blueprint

[`../.railway/railway.ts`](../.railway/railway.ts) declares both GitHub services,
their root directories, health checks, replica counts, ports, and the relay URL
reference. It uses Railway's current **Infrastructure as Code** API. Railway
calls this an IaC configuration; `render.yaml` is the separate Render Blueprint
for the frontend and backend.

For a new Railway project, with Node **22 or newer** and the current Railway CLI:

```sh
npm install -g @railway/cli
railway login
railway init
npm --prefix .railway ci
railway config plan
railway config apply
```

Run these from the repository root. Authorize Railway's GitHub integration for
the repository if needed. Review the plan, then apply it. The config uses the
named partial `blind-driver` so unrelated services are outside its ownership.
For an existing project, use `railway link` instead of `railway init`; compare
the proposed service names with your existing services before applying. The
manual frontend-only instructions above are simplest if you already have a relay.

Railway-generated public domains are not managed by the IaC file. After apply,
generate the **relay** domain first (port 10000), then generate the **frontend**
domain (port 8080). Redeploy the frontend once the referenced relay domain exists.
Pushing the IaC file alone does not apply infrastructure changes. GitHub service
deploys follow the autodeploy settings in your Railway project; deploy compatible
client and relay revisions together and update both players between rides.

Official references: [Railway IaC](https://docs.railway.com/infrastructure-as-code),
[IaC fields](https://docs.railway.com/infrastructure-as-code/reference),
[Dockerfile detection](https://docs.railway.com/builds/dockerfiles),
[health checks](https://docs.railway.com/deployments/healthchecks), and
[public domains](https://docs.railway.com/networking/public-networking).
Legacy `railway.json`/`railway.toml` is deprecated for new services, so this
repository does not introduce it.

## Browser behavior

- Use a desktop browser with **WebGL 2**, a keyboard or gamepad, and a voice call
  for your navigator. There are no touch driving controls or built-in voice chat.
- The export uses Compatibility rendering and **one thread**. No cross-origin
  isolation headers, SharedArrayBuffer, PWA installation, or service worker are
  required. Procedural engine and siren audio use **Stream** playback. If loading
  takes a while, click inside the game to unlock sound.
- **Two players / two windows** and direct-LAN controls are hidden on the Web.
  Use two computers in an online lobby, shared screen, or solo practice.
- Keep both game tabs visible and the computers awake. Browsers throttle hidden
  tabs; the driver owns the simulation, so backgrounding their tab can stall a
  ride. Browser Escape may first exit fullscreen; press it again for the menu.
- Lobby name, preferred seat, and personal best use browser storage for that
  site's origin. Private browsing, cleared data, or changing domains can lose
  these preferences. A reload closes the current game and its in-memory resume
  credential; it does not resume a saved world. Use **Cancel / leave lobby** before
  reloading so the seat is released promptly.
- **F8 → Download network logs** exports browser-side JSONL. The normal live
  metrics and connection check remain available. See the relay's `/diagnostics`
  page for a separate transport check.
- Large game assets are precompressed with Brotli/gzip. Responses require cache
  revalidation to avoid mixing old engine and game files after a deployment.

See [Godot's Web export documentation](https://docs.godotengine.org/en/stable/tutorials/export/exporting_for_web.html)
for browser rendering, audio, storage, and background-tab constraints.

## Local build and verification

Install Godot 4.7.2 and its matching export templates, and use Node 20+:

```sh
GODOT=/path/to/godot bash tools/export_web.sh
node --test frontend/server.test.mjs
npm --prefix server ci
npm --prefix server test
python3 tests/run_checks.py --relay

# Separate terminal: relay
PORT=10000 node server/index.mjs

# Separate terminal: frontend
PORT=8080 BLIND_DRIVER_RELAY_URL=http://127.0.0.1:10000 node frontend/server.mjs
```

Open `http://localhost:8080`. HTTP/WS relay addresses are accepted only for
localhost development. The frontend reads `BLIND_DRIVER_RELAY_URL` at startup;
when omitted, it uses the existing Render relay. Railway should set it explicitly.

To test the production containers (Railway builds Linux amd64):

```sh
docker build --platform linux/amd64 -t blind-driver-frontend .
docker build --platform linux/amd64 -t blind-driver-relay server
docker run --rm -p 8080:8080 -e BLIND_DRIVER_RELAY_URL=https://YOUR-RELAY-DOMAIN blind-driver-frontend
```

Before sharing a live release, use two computers on its public frontend URL.
Verify navigator-first arrival, matching car/patrol movement, map and rear-view
controls, audio, restart, and a temporary reconnect. That public TLS/two-computer
check is distinct from local browser and integration checks.
