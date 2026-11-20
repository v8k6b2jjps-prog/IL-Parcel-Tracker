<# :
@cls
@echo off
chcp 65001 >nul
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$global:ScriptFile = '%~f0'; iex ([System.IO.File]::ReadAllText('%~f0', [System.Text.Encoding]::UTF8))"
exit /b
#>

$rawContent = [System.IO.File]::ReadAllText($global:ScriptFile, [System.Text.Encoding]::UTF8)
$htmlMatch = [System.Text.RegularExpressions.Regex]::Match(
    $rawContent,
    '(?s)__HTML_START__\r?\n(.*?)\r?\n__HTML_END__'
)

if (-not $htmlMatch.Success) {
    Write-Host "Failed to extract embedded HTML using regex." -ForegroundColor Red
    exit 1
}

# --- choose a port: prefer 8787, fall back to a free one if it's busy ---
$port = 8787
try {
    $probe = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 8787)
    $probe.Start(); $probe.Stop()
} catch {
    $probe = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $probe.Start(); $port = ([System.Net.IPEndPoint]$probe.LocalEndpoint).Port; $probe.Stop()
}

# --- write the page, injecting the chosen port ---
$html = $htmlMatch.Groups[1].Value.Replace('__PORT__', "$port")
$htmlPath = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "Parcel-Tracker.html")
[System.IO.File]::WriteAllText($htmlPath, $html, (New-Object System.Text.UTF8Encoding($false)))

$appArgs = @(
    "--app=file:///$($htmlPath -replace '\\', '/')"
    "--guest"
    "--window-size=740,700"
    "--window-position=120,70"
)

$edgePath = @(
    "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
    "${env:ProgramFiles}\Microsoft\Edge\Application\msedge.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1

$chromePath = @(
    "${env:ProgramFiles}\Google\Chrome\Application\chrome.exe",
    "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1

if ($edgePath) {
    Start-Process -FilePath $edgePath -ArgumentList $appArgs
} elseif ($chromePath) {
    Start-Process -FilePath $chromePath -ArgumentList $appArgs
} else {
    Start-Process $htmlPath
}

$listenerCode = @'
$port   = __PORT__
$allow  = @('api.hfd.co.il', 'run.hfd.co.il', 'chita-il.com', 'apimftprd.israelpost.co.il')
$marker = 'Parcel Tracker'
$htmlPath = '__HTMLPATH__'

# Reliable window-title lookup across ALL visible top-level windows
# (Get-Process MainWindowTitle is blank for Edge --guest --app windows).
Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class WinFind {
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr l);
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    public static bool TitleContains(string needle) {
        bool found = false;
        EnumWindows((h, l) => {
            if (IsWindowVisible(h)) {
                var sb = new StringBuilder(512);
                GetWindowText(h, sb, sb.Capacity);
                if (sb.ToString().IndexOf(needle, StringComparison.OrdinalIgnoreCase) >= 0) { found = true; return false; }
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }
}
"@

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$port/")
try { $listener.Start() } catch { exit 1 }

$ar = $listener.BeginGetContext($null, $null)   # async arm (callback-style)

do {
    # Wait up to 60s; returns immediately when a request arrives.
    $gotCommand = $ar.AsyncWaitHandle.WaitOne(60000)

    if ($gotCommand) {
        $ctx = $listener.EndGetContext($ar)
        $req = $ctx.Request
        $res = $ctx.Response

        $res.Headers.Add('Access-Control-Allow-Origin', '*')
        $res.Headers.Add('Access-Control-Allow-Methods', 'GET, OPTIONS')
        $res.Headers.Add('Access-Control-Allow-Headers', 'Content-Type, Ocp-Apim-Subscription-Key, X-Requested-With, Accept')

        if ($req.HttpMethod -eq 'OPTIONS') {
            $res.StatusCode = 204
            $res.Close()
        }
        elseif ($req.Url.AbsolutePath -eq '/gcx') {
            # GCX (gcx.co.il) is an ASP.NET postback: GET the page for tokens, then POST the number.
            try {
                $gnum = $req.QueryString['num']
                $gurl = 'https://info.gcx.co.il/gcx_event/Default.aspx'
                $gua  = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/158.0.0.0 Safari/537.36'
                $g1 = Invoke-WebRequest -Uri $gurl -UserAgent $gua -SessionVariable gsess -UseBasicParsing -TimeoutSec 25 -ErrorAction Stop
                $gh = $g1.Content
                $vs = [System.Net.WebUtility]::HtmlDecode(([regex]::Match($gh, 'name="__VIEWSTATE"[^>]*?value="([^"]*)"')).Groups[1].Value)
                $vg = ([regex]::Match($gh, 'name="__VIEWSTATEGENERATOR"[^>]*?value="([^"]*)"')).Groups[1].Value
                $ev = [System.Net.WebUtility]::HtmlDecode(([regex]::Match($gh, 'name="__EVENTVALIDATION"[^>]*?value="([^"]*)"')).Groups[1].Value)
                $gbody = [ordered]@{
                    '__EVENTTARGET' = ''; '__EVENTARGUMENT' = '';
                    '__VIEWSTATE' = $vs; '__VIEWSTATEGENERATOR' = $vg; '__EVENTVALIDATION' = $ev;
                    'tbHAWB_NUM' = $gnum; 'BtnTrack' = 'TRACK / עקוב'
                }
                $g2 = Invoke-WebRequest -Uri $gurl -Method POST -Body $gbody -WebSession $gsess -UserAgent $gua -Headers @{ 'Referer' = $gurl; 'Origin' = 'https://info.gcx.co.il' } -UseBasicParsing -TimeoutSec 25 -ErrorAction Stop
                $gbytes = $g2.RawContentStream.ToArray()
                $res.ContentType = 'text/html; charset=utf-8'
                $res.StatusCode = 200
                $res.OutputStream.Write($gbytes, 0, $gbytes.Length)
            }
            catch {
                $res.StatusCode = 502
                $eb = [Text.Encoding]::UTF8.GetBytes($_.Exception.Message)
                $res.OutputStream.Write($eb, 0, $eb.Length)
            }
            finally { $res.Close() }
        }
        elseif (-not $req.QueryString['url']) {
            $res.StatusCode = 400
            $buf = [Text.Encoding]::UTF8.GetBytes('Missing ?url= parameter')
            $res.OutputStream.Write($buf, 0, $buf.Length)
            $res.Close()
        }
        else {
            $targetUrl = $req.QueryString['url']
            $uri = $null
            try { $uri = [Uri]$targetUrl } catch {}

            if (-not $uri -or ($allow -notcontains $uri.Host)) {
                $res.StatusCode = 403
                $buf = [Text.Encoding]::UTF8.GetBytes('Host not allowed')
                $res.OutputStream.Write($buf, 0, $buf.Length)
                $res.Close()
            }
            else {
                try {
                    $headers = @{
                        'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/158.0.0.0 Safari/537.36'
                    }
                    foreach ($hName in @('Accept', 'Ocp-Apim-Subscription-Key', 'X-Requested-With')) {
                        $val = $req.Headers[$hName]
                        if ($val) { $headers[$hName] = $val }
                    }
                    if ($uri.Host -like '*hfd.co.il') {
                        $headers['Referer'] = 'https://run.hfd.co.il/run_public/pub_random_form.htm'
                    } elseif ($uri.Host -eq 'chita-il.com') {
                        $headers['Referer'] = 'https://chita-il.com/run_public1/'
                    } elseif ($uri.Host -like '*israelpost.co.il') {
                        $headers['Origin'] = 'https://doar.israelpost.co.il'
                    }

                    $webResp = Invoke-WebRequest -Uri $targetUrl -Headers $headers -UseBasicParsing -TimeoutSec 25 -ErrorAction Stop
                    $bytes = $webResp.RawContentStream.ToArray()
                    if ($webResp.Headers['Content-Type']) {
                        $res.ContentType = $webResp.Headers['Content-Type']
                    }
                    $res.StatusCode = [int]$webResp.StatusCode
                    $res.OutputStream.Write($bytes, 0, $bytes.Length)
                }
                catch {
                    $res.StatusCode = 502
                    $errBytes = [Text.Encoding]::UTF8.GetBytes($_.Exception.Message)
                    $res.OutputStream.Write($errBytes, 0, $errBytes.Length)
                }
                finally {
                    $res.Close()
                }
            }
        }

        $ar = $listener.BeginGetContext($null, $null)   # re-arm for the next request
        $titleFound = $true                              # a live request means the window is open
    }
    else {
        # No request for a while -> is the app window still open? (keep looping while the title exists)
        $titleFound = [WinFind]::TitleContains($marker)
    }
}
while ($gotCommand -or $titleFound)

try { $listener.Stop() } catch {}
Remove-Item $htmlPath -Force -ErrorAction SilentlyContinue
'@

# Launch the listener via -EncodedCommand (base64): the whole script travels as a
# single argument, so quotes/newlines in the code can't break the command line.
$listenerCode = $listenerCode.Replace('__PORT__', "$port").Replace('__HTMLPATH__', $htmlPath)
$encodedCode = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($listenerCode))
Start-Process -FilePath "powershell.exe" -WindowStyle Hidden -ArgumentList @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-EncodedCommand", $encodedCode
)

<#
__HTML_START__
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>Parcel Tracker</title>
  <style>
    :root {
      --dark: #253444;
      --accent: #ee685f;
      --bg: #f5f6f8;
      --con-bg: #1c1e22;
      --con-fg: #dee2e6;
      --muted: #828a94;
      --border: #cfd5dd;
    }

    * { box-sizing: border-box; }

    html, body {
      margin: 0; padding: 0; height: 100%;
      background: var(--bg);
      font-family: "Segoe UI", system-ui, -apple-system, sans-serif;
      color: var(--dark); overflow: hidden;
    }

    .window { width: 100%; height: 100%; display: flex; flex-direction: column; }

    .header {
      background: var(--dark); color: #fff; height: 48px; padding: 0 16px;
      display: flex; align-items: center; justify-content: space-between; flex-shrink: 0;
    }
    .header-title { font-size: 18px; font-weight: 600; letter-spacing: 0.2px; }
    .header-sub { color: var(--accent); font-size: 12.5px; font-weight: 500; }
    .accent-bar { height: 3px; background: var(--accent); flex-shrink: 0; }

    .body { padding: 12px 16px 14px; flex: 1; display: flex; flex-direction: column; min-height: 0; }

    label { font-size: 13px; font-weight: 500; color: var(--dark); display: block; margin-bottom: 4px; }

    textarea#txtNum {
      width: 100%; height: 84px; resize: vertical; padding: 6px 9px;
      font-size: 13px; font-family: Consolas, "Courier New", monospace;
      background: #fff; color: var(--dark); border: 1px solid #9aa3ae; outline: none;
    }
    textarea#txtNum:focus { border-color: var(--dark); }

    .controls { display: flex; align-items: center; gap: 8px; margin-top: 10px; flex-wrap: wrap; }
    .controls #txtPhone { flex: 0 0 180px; }
    .controls .status { margin-left: auto; }
    input[type="text"] {
      height: 36px; padding: 4px 9px; font-size: 14px; font-family: inherit;
      background: #fff; color: var(--dark); border: 1px solid #9aa3ae; outline: none;
    }
    input[type="text"]:focus { border-color: var(--dark); }
    .hint { font-size: 12px; color: var(--muted); margin-top: 6px; }
    button {
      height: 36px; padding: 0 16px; border: 0; font-family: inherit; font-size: 13.5px;
      font-weight: 600; cursor: pointer; color: #fff; display: inline-flex; align-items: center;
      transition: background-color 0.15s ease;
    }
    button#btnTrack { background: var(--dark); }
    button#btnTrack:hover:not(:disabled) { background: var(--accent); }
    button.secondary { background: #5b6672; }
    button.secondary:hover:not(:disabled) { background: #6b7480; }
    button:disabled { opacity: 0.55; cursor: not-allowed; }
    .status { font-size: 13px; color: var(--dark); font-weight: 500; }

    .results { flex: 1; display: flex; flex-direction: column; min-height: 0; margin-top: 10px; }
    .tabs { display: flex; gap: 2px; flex-shrink: 0; }
    .tab { height: 30px; padding: 0 18px; background: #e3e6ea; color: var(--muted); border: 0;
           font-family: inherit; font-size: 13px; font-weight: 600; cursor: pointer; }
    .tab.active { background: var(--dark); color: #fff; }
    .tabpanel { flex: 1; display: flex; flex-direction: column; min-height: 0; }
    .tabpanel.hidden { display: none; }

    .tablewrap { flex: 1; overflow: auto; border: 1px solid #e3e6ea; }
    table#summary { width: 100%; border-collapse: collapse; font-size: 12.5px; }
    #summary th, #summary td { text-align: left; padding: 4px 8px; border-bottom: 1px solid #eef0f2; white-space: nowrap; }
    #summary th { position: sticky; top: 0; background: #eef0f2; color: var(--muted); font-weight: 600; }
    #summary td.st { white-space: normal; }
    #summary td.ok { color: #1a7f37; }
    #summary td.bad { color: #c4342b; }

    pre#out {
      margin: 0; width: 100%; flex: 1; min-height: 0;
      background: var(--con-bg); color: var(--con-fg); border: 1px solid #111316;
      padding: 8px 10px; font-family: Consolas, "Courier New", monospace;
      font-size: 12.5px; line-height: 1.4; overflow: auto; white-space: pre;
    }
  </style>
</head>
<body>
  <div class="window">
    <div class="header">
      <div class="header-title">Parcel Tracker</div>
      <div class="header-sub">HFD &nbsp;/&nbsp; Israel Post &nbsp;/&nbsp; Cheetah &nbsp;/&nbsp; GCX</div>
    </div>
    <div class="accent-bar"></div>

    <div class="body">
      <form id="trackForm">
        <label for="txtNum">Tracking numbers &mdash; paste a list or any text (ED&hellip; / AE&hellip; / SN&hellip; / RS&hellip; auto-extracted)</label>
        <textarea id="txtNum" autocomplete="off" placeholder="ED004795367&#10;RS1352727496Y&#10;AE041971705&#10;SN8094856"></textarea>
        <div class="controls">
          <input id="txtPhone" type="text" autocomplete="off" placeholder="Phone (HFD / Cheetah)" />
          <button id="btnTrack" type="submit">Track all</button>
          <button id="btnClip" type="button" class="secondary">Paste</button>
          <button id="btnFile" type="button" class="secondary">Load file</button>
          <input id="fileInput" type="file" accept=".txt,.csv,.log,text/plain" hidden />
          <button id="btnCopy" type="button" class="secondary">Copy</button>
        </div>
      </form>

      <div class="results">
        <div class="tabs">
          <button type="button" class="tab active" data-tab="summary">Results</button>
          <button type="button" class="tab" data-tab="console">Console</button>
        </div>
        <div class="tabpanel" id="tab-summary">
          <div class="tablewrap">
            <table id="summary">
              <thead><tr><th>#</th><th>Number</th><th>Carrier</th><th>Status</th></tr></thead>
              <tbody></tbody>
            </table>
          </div>
        </div>
        <div class="tabpanel hidden" id="tab-console">
          <pre id="out"></pre>
        </div>
      </div>
    </div>
  </div>

  <script>
    try { window.resizeTo(740, 700); } catch (e) {}

    const IPOST_KEY = "5ccb5b137e7444d885be752eda7f767a";

    // Pulls every ED.., AE.., RS..Y (and S10-style) token out of arbitrary text.
    const TRACK_RX = /\b(?:ED\d{5,}|AE\d{5,}|SN\d{5,}|RS\d{5,}[A-Z]{0,2}|[A-Z]{2}\d{6,}[A-Z]{1,2})\b/gi;

    const form = document.getElementById("trackForm");
    const txtNum = document.getElementById("txtNum");
    const txtPhone = document.getElementById("txtPhone");
    const btnTrack = document.getElementById("btnTrack");
    const btnClip = document.getElementById("btnClip");
    const btnCopy = document.getElementById("btnCopy");
    const btnFile = document.getElementById("btnFile");
    const fileInput = document.getElementById("fileInput");
    const lblStatus = { textContent: "" }; // status line removed; assignments are harmless no-ops
    const out = document.getElementById("out");
    const tbody = document.querySelector("#summary tbody");

    const writeOut = (line = "") => { out.textContent += line + "\r\n"; };

    function clearResults() { out.textContent = ""; tbody.innerHTML = ""; }

    function normalizeNum(num) { return (num || "").replace(/[^A-Za-z0-9]/g, "").toUpperCase(); }
    function normalizePhone(phone) { return (phone || "").replace(/\D/g, ""); }

    function extractNumbers(text) {
      const found = (text || "").toUpperCase().match(TRACK_RX) || [];
      const seen = new Set(); const list = [];
      for (const m of found) { if (!seen.has(m)) { seen.add(m); list.push(m); } }
      return list;
    }

    function detectCarrier(num) {
      const n = normalizeNum(num);
      if (n.startsWith("ED")) return "HFD";
      if (n.startsWith("AE")) return "Chita";
      if (n.startsWith("SN")) return "GCX";
      if (n.startsWith("RS")) return "Post";
      if (/^[A-Z]{2}\d{6,}[A-Z]{0,2}$/.test(n)) return "Post";
      return null;
    }

    const PROXY_BASE = "http://localhost:__PORT__/?url=";
    function proxiedUrl(targetUrl) { return PROXY_BASE + encodeURIComponent(targetUrl); }

    function decodeHtmlEntities(str) {
      const el = document.createElement("textarea");
      el.innerHTML = str;
      return el.value;
    }

    function getXmlTagValue(xmlText, tagName) {
      const doc = new DOMParser().parseFromString(xmlText, "text/xml");
      const all = doc.getElementsByTagName("*");
      for (let i = 0; i < all.length; i++) {
        if (all[i].localName === tagName) return (all[i].textContent || "").trim();
      }
      const m = xmlText.match(new RegExp(`<${tagName}[^>]*>([\\s\\S]*?)</${tagName}>`, "i"));
      return m ? decodeHtmlEntities(m[1]).trim() : "";
    }

    function parseRunComDetail(html) {
      const im = html.match(/:\s*([0-9]{4,})\s*<\/span>/);
      const internalNum = im ? im[1] : "";
      const events = [];
      const rx = /<tr[^>]*>\s*<td[^>]*>([\s\S]*?)<\/td>\s*<td[^>]*>([\s\S]*?)<\/td>\s*<td[^>]*>([\s\S]*?)<\/td>\s*<\/tr>/gi;
      let m;
      while ((m = rx.exec(html)) !== null) {
        const date = decodeHtmlEntities(m[1].replace(/<[^>]+>/g, " ")).trim();
        const time = decodeHtmlEntities(m[2].replace(/<[^>]+>/g, " ")).trim();
        let status = decodeHtmlEntities(m[3].replace(/<[^>]+>/g, " ")).trim().replace(/\s{2,}/g, " ");
        if (date || time || status) events.push({ Date: date, Time: time, Status: status });
      }
      return { InternalNum: internalNum, Events: events };
    }

    // Plain text (XML / JSON): decode by the server charset.
    async function fetchText(url, options = {}) {
      const resp = await fetch(proxiedUrl(url), options);
      const text = await resp.text();
      if (!resp.ok) throw new Error(`HTTP ${resp.status} ${resp.statusText}: ${text.slice(0, 160)}`);
      return text;
    }

    // RunCom detail pages: decode UTF-8, fall back to Windows-1255 (the meta tag can lie).
    async function fetchDecoded(url, options = {}) {
      const resp = await fetch(proxiedUrl(url), options);
      const buf = await resp.arrayBuffer();
      if (!resp.ok) {
        const t = new TextDecoder("utf-8").decode(buf).slice(0, 160);
        throw new Error(`HTTP ${resp.status} ${resp.statusText}: ${t}`);
      }
      let s = new TextDecoder("utf-8", { fatal: false }).decode(buf);
      if (s.includes("�")) s = new TextDecoder("windows-1255").decode(buf);
      return s;
    }

    async function trackHfd(num, phone) {
      const apiUrl = "https://api.hfd.co.il/rest/v3/api/ship-locate-num-and-phone?num=" +
        encodeURIComponent(num) + "&phone=" + encodeURIComponent(phone);
      const xmlText = await fetchText(apiUrl, { headers: { "Accept": "*/*" } });
      const message = getXmlTagValue(xmlText, "status_message");
      const token = getXmlTagValue(xmlText, "ship_rand_num");
      if (message) return { Found: false, Message: message };
      if (!token) return { Found: false, Message: "no token returned" };
      const html = await fetchDecoded(
        "https://run.hfd.co.il/runcom.server/request.aspx?APPNAME=run&PRGNAME=ship_locate_random&ARGUMENTS=-A" + encodeURIComponent(token),
        { headers: { "Accept": "text/html,*/*" } });
      const parsed = parseRunComDetail(html);
      if (!parsed.Events.length) return { Found: false, Message: "no events (possibly not found)" };
      return { Found: true, InternalNum: parsed.InternalNum, Events: parsed.Events };
    }

    async function trackChita(num, phone) {
      const step1Url = "https://chita-il.com/RunCom.Server/Request.aspx?APPNAME=RUN&PRGNAME=ship_locate_num_and_phone&ARGUMENTS=-N" +
        encodeURIComponent(num) + ",-A" + encodeURIComponent(phone);
      const xmlText = await fetchText(step1Url, {
        headers: { "Accept": "application/xml, text/xml, */*; q=0.01", "X-Requested-With": "XMLHttpRequest" }
      });
      const message = getXmlTagValue(xmlText, "status_message");
      const token = getXmlTagValue(xmlText, "ship_rand_num");
      if (message) return { Found: false, Message: message };
      if (!token) return { Found: false, Message: "no token returned" };
      const html = await fetchDecoded(
        "https://chita-il.com/RunCom.Server/Request.aspx?APPNAME=run&PRGNAME=ship_locate_random&ARGUMENTS=-A" + encodeURIComponent(token),
        { headers: { "Accept": "text/html,*/*" } });
      const parsed = parseRunComDetail(html);
      if (!parsed.Events.length) return { Found: false, Message: "no events (possibly not found)" };
      return { Found: true, InternalNum: parsed.InternalNum, Events: parsed.Events };
    }

    // ---- GCX (SN..): ASP.NET postback done server-side by the local proxy at /gcx ----
    const GCX_BASE = PROXY_BASE.replace(/\?url=$/, "gcx?num=");
    function gcxSpan(html, id) {
      const m = html.match(new RegExp('<span[^>]*id="' + id + '"[^>]*>([\\s\\S]*?)</span>', "i"));
      if (!m) return "";
      return decodeHtmlEntities(m[1].replace(/<[^>]+>/g, " ")).replace(/\s{2,}/g, " ").trim();
    }
    async function trackGcx(num) {
      const resp = await fetch(GCX_BASE + encodeURIComponent(num));
      const html = await resp.text();
      if (!resp.ok) return { Found: false, Message: "HTTP " + resp.status + (html ? ": " + html.slice(0, 120) : "") };
      const curEng = gcxSpan(html, "LbCurrentStatusEng");
      const idx = [...new Set([...html.matchAll(/id="lbEventDescrEng(\d+)"/g)].map((m) => +m[1]))].sort((a, b) => a - b);
      const events = [];
      for (const i of idx) {
        const eng = gcxSpan(html, "lbEventDescrEng" + i);
        const heb = gcxSpan(html, "lbEventDescrHeb" + i);
        const date = gcxSpan(html, "lbEventDate" + i);
        const time = gcxSpan(html, "lbEventTime" + i);
        const status = heb ? (eng ? eng + " / " + heb : heb) : eng;
        events.push({ Date: date, Time: time, Status: status });
      }
      if (!curEng && !events.length) return { Found: false, Message: "not found / no data" };
      const company = gcxSpan(html, "lbDeliveryCompnyName");
      const origin = gcxSpan(html, "lbOrigenCounteyEng") || gcxSpan(html, "lbOriginCountryEng");
      let info = [];
      if (company) info.push("via " + company);
      if (origin) info.push("from " + origin);
      return { Found: true, InternalNum: info.join("  "), Events: events };
    }

    function findEventArray(node, bestRef) {
      if (Array.isArray(node)) {
        const objs = node.filter((x) => x && typeof x === "object" && !Array.isArray(x));
        if (objs.length > 0 && objs.length >= bestRef.current.length) bestRef.current = objs;
        for (const item of node) findEventArray(item, bestRef);
      } else if (node && typeof node === "object") {
        for (const key of Object.keys(node)) findEventArray(node[key], bestRef);
      }
    }
    const prop = (o, name) => {
      const k = Object.keys(o || {}).find((k) => k.toLowerCase() === name.toLowerCase());
      return k ? String(o[k] ?? "").trim() : "";
    };

    async function trackIsraelPost(item) {
      const url = `https://apimftprd.israelpost.co.il/MyPost-itemtrace/items/${encodeURIComponent(item)}/heb`;
      const rawJson = await fetchText(url, {
        headers: { "Accept": "application/json, text/plain, */*", "Ocp-Apim-Subscription-Key": IPOST_KEY }
      });
      if (!rawJson || !rawJson.trim()) return { Found: false, Events: [], Raw: "(empty response)" };
      let obj;
      try { obj = JSON.parse(rawJson); } catch { return { Found: false, Events: [], Raw: rawJson }; }
      const bestRef = { current: [] };
      findEventArray(obj, bestRef);
      return { Found: bestRef.current.length > 0, Events: bestRef.current, Raw: rawJson };
    }

    function addRow(idx, num, carrier) {
      const tr = document.createElement("tr");
      const tdIdx = document.createElement("td"); tdIdx.textContent = idx;
      const tdNum = document.createElement("td"); tdNum.textContent = num;
      const tdCar = document.createElement("td"); tdCar.textContent = carrier || "?";
      const tdSt = document.createElement("td"); tdSt.className = "st"; tdSt.textContent = "…";
      tr.append(tdIdx, tdNum, tdCar, tdSt);
      tbody.appendChild(tr);
      tr.scrollIntoView({ block: "nearest" });
      return tdSt;
    }
    function setCell(cell, text, ok) { cell.textContent = text; cell.className = "st " + (ok ? "ok" : "bad"); }

    function blockDivider() { writeOut("-".repeat(78)); }

    async function setBusy(b) {
      [txtNum, txtPhone, btnTrack, btnClip, btnCopy, btnFile].forEach((el) => { el.disabled = b; });
    }

    function saveSession() {
      try { sessionStorage.setItem("pt_nums", txtNum.value); sessionStorage.setItem("pt_phone", txtPhone.value); } catch (e) {}
    }
    (function loadSession() {
      try {
        const n = sessionStorage.getItem("pt_nums"); if (n) txtNum.value = n;
        const p = sessionStorage.getItem("pt_phone"); if (p) txtPhone.value = p;
      } catch (e) {}
    })();

    form.addEventListener("submit", async (ev) => {
      ev.preventDefault();
      const nums = extractNumbers(txtNum.value);
      const phone = normalizePhone(txtPhone.value);
      clearResults();

      if (!nums.length) { writeOut("No tracking numbers found (expected ED…, AE…, SN…, RS…Y)."); return; }

      const needPhone = nums.some((n) => { const c = detectCarrier(n); return c === "HFD" || c === "Chita"; });
      if (needPhone && !phone) { writeOut("A phone number is required for HFD / Cheetah numbers."); return; }

      saveSession();
      await setBusy(true);
      let i = 0, ok = 0, bad = 0;

      for (const num of nums) {
        i++;
        lblStatus.textContent = `Tracking ${i} / ${nums.length}…`;
        const carrier = detectCarrier(num);
        const cell = addRow(i, num, carrier);
        try {
          if (!carrier) {
            setCell(cell, "Unknown prefix", false); bad++;
            writeOut(`${num} - carrier not recognized`); blockDivider();
          } else if ((carrier === "HFD" || carrier === "Chita") && !phone) {
            setCell(cell, "Phone required", false); bad++;
          } else if (carrier === "Post") {
            const res = await trackIsraelPost(num);
            if (res.Found) {
              const latest = prop(res.Events[0], "CategoryName") || "found";
              setCell(cell, latest, true); ok++;
              writeOut(`Israel Post - ${num}`);
              for (const e of res.Events) {
                writeOut(`    ${prop(e, "StatusDate")}  |  ${prop(e, "CategoryName")}  |  ${prop(e, "Status")}`);
              }
              blockDivider();
            } else {
              setCell(cell, "No updates", false); bad++;
              writeOut(`Israel Post - ${num}: no updates`);
              if (res.Raw) writeOut(res.Raw);
              blockDivider();
            }
          } else if (carrier === "GCX") {
            const res = await trackGcx(num);
            if (res.Found) {
              setCell(cell, res.Events.length ? res.Events[0].Status : "Found", true); ok++;
              writeOut(`GCX - ${num}${res.InternalNum ? "    " + res.InternalNum : ""}`);
              for (const e of res.Events) writeOut(`    ${e.Date}  ${e.Time}   ${e.Status}`);
              blockDivider();
            } else {
              setCell(cell, res.Message || "Not found", false); bad++;
              writeOut(`GCX - ${num}: ${res.Message || "not found"}`); blockDivider();
            }
          } else {
            const res = carrier === "Chita" ? await trackChita(num, phone) : await trackHfd(num, phone);
            if (res.Found) {
              setCell(cell, res.Events[0].Status, true); ok++;
              writeOut(`${carrier} - ${num}    internal: ${res.InternalNum}`);
              for (const e of res.Events) writeOut(`    ${e.Date}  ${e.Time}   ${e.Status}`);
              blockDivider();
            } else {
              setCell(cell, res.Message || "Not found", false); bad++;
              writeOut(`${carrier} - ${num}: Not found - ${res.Message || ""}`); blockDivider();
            }
          }
        } catch (err) {
          const msg = err && err.message ? err.message : String(err);
          setCell(cell, "Error", false); bad++;
          writeOut(`${carrier || "?"} - ${num}: Error - ${msg}`); blockDivider();
        }
      }

      lblStatus.textContent = `Done - ${nums.length} numbers (${ok} found, ${bad} issues).`;
      await setBusy(false);
    });

    function flash(btn, txt) { const o = btn.textContent; btn.textContent = txt; setTimeout(() => { btn.textContent = o; }, 1200); }
    btnCopy.addEventListener("click", async () => {
      const text = out.textContent;
      try { await navigator.clipboard.writeText(text); flash(btnCopy, "Copied"); }
      catch (e) {
        const r = document.createRange(); r.selectNodeContents(out);
        const sel = getSelection(); sel.removeAllRanges(); sel.addRange(r);
        try { document.execCommand("copy"); flash(btnCopy, "Copied"); } catch (e2) {}
        sel.removeAllRanges();
      }
    });

    btnClip.addEventListener("click", async () => {
      try {
        const t = await navigator.clipboard.readText();
        txtNum.value = (txtNum.value ? txtNum.value + "\n" : "") + t;
      } catch (e) {
        txtNum.focus();          // clipboard read is blocked in file:// windows
        flash(btnClip, "Ctrl+V");
      }
    });

    btnFile.addEventListener("click", () => fileInput.click());
    fileInput.addEventListener("change", () => {
      const f = fileInput.files[0];
      if (!f) return;
      const r = new FileReader();
      r.onload = () => {
        txtNum.value = (txtNum.value ? txtNum.value + "\n" : "") + String(r.result);
        lblStatus.textContent = "Loaded " + f.name;
      };
      r.readAsText(f);
      fileInput.value = "";
    });

    // Tabs: Results (short) / Console (full)
    document.querySelectorAll(".tab").forEach((t) => {
      t.addEventListener("click", () => {
        document.querySelectorAll(".tab").forEach((x) => x.classList.remove("active"));
        document.querySelectorAll(".tabpanel").forEach((x) => x.classList.add("hidden"));
        t.classList.add("active");
        document.getElementById("tab-" + t.dataset.tab).classList.remove("hidden");
      });
    });
  </script>
</body>
</html>
__HTML_END__
#>
