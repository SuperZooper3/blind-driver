# Blind Driver

A two-player cooperative game about driving a car blind. Players use separate computers: one drives, and the other helps them navigate. The initial target is a low-poly 3D game that runs in desktop browsers and can be played online through an invite link.

This document is a plan, not a description of an existing implementation. The precise player roles and interactions still need to be designed and tested.

## Recommended approach

Build the game in **Godot 4 with GDScript**, export it for the web, and host the exported files as a static site. Run a small WebSocket service on **Render** to create two-player rooms and relay messages. The driver's browser simulates the car; the navigator's browser receives snapshots and renders a smooth representation of it.

```text
                 HTTPS: download the same Godot web build
       ┌──────────────── Static site ────────────────┐
       ▼                                            ▼
Driver's browser ─────── WebSocket relay ─────── Navigator's browser
  Simulates car          Rooms and messages       Displays car and world
  Runs game physics      No 3D or car physics     Sends navigator actions
```

The relay can handle many separate rooms in a single service process. A room is a logical grouping of players; it does not need its own server process. Start with one service instance and in-memory rooms. This is an established host-authoritative, relayed multiplayer model, used for cooperative games where players can trust each other. See [Nakama's description of relayed multiplayer](https://heroiclabs.com/docs/gameplay-multiplayer-realtime/) and [Unity's relay documentation](https://docs.unity.com/relay/relay-servers).

This model is a good fit if the navigator mostly observes the car and gives directions. If both players eventually need to control the same physics objects continuously, revisit the authority and synchronization design.

## Player flow

1. A player opens the game and creates a room.
2. The service returns an invite link or code. The other player opens it and joins the room.
3. The players choose roles and wait until both game clients are ready.
4. The driver simulates the car and sends snapshots and events. The navigator displays the shared game state and sends any game actions back to the driver.
5. If a player disconnects, pause or show a connection issue and allow a short rejoin window. If the authoritative driver cannot return, offer a restart rather than silently continuing a broken simulation.
6. Remove abandoned rooms after a timeout. Initially, players can communicate through a separate voice call; in-game voice chat is not part of the first milestone.

Invite links should use sufficiently unpredictable room identifiers. The service should enforce the two-player limit, check message size and rate, reject malformed messages, and use HTTPS and secure WebSockets (`wss://`). These are basic public-service safeguards, not a full anti-cheat system.

## Physics and synchronization

### One simulation, two views

The driver is authoritative for the car and gameplay-critical physics. Their browser runs the physics and determines collisions, checkpoints, resets, and other results. It sends the resulting state to the navigator through the relay.

The navigator does **not** run a competing simulation of the same car. Instead, it renders a representation based on received state. Independently running the same simulation on both machines risks divergence from timing and physics differences, especially over bumpy terrain. The tradeoff is that the driver's client is trusted and its view of the game is the source of truth.

Initial snapshot fields should include:

- Position and orientation, plus linear and angular velocity.
- A sequence number and simulation timestamp for ordering and timing.
- Steering, wheel, and suspension state where needed for a convincing view.
- Any other dynamic objects that materially affect what the navigator sees; cosmetic effects can be approximated locally.

Send discrete events such as collisions, checkpoints, start, finish, and resets separately from continuous snapshots, with enough ordering or identifiers to avoid duplicates and inconsistent state. The driver remains responsible for deciding the outcome of navigator actions. Keep the initial scope small: adding many independently interacting physics objects will increase synchronization work.

### Make the navigator's view smooth

Do not simply move the navigator's car to each newly received position. Store a short buffer of timestamped snapshots and interpolate position and rotation between them on each rendered frame. The navigator's camera should follow the same interpolated transform, with independently tuned camera smoothing and roll to avoid uncomfortable motion. Wheel and suspension visuals can be synchronized or approximated, depending on what looks good in testing.

Start experiments at **30 snapshots per second** and with a **50–100 ms interpolation buffer**. These are tuning starting points, not performance guarantees. Handle missing snapshots with bounded extrapolation or a graceful freeze; show a connection warning and pause when updates are too stale. Snap or reset the interpolation buffer for teleports and game resets rather than drawing a path through the world.

Godot's local physics interpolation and network snapshot interpolation solve related but different timing problems; a networked view may need its own interpolation. See [Godot's physics interpolation introduction](https://docs.godotengine.org/en/stable/tutorials/physics/interpolation/physics_interpolation_introduction.html) and [Snapshot Interpolation](https://gafferongames.com/post/snapshot_interpolation/).

### Account for delay in the game design

Interpolation makes movement smoother by rendering slightly in the past. The navigator's view also incurs travel time from the driver through the relay. For example, 60 ms of network travel plus an 80 ms buffer is about 140 ms behind the driver; at 10 m/s, the car travels about 1.4 m during that time. Voice latency and human reaction add further delay. Actual results depend on network conditions and implementation.

Design turns, visibility, speed, and braking distance so the navigator can give useful instructions early enough. Test camera comfort as well as accuracy: faithfully reproducing every bump and roll is not necessarily the most comfortable experience.

## Transport: WebSocket first, WebRTC if needed

Start with WebSockets because browsers support them and they are easy to deploy through Render. Use a small, explicit message protocol and keep the transport separate from the game and interpolation logic so it can be replaced.

WebSockets are reliable and ordered over TCP. Under packet loss, an old missing packet can delay newer car snapshots; this can cause visible stalls. Godot notes this tradeoff for fast-paced games in its [WebSocket documentation](https://docs.godotengine.org/en/stable/tutorials/networking/websocket.html). Limit queues and avoid generating unnecessary stale updates, while recognizing that data already queued in TCP cannot simply be discarded by the application.

If tests show unacceptable stalls or delay, evaluate **WebRTC**. It can use an unreliable channel for frequent movement snapshots and a reliable channel for important events. It still needs a signaling service, STUN configuration, and a TURN relay for networks that cannot establish a direct connection; TURN adds operating and bandwidth costs. Direct connection is not guaranteed. Godot supports WebRTC in web exports: [Godot WebRTC](https://docs.godotengine.org/en/stable/tutorials/networking/webrtc.html) and [WebRTCMultiplayerPeer](https://docs.godotengine.org/en/stable/classes/class_webrtcmultiplayerpeer.html).

Neither transport removes latency, and neither automatically implements physics synchronization. Choose based on measurements and playtests.

## Hosting and platform choices

### Initial setup

- **Game:** Godot 4, GDScript, Compatibility renderer, targeting desktop browsers first. Start with a single-threaded web export and test the actual browser build early. Godot 4 C# projects currently cannot be exported to the web. See [Godot web export](https://docs.godotengine.org/en/stable/tutorials/export/exporting_for_web.html), [C# platform support](https://docs.godotengine.org/en/stable/tutorials/scripting/c_sharp/), and [renderer guidance](https://docs.godotengine.org/en/stable/tutorials/rendering/renderers.html).
- **Static site:** Host the exported HTML, WebAssembly, and game assets over HTTPS, for example as a Render static site.
- **Relay:** A small Node.js/TypeScript Render web service with room creation, joining, message forwarding, connection health, and cleanup. Use Godot's WebSocket client with an explicit protocol; a custom Node relay does not automatically speak Godot's high-level multiplayer RPC protocol.
- **Storage:** Keep initial room state in memory. A database is unnecessary until we need persistent accounts, progress, or other durable data.
- **Availability:** Start with one backend instance. A restart or deploy can interrupt active games, so communicate the disconnect and support recovery or restart. Scaling to multiple instances later requires room-aware routing or shared coordination because connections may reach different instances. See [Render WebSockets](https://render.com/docs/websocket).

Render's free service is useful for experiments but can spin down after inactivity and can restart. For a public build, evaluate a paid service and current bandwidth limits. Costs depend on usage; check [Render's pricing](https://render.com/pricing) and [free-service limitations](https://render.com/docs/free) before deploying.

### Alternatives to revisit

| Option | Advantages | Tradeoffs |
| --- | --- | --- |
| **Nakama** | Game backend with relayed matches, accounts, matchmaking, and an official Godot SDK. | More infrastructure and concepts than a small two-player relay needs. Attractive if we add friends, accounts, progression, or matchmaking. |
| **Colyseus** | Multiplayer framework with rooms and state synchronization. | Its Godot GDExtension is currently marked beta, and its web setup requires extension support. Evaluate browser compatibility before committing. |
| **Cloudflare Durable Objects** | Named objects provide a natural coordination point per room, with managed WebSocket infrastructure. | Different development and billing model; measure costs for frequent game updates. Hibernation is most useful during idle periods. |
| **Headless Godot game servers** | A central Godot instance can simulate gameplay and physics. | More deployment and operating complexity; a remote driver still needs latency compensation for responsive controls. Consider if shared physics or other requirements justify it. |

These options manage connections or game services; they do not automatically solve the navigator's vehicle interpolation and camera experience. References: [Nakama Godot SDK](https://heroiclabs.com/docs/nakama/client-libraries/godot/), [Colyseus Godot SDK](https://docs.colyseus.io/getting-started/godot), [Cloudflare WebSockets](https://developers.cloudflare.com/durable-objects/best-practices/websockets/), and [Godot dedicated servers](https://docs.godotengine.org/en/stable/tutorials/export/exporting_for_dedicated_servers.html).

## First milestone: prove online driving feels good

1. Build a small low-poly test course with slopes, bumps, turns, and an obstacle. Prototype the car and both roles locally.
2. Export to the browser and verify that the scene performs acceptably on two target computers. Test Godot's built-in vehicle controller, but do not assume it is final: [VehicleBody3D has documented limitations](https://docs.godotengine.org/en/stable/classes/class_vehiclebody3d.html). Try a custom arcade controller if needed.
3. Add a minimal WebSocket service with two-player rooms and invite links, then deploy the game and relay.
4. Have the driver simulate the car and send snapshots; implement the navigator's interpolation and camera. Add ready, reset, disconnect, and rejoin behavior.
5. Play from two physical computers, including across different networks. Test added latency, jitter, packet loss, and connection interruptions. Record snapshot age, visible stalls, frame rate, and whether the navigator can give timely directions.
6. Tune the track, speed, camera, snapshot rate, and buffer. If TCP-related stalls remain disruptive, compare the same gameplay over WebRTC, including TURN fallback.

The milestone succeeds when driving feels responsive, the navigator's view is comfortable and sufficiently current for navigation, and two people can reliably create and join a session online. Agree on concrete latency and performance targets after initial playtests; the starting numbers above are not acceptance guarantees.
