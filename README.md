# DeviceRetirementAutomation

## What this does

When a device is retired, it needs to be cleaned up in four separate systems:
Active Directory, SCCM, Absolute, and Cisco Secure Endpoint. Each one has its
own console, its own auth model, and its own manual process.

This orchestrator takes a list of hostnames and serial numbers as input, and retires the device in all four systems. There is also an audit report that gets produced, plus one running ledger across every run.

All scripts default to preview mode as a safety guard. The code won't execute unless you explicitly
use `-PreviewOnly $false`.

---

## Why I built this

We have a hardware lifecycle project coming up and my team is going to be replacing hundreds of machines
across the org. Every single device retirement is a 4-step manual process:
open each console, find the device, action it, move on. Multiply that by hundreds
of machines and you have weeks of repetitive work, no audit trail, and a high
margin for something getting missed. We would track devices with spreadsheets, but all of these are manual actions that can be handled much more safely and efficiently.

I built this ahead of the project so that when the first batch of machines land, the process
is already greased and ready to go. All four systems have confirmed working auth.
First production run is next.

The hardest part of building this was Absolute. Their v3 API uses a custom JWS/HS256 signed
request model with no SDK, so I had to build this entirely from scratch. The auth
implementation was correct early on - the blocker turned out to be a token
permission scope (`device-reports-view`) that Absolute's own support team
misconfigured on the initial setup and that isn't documented anywhere in their
API docs. Took about six weeks of vendor back-and-forth to land on that root
cause. Once the token was scoped correctly, it worked.

The other systems use standard module auth: ConfigurationManager for SCCM, ActiveDirectory
module for AD, and an API token with Basic auth for Cisco AMP.

---

## Requirements

- PowerShell 7+
- Microsoft.PowerShell.SecretManagement + a registered vault (for API credentials)
- ActiveDirectory module (for AD retirement)
- ConfigurationManager module (for SCCM retirement)
- Network access to each target system's API or management console

---

## Setup

1. Copy `.env.example` to `.env` in the repo root and fill in your values:

```
ABSOLUTE_API_BASE=https://api.absolute.com
CISCO_AMP_API_BASE=https://api.amp.cisco.com
SCCM_SITE_CODE=ABC
AD_DISABLED_COMPUTERS_OU=OU=Disabled Computers,OU=_Disabled,DC=corp,DC=example,DC=com
OUTPUT_DIR=.\out
EXTRA_SKIP_PATTERNS=
```

2. Store API credentials in your SecretManagement vault:

```powershell
Set-Secret -Name AbsoluteTokenId     -Secret 'your-token-id'
Set-Secret -Name AbsoluteTokenSecret -Secret 'your-token-secret'
Set-Secret -Name CiscoAmpClientId    -Secret 'your-client-id'
Set-Secret -Name CiscoAmpApiKey      -Secret 'your-api-key'
```

3. Drop your device list in `DangerZone-DevicesToBeRetired\`. Either shape works:

```
Hostname,SerialNumber
WORKSTATION-01,ABC123
WORKSTATION-02,DEF456
```

or a plain `.txt` with names anywhere in it. Tabs, spaces, a sentence at the top, doesn't matter.
Anything shaped like `XX-something` is read as a hostname, the rest is ignored.
Every file in the folder gets picked up and duplicates are collapsed.

---

## Usage

### Test authentication only

```powershell
.\Invoke-DeviceRetirement.ps1 -TestAuthOnly
```

Checks auth against all four systems and exits, prints success or fail.

To test a subset:

```powershell
.\Invoke-DeviceRetirement.ps1 -TestAuthOnly -Systems Absolute,AD
```

### Preview mode (default)

Looks up every device in each system and logs what would happen. Read only, so no changes will be made.

```powershell
.\Invoke-DeviceRetirement.ps1
```

Reads everything in `DangerZone-DevicesToBeRetired\`. Point it at one file instead with `-CsvPath`.

### Action mode

```powershell
.\Invoke-DeviceRetirement.ps1 -PreviewOnly $false -ConfirmCiscoDelete
```

It asks you to type the device count before it touches anything. `-ConfirmCiscoDelete` is required
if Cisco is in the run, because that delete cannot be undone. Batches over 500 are refused unless
you raise `-MaxBatch` on purpose.

### Target specific systems

```powershell
.\Invoke-DeviceRetirement.ps1 -Systems SCCM,AD
```

Valid values: `Absolute`, `CiscoAmp`, `SCCM`, `AD`

---

## Big batches

Things I learned sizing this for hundreds of machines at a time.

- Run it on hardware that is already wiped or gone. Cisco and SCCM only delete the console record. A live agent re-registers on its next check-in.
- Absolute only unenrolls devices whose agent status is Active. Anything already dark logs as Found and stays put. It also has a daily threshold per action type, so check the Unenroll threshold in the console before a big day or the API starts returning 429.
- Waves of 100 to 150 beat one 500 shot. Preview logs are the only gate, so read the Found and NotFound counts against what you expect before flipping to action.
- Unattended runs: pass `-Force` to skip the typed confirmation, and set the vault to no password with `Set-SecretStoreConfiguration -Authentication None -Interaction None` or it sits waiting for a prompt.
- `out\ledger.csv` is the running record across every run, with a `RunId` column. Send that, not the folders.

---

## What each script does

| Script | Action (action mode) |
|---|---|
| `Retire-Absolute.ps1` | Looks up device by hostname or serial number, sends unenroll request if agent is active. Auth is a signed JWS/HS256 token. |
| `Retire-CiscoAmp.ps1` | Looks up connector by hostname, deletes the console record. Includes rate limit backoff and retry handling. |
| `Retire-SCCM.ps1` | Finds device by hostname via ConfigurationManager module, removes the resource record. |
| `Retire-AD.ps1` | Finds computer by hostname, disables, and moves it to the disabled computers OU. |

---

## Whitelist

Infrastructure you never want retired (distribution points, site servers, domain
controllers) is protected by an allow-list you define, not a hardcoded rule. Put real
names or wildcard patterns in `EXTRA_SKIP_PATTERNS` in `.env` as a comma-separated list,
for example `DP01,SCCM-*,DC-*`. Matching is wildcard and full-string (`-like`), so a
short pattern won't silently skip every machine that merely contains those letters.
Whitelisted devices are logged but never actioned.

---

## Output

Each run creates a timestamped directory under `OUTPUT_DIR`:

```
out\
  ledger.csv
  20260410-143022\
    targets.csv
    Retirement-Absolute-20260410-143022.csv
    Retirement-CiscoAmp-20260410-143023.csv
    Retirement-SCCM-20260410-143024.csv
    Retirement-AD-20260410-143025.csv
```

Each log CSV contains: `Timestamp`, `Hostname`, `SerialNumber`, `System`,
`Action`, `Status`, `Detail`. `targets.csv` is the exact deduped list that run used.
`ledger.csv` is every log from every run appended together with a `RunId` column.

---

## Running scripts individually

Each `Retire-*.ps1` can be run without the orchestrator:

```powershell
.\Retire-AD.ps1 -CsvPath .\batch.csv -PreviewOnly $false
.\Retire-Absolute.ps1 -TestAuthOnly
```

All scripts accept `-CsvPath`, `-EnvPath`, `-OutputDir`, `-PreviewOnly`,
and `-TestAuthOnly`.
