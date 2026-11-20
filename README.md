# IL Parcel Tracker

Track Israeli parcel shipments by tracking number — **HFD**, **Chita (ציטה)**,
**GCX** and **Israel Post (דואר ישראל)** — with the carrier auto-detected from
the number prefix. Three independent, self-contained versions are included;
pick whichever fits how you want to run it. No backend, no database, no install
for the script versions.

## Versions

| Version | File | What it is | Needs installed | Batch / multi-number |
|---------|------|------------|-----------------|----------------------|
| **HTML** (Invoke-WebApp) | `Invoke-WebApp.cmd` | One double-clickable `.cmd` that spins up a tiny local proxy and opens a web UI in the browser | Nothing (Windows built-in PowerShell) | ✅ paste a list, auto-extract, Results/Console tabs |
| **WPF** | `WPF/ParcelTracker/` | Native C# desktop app | .NET SDK (net5.0-windows; retarget as needed) | ❌ one number at a time |
| **PS1** | `Parcel-Tracker.ps1` | WinForms GUI in a single PowerShell script | Nothing (Windows PowerShell 5.1) | ❌ one number at a time |

`Invoke-TrackingApp.lnk` is a convenience shortcut for launching the HTML
version.

> A hosted, browser-only build (GitHub Pages + a Cloudflare Worker) lives in the
> sibling repo **parcel-tracker**. GCX there depends on the Worker being able to
> reach GCX's origin — see the GCX note below.

## Carriers

| Prefix | Carrier | Needs phone | How it's tracked |
|--------|---------|-------------|------------------|
| `ED…` | HFD | yes | RunCom 2-step: XML token → HTML timeline |
| `AE…` | Chita (ציטה) | yes | RunCom 2-step, self-hosted |
| `SN…` | GCX | no | ASP.NET postback (GET tokens → POST); hands off to YDM |
| `RS…` / `…IL` / other S10 | Israel Post | no | MyPost JSON API |

**Detection order:** `ED` → HFD, `AE` → Chita, `SN` → GCX, then anything shaped
like *two letters + digits (+ trailing letters)* → Israel Post. `ED`, `AE` and
`SN` are pinned (proprietary, non-postal formats); every postal prefix is caught
generically, so new `R…`/`C…`/`E…` postal variants route to Israel Post
automatically.

The number box is forgiving — it strips spaces, hidden RTL marks and paste
artifacts before matching, so pasting straight from an email or SMS works.

## Quick start

**HTML (Invoke-WebApp)** — easiest, nothing to install:
```
Double-click Invoke-WebApp.cmd   (or Invoke-TrackingApp.lnk)
```
It launches a local proxy, opens the UI, and closes the proxy when you close the
window. Paste one or many numbers, add a phone for HFD/Chita, and hit **Track all**.

**PS1** — single-number WinForms GUI:
```
Right-click Parcel-Tracker.ps1 → Run with PowerShell
   or:  powershell -ExecutionPolicy Bypass -File .\Parcel-Tracker.ps1
```

**WPF** — native desktop app (needs the .NET SDK):
```powershell
cd WPF/ParcelTracker
dotnet run
```
Or open `WPF/ParcelTracker.sln` in Visual Studio 2022 and press F5. For a
single self-contained `.exe`:
```powershell
dotnet publish -c Release -r win-x64 --self-contained true `
  /p:PublishSingleFile=true /p:IncludeNativeLibrariesForSelfExtract=true
```

## How it works

All versions share the same per-carrier logic:

- **HFD / Chita** use the same **RunCom** system. Step 1 is an XML call that
  returns a `ship_rand_num` token; step 2 fetches the HTML timeline keyed by that
  token. Both need the recipient **phone** as a second factor. The timeline HTML
  is decoded as UTF-8 with a Windows-1255 fallback (the page's own meta tag can
  lie).
- **Israel Post** calls the **MyPost JSON API** (number only) and shows
  `Date | Status | Detail`.
- **GCX** is an **ASP.NET WebForms postback**: a GET harvests
  `__VIEWSTATE` / `__VIEWSTATEGENERATOR` / `__EVENTVALIDATION` plus the
  `ASP.NET_SessionId` cookie, then a POST submits the number. GCX is a
  China→Israel consolidator that hands the last mile to **YDM**; the timeline
  shows both the English and Hebrew event text, and no phone is required.

Why a local proxy in the HTML version? A browser can't call the carrier APIs
directly (CORS + custom headers), so `Invoke-WebApp.cmd` runs a tiny local
PowerShell listener that forwards each request with the right headers — and, for
GCX, performs the stateful two-step server-side.

## Notes

- The Israel Post `Ocp-Apim-Subscription-Key` is the site's **public** frontend key.
- Hebrew is decoded correctly everywhere (UTF-8, Windows-1255 fallback).
- **Seller self-ship** Israel Post items (often `RS…` with no trailing letter)
  frequently have **no tracking data** on Israel Post's side — an empty result is
  expected, not an app error.
- **GCX reachability:** the local versions here run from your own machine/IP, so
  GCX works the same way it does in a browser. The hosted Worker build may see
  GCX time out if GCX's origin blocks datacenter IPs — in that case use one of
  these local versions for GCX.
