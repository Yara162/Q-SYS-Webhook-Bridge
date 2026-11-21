# Q-SYS Webhook Bridge

A Q-SYS plugin that sends an HTTP request when a control changes. Wire a room's occupancy, a fault
LED, a mic mute or a "help" button to it, and the event reaches Slack, Teams, Home Assistant,
Node-RED, ntfy, Zapier, a ticketing system or anything else that accepts a webhook.

- **Up to 16 triggers**, each with its own URL, method and body.
- **Two input pins per trigger:** *In* for logic (toggle, LED, wired logic) and *Text In* for
  strings and numbers.
- **Modes:** On Change, On Rising (In goes true), On Falling (In goes false), Manual (the Send button only).
- **Placeholders** in the URL and body: `{name}` `{value}` `{string}` `{bool}` `{trigger}` `{time}`
  `{epoch}` `{design}`. In a JSON body they're JSON-escaped; in a URL, URL-encoded.
- **Delivery:** one request at a time from a queue, with a timeout and retries on network errors,
  429 and 5xx. When the queue is full, the oldest waiting request is dropped and counted.
- **Shared settings:** a Base URL that relative trigger URLs join onto, extra headers, and a bearer token.

Made by YZ at the SmartSpaces programming department. Provided as-is, under the [MIT License](LICENSE).

## Tested On

| | |
|---|---|
| Q-SYS Core | **Not yet run on a Core.** |
| Simulation | `tests/sim.lua`: 51 checks against stand-ins for the Q-SYS runtime and a fake server, all passing |
| Lint | [Q-SYS Plugin Linter](https://github.com/Yara162/Q-SYS-Plugin-Linter): no findings |

The simulation's assumptions about Q-SYS (how `HttpClient`, `Timer` and control events behave) are
listed at the top of `tests/sim.lua`. Until it has run on a Core, treat this as a first version.

## Install

The plugin ships as two identical files; use either one.

- **`webhook-bridge.qplug`:** double-click it, and Q-SYS Designer installs it.
- **`webhook-bridge.lua`:** in Q-SYS Designer, **Tools > Design Resources > Import**, and pick it.

Then drag **Webhook Bridge** from the User tree (folder *Smart Spaces WI*) into the design, and set
**Trigger Count** in Properties.

## Set up

1. **Setup page:** turn **Active** on. Nothing is sent while it is off, so a freshly placed plugin
   stays quiet until you're ready.
2. Optionally set a **Base URL** (for example `http://homeassistant.local:8123`), **Headers**
   (`Name: value; Name: value`) and a **Bearer Token**.
3. **Triggers page**, per trigger: a **Name**, **ON**, a **Mode**, a **Method**, a **URL** (full,
   or starting with `/` to join the Base URL) and a **Body**.
4. Wire a control pin to the trigger's **In** or **Text In** pin, or press **SEND** to test.

Each trigger shows an **OK** light and its last result (`14:02:11 200`). The Setup page counts sent,
failed and dropped requests and shows the status, which is also an output pin.

### Placeholders

| Placeholder | Becomes |
|---|---|
| `{name}` | The trigger's Name, or "Trigger N" |
| `{value}` | Text In as a number if it is one, else 1/0 from In. Unquoted, for JSON numbers |
| `{string}` | Text In, or "true"/"false" from In when Text In is empty |
| `{bool}` | `true` or `false` from In |
| `{trigger}` | The trigger's number |
| `{time}` | Core local time, `2026-11-21T14:02:11` |
| `{epoch}` | Seconds since 1970 |
| `{design}` | The running design's name |

A body that starts with `{` or `[` is treated as JSON: it's sent as `application/json` and
placeholders are escaped. Anything else is sent as `text/plain` unless you set a `Content-Type` header.

## Examples

**Slack** (incoming webhook), Method POST, full URL from Slack:

```json
{"text":"{name} in {design}: {string} at {time}"}
```

**Home Assistant**: Base URL `http://homeassistant.local:8123`, trigger URL
`/api/webhook/qsys-boardroom`, Method POST, and in an automation use a *Webhook* trigger with that ID.
The default body sends `trigger`, `value`, `string`, `time` and `design` fields.

**Node-RED**: an *http in* node on `POST /qsys`, Base URL `http://nodered.local:1880`, trigger URL `/qsys`.

**ntfy** (phone push): URL `https://ntfy.sh/your-topic`, Method POST, plain-text body
`{name}: {string}`.

## Properties

| Property | Default | |
|---|---|---|
| Trigger Count | 4 | 1–16 |
| Timeout (seconds) | 5 | Per attempt |
| Retries | 1 | Extra attempts after a network error, 429 or 5xx, 2 s apart then 4 s… |
| Queue Size | 20 | Requests waiting; the oldest is dropped when full |
| Min Seconds Between Sends | 0 | Per trigger; repeats within it are skipped (Send ignores it) |
| Log Requests | off | Prints each request and result to the debug output |

## Limits

- **Outbound only.** Receiving webhooks into Q-SYS is a possible next version.
- **The bearer token is saved in the design file**, like any other control value.
- **HTTPS** depends on the Core's `HttpClient` and its certificate handling. Plain HTTP on the
  control network is the easiest place to start.
- One request is in flight at a time, so a slow server holds up the queue for up to the timeout
  times the retries.

## Develop

```bash
lua5.3 tests/sim.lua webhook-bridge.qplug
```

Keep `webhook-bridge.lua` and `webhook-bridge.qplug` identical (`cmp` runs in CI).
