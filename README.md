# PRTG License Sensor — the sensor count you are actually billed for

> 中文說明：**[README.zh-TW.md](README.zh-TW.md)**
>
> TL;DR — PRTG shows *total* objects; the licence meters fewer than that, and for subscriptions the
> product displays **twice** what you bought. This custom sensor reports the real number
> `all objects − (status 7 paused ∪ status 11 licence-paused ∪ created < 24 h ago)`
> and turns it into PRTG channels,
> so you get history, daily peaks and alarms.

PRTG shows total objects. The vendor meters something narrower, and for subscription licenses the
number shown in the product is **twice** what you subscribed to. This tool answers two questions:

1. **How many sensors are actually metered right now?**
2. **How close is that to the licence quota — over time?** (billing follows the *daily peak*, not a snapshot)

## Three terms first

Every PRTG **object** (a sensor, device, group...) carries a **status code**; the API column is
`status_raw`. The official names are: `Unknown=1`, `Collecting=2`, `Up=3`, `Warning=4`, `Down=5`,
`NoProbe=6`, `PausedbyUser=7`, `PausedbyDependency=8`, `PausedbySchedule=9`, `Unusual=10`,
`PausedbyLicense=11`, `PausedUntil=12`, `DownAcknowledged=13`, `DownPartial=14`.

| Status code | Official name | In plain words | How this tool treats it |
|---|---|---|---|
| **7** | `PausedbyUser` | Paused: either you paused it, or something **above** it in the tree is paused and it came along | **not metered, deducted** |
| **11** | `PausedbyLicense` | PRTG decided the licence was exceeded and paused the surplus itself | **not metered, deducted**; any value above 0 means the ceiling has been hit |
| **3** | `Up` | Normally collecting data | metered (not deducted) |

Two more words used throughout this file:

* **quota** — how many sensors you bought. On **subscription** licences (`EditionType=S`) PRTG shows
  **twice** that number; the tool converts it back for you.
* **metered count** — the number that actually consumes the licence and that the vendor bills on.
  **PRTG never shows this number**; the UI shows total objects.

## Formula

```
metered = all objects  -  ( status 7 paused  U  status 11 licence-paused  U  created < 24 h ago )
```

| Deducted | Why |
|---|---|
| **status code 7** (`PausedbyUser`) | Paused sensors hold no licence, whether paused directly or through a parent object. |
| **status code 11** (`PausedbyLicense`) | Already paused by PRTG because the ceiling was reached. |
| **created < 24 h** | A brand-new object is not metered yet (vendor *Sensor Overage Policy*). Change the threshold with `-AgeHours`. |

The three sets form a **union**: one object is never deducted twice.

### Licence ceiling

The tool's only criterion is **whether `MaxSensorCount` (from `/api/getstatus.htm`) parses as a number**:

| `MaxSensorCount` | Meaning | Behaviour |
|---|---|---|
| parses | this server exposes its configurable sensor ceiling | `EditionType=F` / `C`: the value **is** the quota. `EditionType=S` (subscription): **divide by 2** (`-SubscriptionDivisor`) to get the real subscribed quantity |
| `(Tag maxsensorcount unknown)` or endpoint unreachable | ceiling unknown | **Nothing is guessed** — the metered count is still reported; supply the quota with `-LicenseLimit` |

In practice only an **administrator** account returns a real `MaxSensorCount`; read-only accounts and
API keys return `(Tag maxsensorcount unknown)`. For subscription licences, exceeding the quota is
**billed retroactively** without pausing anything, and status 11 only appears at 2× the quota —
so **status code 11 being 0 is not evidence that you are within quota**.

## Files

| File | Purpose |
|---|---|
| `prtg-license-sensor.ps1` | PRTG **EXE/Script Advanced** custom sensor — emits channel XML so the number is recorded every interval. That one file is the whole tool. |

## Install the sensor

1. Copy `prtg-license-sensor.ps1` to `Custom Sensors\EXEXML\` under the **PRTG program directory**, on the machine
   that runs the probe — typically `C:\Program Files (x86)\PRTG Network Monitor\Custom Sensors\EXEXML\`. Remote
   probe → copy it to the probe machine; cluster → every node. A new file can take tens of seconds to show up.
2. **Add Sensor** → type **EXE/Script Advanced**. PRTG does not invoke PowerShell on its own, so point *EXE/Script*
   at the wrapper from step 3, or at the interpreter directly:
   ```
   EXE/Script:  prtg-license-sensor.bat
   Parameters:  -BaseUri https://127.0.0.1 -TokenFile "C:\ProgramData\prtg-license\token.txt" -LicenseLimit 100
   ```
   With `powershell.exe` / `pwsh.exe` in that field, Parameters must start with
   `-NoProfile -ExecutionPolicy Bypass -File prtg-license-sensor.ps1`. A `.ps1` selected on its own collects
   nothing. The working directory is `Custom Sensors\EXEXML`, so a bare file name resolves.
3. Wrapper — the one part that matters is `%*`, without it the parameters never reach the script:
   ```bat
   @echo off
   powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0prtg-license-sensor.ps1" %*
   ```
4. Parameters — **paths only, never the key** (they are stored in plain text and visible in the sensor settings
   and API responses):
   ```
   -BaseUri http://127.0.0.1 -TokenFile "C:\ProgramData\prtg-license\token.txt" -LicenseLimit 100
   ```
   `-TokenFile` holds one line with the API key, `-PasshashFile` one line `username:passhash`; a BOM, CRLF,
   surrounding quotes and `#` comment lines are tolerated. Restrict the file to the PRTG probe service account.
5. Polling interval: 300 s is plenty (a few thousand objects cost roughly 1-3 s against localhost).
6. ⚠ **This sensor is itself 1 sensor** and counts toward your licence.
7. Collects nothing? PRTG keeps the raw script output in `Result of Sensor <id>.txt` (setting `resultfile`, under
   `Logs\Sensors\Custom\Results\`).

**Reading the history**: chart the **maximum over the last 24 h** of `Licensed sensors`
(or `Quota usage %`). The vendor bills on the *highest value of the day*, not on a snapshot, and
that is exactly what turning this number into a channel buys you.

## Channels

| Channel | Meaning |
|---|---|
| `Licensed sensors` | ★ the metered count (formula above) |
| `PRTG total sensors` | all objects |
| `Paused (code 7)` | objects in status 7 (`PausedbyUser`) |
| `Not licensed (code 11)` | objects in status 11 (`PausedbyLicense`); above 0 means the ceiling was reached |
| `Created under age limit` | objects deducted as "younger than N hours" |
| `License quota` | quota (subscription already divided); `0` when unknown |
| `Ceiling readable` | `1` = `MaxSensorCount` parsed, `0` = not readable |
| `Quota usage %` | metered ÷ quota |

Channel limits are **not** emitted by default (the limit element names differ between PRTG versions);
set the 80 % / 100 % thresholds on the sensor's **Channel Limits** tab instead, or pass `-Limits`.

## Parameters

| Parameter | Default | Description |
|---|---|---|
| `-BaseUri` | `http://127.0.0.1` | web root, **without** `/api` |
| `-TokenFile` / `-PasshashFile` | — | recommended: file with the API key / `username:passhash` |
| `-ApiToken` / `-Username` `-Passhash` | — | direct values (they end up in plain text in sensor settings) |
| `-LicenseLimit` | `0` | real quota (subscription: the subscribed number, not the displayed one) |
| `-SubscriptionDivisor` | `2` | displayed ceiling ÷ quota for `EditionType=S`; use `1` for perpetual licences |
| `-AgeHours` | `24` | "created at least N hours ago" threshold |
| `-NoAgeCheck` | off | skip that deduction |
| `-TimeoutSec` | `30` | maps to the sensor timeout |
| `-AllowSelfSigned` | off | accept a self-signed / name-mismatched TLS certificate. **Loopback is trusted automatically** — this switch is for a *remote* host |
| `-Limits` | off | emit channel limits from the script (see note above) |
| `-LogStderr` | off | debug output on stderr (PRTG ignores stderr) |

## How it reads PRTG (single request)

Everything comes from **one** request: `GET /api/table.xml?content=sensortree&count=100000`
(`content=sensortree` is a Table Query that returns the whole device tree together with per-sensor
columns). The fields used:

* `status_raw` — the status code of each sensor. Counting them reproduces the official per-status
  query (`content=sensors&filter_status=<code>`) exactly.
* `active` — whether the sensor is enabled; combined with status 7 this separates direct pause from
  parent-driven pause.
* the two fields below, for the "created recently" test:

| Field | Test |
|---|---|
| `cumulateduptime_raw` | accumulated "Up" seconds reaches N hours or more ⇒ the object is certainly that old |
| `statussince_raw_utc` | the current status started earlier than *now minus N hours* ⇒ the object already existed then |

Both are **one-sided**: they can prove an object is *not* new. Anything that cannot be proven is
deducted as "created < N hours" (disable with `-NoAgeCheck`). Proving creation time exactly requires
an administrator account reading the object's `content=history` (`Created.` entry), which read-only
credentials cannot read.

If `content=sensortree` cannot be read, the sensor answers `<prtg><error>…</error></prtg>` and PRTG
marks it Down **with the reason** — deliberate: a silently partial number is worse than a red sensor.

## PRTG quirks worth knowing

* Invalid credentials can answer `HTTP 200` with HTML `OK`, not `401`. Never trust the status code alone: the
  script requires parseable JSON containing an integer `treesize`.
* `statussince_raw_utc = 0` means *no value*, not the year 1899.
* Values use `.` as the decimal separator → parse with `InvariantCulture`, or a German/French host misreads them.
* `Invoke-WebRequest` returns an `XmlDocument` for `text/xml` on Windows PowerShell 5.1 and a string on 7; both
  are handled.
* stdout **is** the protocol: no `Write-Host`, progress records off, debug to stderr, channel names and `<text>`
  in ASCII (the 5.1 console codepage mangles anything else into the history), and every failure answers
  `<prtg><error>…</error></prtg>`.
* API keys are not numeric and their character set is whatever PRTG decides — do not validate them by character
  class. Only whitespace, control characters, a stray BOM, or a body starting with `<`/`{` are rejected.
* HTTPS to `127.0.0.1`/`localhost` always shows a name-mismatched certificate (issued for the server's own name).
  Loopback is trusted automatically; a remote self-signed host needs `-AllowSelfSigned`.
* Do not hand .NET a PowerShell scriptblock as a certificate callback — .NET calls it from a thread without a
  PowerShell runspace. A compiled `ICertificatePolicy` is used instead.
* From a console, `.\script.ps1` loads `$PROFILE`; `powershell -NoProfile -File .\script.ps1` does not.

## Requirements

* Windows PowerShell **5.1** (the engine PRTG uses for this sensor type) or PowerShell **7**.
* Any credential that may read the device tree; an administrator is only needed for the quota and for
  exact creation dates.
* Read-only API. Nothing is written to PRTG.

**Before creating the sensor**, run it once from a console, in the `Custom Sensors\EXEXML` folder:

```
powershell -NoProfile -ExecutionPolicy Bypass -File .\prtg-license-sensor.ps1 -BaseUri https://127.0.0.1 -TokenFile C:\ProgramData\prtg-license\token.txt -LicenseLimit 100
```

A good run prints exactly one `<prtg>` document — 8 `<result>` channels plus `<text>`. A failing run prints
exactly one document too, `<prtg><error>reason</error></prtg>`, and the exit code is still 0; add
`-LogStderr` for the per-step trace on stderr.

Console success is **not** the same as sensor success: PRTG runs the script as the **probe service account**
(that account must be able to read the credential file) and only via `powershell.exe` / a wrapper. So
"works in the console, nothing collected in PRTG" points at the invocation in steps 2-3 or at file
permissions, not at the formula.

## Licence

[MIT](LICENSE).
