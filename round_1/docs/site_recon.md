# Recon Log — Recovering Dataset 01

The rulebook states the corrupted dataset is not handed out: it has to be
recovered from `https://datavortex-social-engine.vercel.app/`. This is the
solve path, recorded so the provenance of `data/raw/` is auditable and it is
clear the files were retrieved, not received.

---

## Target

| | |
|---|---|
| URL | `https://datavortex-social-engine.vercel.app/` |
| Stack | Vite + React 18.3.1, static deploy on Vercel |
| Entry bundle | `/assets/index-B2FT5USN.js` |
| Stylesheet | `/assets/index-C1sM7F53.css` |

Everything is client-side. There is no backend to attack and none was
attacked: the whole puzzle ships inside the JavaScript bundle, so the work
was reading the application's own code and then driving its own UI.

---

## Step 1 — Landing page

`/` renders a fake boot sequence and a `CRITICAL SYSTEM FAILURE` panel:
every subsystem reports `OFFLINE` / `CORRUPTED` / `UNAVAILABLE`, integrity
`07%`, `NODES ONLINE 1 / 9`. One button: `[ ENTER RECOVERY MODE ]`.

`1 / 9` is the first real signal. Nine nodes, one alive — the interface is
telling you a survivor exists before it tells you anything else.

## Step 2 — Recovery mode dashboard

After the gate, ten module tiles (HOME, DATABASE, ANALYTICS, REPORTS, USERS,
LIVE SIGNAL, SYSTEM, BACKUP, ARCHIVE, HELP). Every tile is dead by design —
the bundle maps each to a canned failure string:

```js
tu = { hang: "NOT RESPONDING", static: "SIGNAL LOST",
       pageerror: "UNREACHABLE", denied: "ACCESS LOCKED", dead: "NO RESPONSE" }
```

Clicking tiles is the dead end the puzzle wants you to exhaust.

## Step 3 — The system log (rulebook hint #2)

The dashboard streams a `SYSTEM LOG` panel. The rulebook says to watch what
appears at the **beginning of each line**. The lines are stored in the
bundle as the array `Oi`:

```
03:42:17  database.service        exited with code 137
03:42:19  analytics.service       segfault, core not found
03:42:21  live_signal.service     carrier lost, retrying...
03:42:21  live_signal.service     retry failed, giving up
03:42:23  node_07                 responded 200 (intermittent)
03:42:26  watchdog                last known good node: node_07
03:42:31  watchdog                dashboard link to node_07: severed
```

Lines 5–7 are the payload. Amid six failures, one identifier returns HTTP
200, is named the last known good node, and has had its dashboard link cut.
The route is alive; only the navigation to it is gone.

Once the log finishes streaming, the page appends a `clue-strip` element:

> `last known surviving node: node_07`

and, if you stall, a `stuck-hint`:

> `Nothing responding? There may be another way in.`

That is the rulebook's "message hidden in plain sight" — literally a DOM
node that only mounts after the log completes.

## Step 4 — The recovery shell

Bottom-right floating action button (`term-fab`, terminal icon) opens a
command panel. `help` enumerates the vocabulary:

```
available commands: help, status, scan, logs, clear
```

`scan` is the one that matters:

```
scanning subsystems...
7 modules detected, all unresponsive via dashboard link.
node_07 responding intermittently, outside normal routing.
manual reconnection may be possible.
```

"Outside normal routing" + "manual reconnection may be possible" is an
instruction, not flavour text.

## Step 5 — Manual reconnection

`help` never lists the winning command; it is matched by a regex hidden in
the bundle's command handler:

```js
/(connect|access|restore|reconnect|link)/.test(b) && /(node.?0?7|archive)/.test(b)
```

So any verb from the first group plus any spelling of the node from the
second group opens the door. The canonical form, confirmed by the bundle's
own diagnostic panel (`Real path: terminal: connect node_07`):

```
connect node_07
```

Response:

```
establishing manual link to node_07...
link unstable -- retrying...
connection stabilized.
redirecting to archive interface...
```

This is the rulebook's "Follow the pattern. Decode the connection. Find the
node." — pattern = the log lines, connection = `connect`, node = `node_07`.

## Step 6 — Archive Node 07

The app routes to an `ARCHIVE NODE 07` view (`CONNECTION: UNSTABLE`), runs a
progress bar, and then exposes the file manifest, defined in the bundle as
the constant `Gi`:

```js
Gi = { files: [
  { label: "Users",            fileName: "Social_Engine_Users.csv",
    filePath: "/dataset/Social_Engine_Users.csv" },
  { label: "Posts (corrupted)", fileName: "Social_Engine_Posts_Corrupted.csv",
    filePath: "/dataset/Social_Engine_Posts_Corrupted.csv" }
]}
```

Both files downloaded from:

```
https://datavortex-social-engine.vercel.app/dataset/Social_Engine_Users.csv
https://datavortex-social-engine.vercel.app/dataset/Social_Engine_Posts_Corrupted.csv
```

---

## Retrieved artefacts

| File | Bytes | Rows (incl. header) | SHA-256 |
|---|---:|---:|---|
| `Social_Engine_Posts_Corrupted.csv` | 2,053,401 | 12,361 | BA76C0B2F9C2C4F3B7507DB569A54AD90CA2C7F710F82FE3B6942103071D39CC |
| `Social_Engine_Users.csv` | 78,398 | 1,501 | 13FF50A8FEFBE3D3A108EE17FCFEE419C8FD7CF60F3BB22EDBB98BAE13F46F74 |

Both land unmodified in `round_1/data/raw/` and are never written to. The
pipeline reads from `raw/`, writes to `interim/` and `processed/`, so the
recovered originals stay byte-identical to what the archive node served.

```powershell
Get-FileHash .\round_1\data\raw\Social_Engine_Posts_Corrupted.csv -Algorithm SHA256
Get-FileHash .\round_1\data\raw\Social_Engine_Users.csv -Algorithm SHA256
```

---

## Notes on method

- No authentication was bypassed, no server was probed, no rate limit was
  hit. The bundle is public static JavaScript; the manifest, the log array
  and the command regex are all shipped to every visitor.
- The intended path — read the log, open the shell, `connect node_07` — was
  followed end to end through the UI. Reading the bundle only *confirmed*
  the command regex and the file paths afterwards.
- The dashboard's operator field is populated from the registered account,
  so the retrieval is attributable to this team rather than anonymous.
