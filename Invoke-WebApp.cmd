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

$htmlPath = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "Parcel-Tracker.html")
[System.IO.File]::WriteAllText($htmlPath, $htmlMatch.Groups[1].Value, [System.Text.Encoding]::UTF8)

$appProfile = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "ParcelTrackerEdgeProfile")
if (Test-Path $appProfile) { Remove-Item $appProfile -Recurse -Force -ErrorAction SilentlyContinue }

$appArgs = @(
    "--app=file:///$($htmlPath -replace '\\', '/')"
    "--guest"
    "--window-size=680,550"
    "--window-position=140,90"
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
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add('http://localhost:8787/')
try { $listener.Start() } catch { exit 1 }

while ($listener.IsListening) {
    $ctx = $listener.GetContext()
    $req = $ctx.Request
    $res = $ctx.Response

    $res.Headers.Add('Access-Control-Allow-Origin', '*')
    $res.Headers.Add('Access-Control-Allow-Methods', 'GET, OPTIONS')
    $res.Headers.Add('Access-Control-Allow-Headers', 'Content-Type, Ocp-Apim-Subscription-Key, X-Requested-With, Accept')

    if ($req.HttpMethod -eq 'OPTIONS') {
        $res.StatusCode = 204
        $res.Close()
        continue
    }

    $targetUrl = $req.QueryString['url']
    if (-not $targetUrl) {
        $res.StatusCode = 400
        $buf = [Text.Encoding]::UTF8.GetBytes('Missing ?url= parameter')
        $res.OutputStream.Write($buf, 0, $buf.Length)
        $res.Close()
        continue
    }

    try {
        $headers = @{
            'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/158.0.0.0 Safari/537.36'
        }
        foreach ($hName in @('Accept', 'Ocp-Apim-Subscription-Key', 'X-Requested-With')) {
            $val = $req.Headers[$hName]
            if ($val) { $headers[$hName] = $val }
        }
        if ($targetUrl -like '*api.hfd.co.il*' -or $targetUrl -like '*run.hfd.co.il*') {
            $headers['Referer'] = 'https://run.hfd.co.il/run_public/pub_random_form.htm'
        } elseif ($targetUrl -like '*chita-il.com*') {
            $headers['Referer'] = 'https://chita-il.com/run_public1/'
        } elseif ($targetUrl -like '*israelpost.co.il*') {
            $headers['Origin'] = 'https://doar.israelpost.co.il'
        }

        $webResp = Invoke-WebRequest -Uri $targetUrl -Headers $headers -UseBasicParsing -ErrorAction Stop
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
'@

$escapedCode = $listenerCode.Replace("'", "''")
Start-Process -FilePath "powershell.exe" -WindowStyle Hidden -ArgumentList @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-Command", "iex '$escapedCode'"
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
      margin: 0;
      padding: 0;
      height: 100%;
      background: var(--bg);
      font-family: "Segoe UI", system-ui, -apple-system, sans-serif;
      color: var(--dark);
      overflow: hidden;
    }

    .window {
      width: 100%;
      height: 100%;
      background: var(--bg);
      display: flex;
      flex-direction: column;
    }

    .header {
      background: var(--dark);
      color: #fff;
      height: 48px;
      padding: 0 16px;
      display: flex;
      align-items: center;
      justify-content: space-between;
      flex-shrink: 0;
    }

    .header-title {
      font-size: 18px;
      font-weight: 600;
      letter-spacing: 0.2px;
    }

    .header-sub {
      color: var(--accent);
      font-size: 12.5px;
      font-weight: 500;
    }

    .accent-bar {
      height: 3px;
      background: var(--accent);
      flex-shrink: 0;
    }

    .body {
      padding: 12px 16px 14px;
      flex: 1;
      display: flex;
      flex-direction: column;
      min-height: 0;
    }

    .row {
      display: flex;
      gap: 14px;
    }

    .field {
      flex: 1 1 0;
      display: flex;
      flex-direction: column;
      gap: 4px;
    }

    label {
      font-size: 13px;
      font-weight: 500;
      color: var(--dark);
    }

    input[type="text"] {
      height: 32px;
      padding: 4px 9px;
      font-size: 14px;
      font-family: inherit;
      background: #fff;
      color: var(--dark);
      border: 1px solid #9aa3ae;
      outline: none;
    }

    input[type="text"]:focus {
      border-color: var(--dark);
    }

    .hint {
      margin-top: 8px;
      font-size: 12px;
      color: var(--muted);
    }

    .proxy-row {
      margin-top: 8px;
      display: flex;
      align-items: center;
      gap: 8px;
      font-size: 12px;
      color: var(--muted);
    }

    .proxy-row input {
      height: 25px;
      font-size: 12px;
      padding: 2px 7px;
      border: 1px solid var(--border);
      color: var(--dark);
    }

    .proxy-base {
      flex: 1 1 auto;
    }

    .proxy-key {
      width: 140px;
    }

    .actions {
      margin-top: 10px;
      display: flex;
      align-items: center;
      gap: 14px;
      min-height: 36px;
    }

    button#btnTrack {
      width: 145px;
      height: 36px;
      background: var(--dark);
      color: #fff;
      border: 0;
      font-family: inherit;
      font-size: 14px;
      font-weight: 600;
      cursor: pointer;
      transition: background-color 0.15s ease;
    }

    button#btnTrack:hover:not(:disabled) {
      background: var(--accent);
    }

    button#btnTrack:disabled {
      opacity: 0.65;
      cursor: not-allowed;
    }

    .status {
      font-size: 13.5px;
      color: var(--dark);
      font-weight: 500;
    }

    pre#out {
      margin: 10px 0 0;
      width: 100%;
      flex: 1;
      min-height: 160px;
      background: var(--con-bg);
      color: var(--con-fg);
      border: 1px solid #111316;
      padding: 8px 10px;
      font-family: Consolas, "Courier New", monospace;
      font-size: 12.5px;
      line-height: 1.4;
      overflow: auto;
      white-space: pre;
    }
  </style>
</head>
<body>
  <div class="window">
    <div class="header">
      <div class="header-title">Parcel Tracker</div>
      <div class="header-sub">HFD &nbsp;/&nbsp; Israel Post &nbsp;/&nbsp; Cheetah</div>
    </div>
    <div class="accent-bar"></div>

    <div class="body">
      <form id="trackForm">
        <div class="row">
          <div class="field">
            <label for="txtNum">Tracking number</label>
            <input id="txtNum" type="text" autocomplete="off" placeholder="e.g. ED123..., AE123..., RS123..." />
          </div>
          <div class="field">
            <label for="txtPhone">Phone (HFD / Cheetah)</label>
            <input id="txtPhone" type="text" autocomplete="off" placeholder="e.g. 0501234567" />
          </div>
        </div>

        <div class="hint">Auto-detect: &nbsp;&nbsp;ED -&gt; HFD &nbsp;&nbsp;&nbsp;&nbsp;AE -&gt; Cheetah &nbsp;&nbsp;&nbsp;&nbsp;RS -&gt; Israel Post</div>

        <div class="proxy-row">
          <label for="txtProxy" style="font-size:12px;color:var(--muted);">Proxy prefix:</label>
          <input id="txtProxy" class="proxy-base" type="text" value="http://localhost:8787/?url=" placeholder="http://localhost:8787/?url= or leave blank for direct" />
          <label for="txtProxyKey" style="font-size:12px;color:var(--muted);">Key (optional):</label>
          <input id="txtProxyKey" class="proxy-key" type="text" value="" placeholder="Leave blank for local proxy" />
        </div>

        <div class="actions">
          <button id="btnTrack" type="submit">Track</button>
          <div id="lblStatus" class="status"></div>
        </div>
      </form>

      <pre id="out"></pre>
    </div>
  </div>

  <script>
    try { window.resizeTo(680, 550); } catch (e) {}

    const IPOST_KEY = "5ccb5b137e7444d885be752eda7f767a";

    const form = document.getElementById("trackForm");
    const txtNum = document.getElementById("txtNum");
    const txtPhone = document.getElementById("txtPhone");
    const txtProxy = document.getElementById("txtProxy");
    const txtProxyKey = document.getElementById("txtProxyKey");
    const btnTrack = document.getElementById("btnTrack");
    const lblStatus = document.getElementById("lblStatus");
    const out = document.getElementById("out");

    function clearOut() {
      out.textContent = "";
    }

    function writeOut(line = "") {
      out.textContent += line + "\r\n";
    }

    function normalizeNum(num) {
      return (num || "").replace(/[^A-Za-z0-9]/g, "").toUpperCase();
    }

    function normalizePhone(phone) {
      return (phone || "").replace(/\D/g, "");
    }

    function detectCarrier(num) {
      const n = normalizeNum(num);
      if (n.startsWith("ED")) return "HFD";
      if (n.startsWith("AE")) return "Chita";
      if (n.startsWith("RS")) return "Post";
      if (/^[A-Z]{2}\d{6,}[A-Z]?$/.test(n)) return "Post";
      return null;
    }

    function proxiedUrl(targetUrl) {
      const rawBase = (txtProxy.value || "").trim();
      const key = (txtProxyKey.value || "").trim();
      if (!rawBase) return targetUrl;

      if (/[?&]url=$/i.test(rawBase)) {
        const hasKey = /[?&]key=/i.test(rawBase);
        const keyPart = key && !hasKey
          ? (rawBase.includes("?") ? `&key=${encodeURIComponent(key)}` : `?key=${encodeURIComponent(key)}`)
          : "";
        return rawBase.replace(/([?&])url=$/i, `${keyPart}$1url=`) + encodeURIComponent(targetUrl);
      }

      const base = rawBase.replace(/\/+$/, "");
      const sep = base.includes("?") ? "&" : "?";
      const keyPart = key ? `key=${encodeURIComponent(key)}&` : "";
      return `${base}/${sep}${keyPart}url=${encodeURIComponent(targetUrl)}`;
    }

    function decodeHtmlEntities(str) {
      const el = document.createElement("textarea");
      el.innerHTML = str;
      return el.value;
    }

    function getXmlTagValue(xmlText, tagName) {
      const parser = new DOMParser();
      const doc = parser.parseFromString(xmlText, "text/xml");
      const all = doc.getElementsByTagName("*");
      for (let i = 0; i < all.length; i++) {
        if (all[i].localName === tagName) {
          return (all[i].textContent || "").trim();
        }
      }
      const m = xmlText.match(new RegExp(`<${tagName}[^>]*>([\\s\\S]*?)</${tagName}>`, "i"));
      return m ? decodeHtmlEntities(m[1]).trim() : "";
    }

    function parseRunComDetail(html) {
      const internalMatch = html.match(/:\s*([0-9]{4,})\s*<\/span>/);
      const internalNum = internalMatch ? internalMatch[1] : "";

      const events = [];
      const rowRegex = /<tr[^>]*>\s*<td[^>]*>([\s\S]*?)<\/td>\s*<td[^>]*>([\s\S]*?)<\/td>\s*<td[^>]*>([\s\S]*?)<\/td>\s*<\/tr>/gi;
      let match;
      while ((match = rowRegex.exec(html)) !== null) {
        const date = decodeHtmlEntities(match[1].replace(/<[^>]+>/g, " ")).trim();
        const time = decodeHtmlEntities(match[2].replace(/<[^>]+>/g, " ")).trim();
        let status = match[3].replace(/<[^>]+>/g, " ").trim();
        status = decodeHtmlEntities(status).replace(/\s{2,}/g, " ");
        if (date || time || status) {
          events.push({ Date: date, Time: time, Status: status });
        }
      }

      return { InternalNum: internalNum, Events: events };
    }

    async function fetchText(url, options = {}) {
      const resp = await fetch(proxiedUrl(url), options);
      const text = await resp.text();
      if (!resp.ok) {
        throw new Error(`HTTP ${resp.status} ${resp.statusText}: ${text.slice(0, 200)}`);
      }
      return text;
    }

    async function trackHfd(num, phone) {
      const apiUrl =
        "https://api.hfd.co.il/rest/v3/api/ship-locate-num-and-phone?num=" +
        encodeURIComponent(num) +
        "&phone=" +
        encodeURIComponent(phone);

      const xmlText = await fetchText(apiUrl, {
        headers: { "Accept": "*/*" }
      });

      const message = getXmlTagValue(xmlText, "status_message");
      const token = getXmlTagValue(xmlText, "ship_rand_num");
      if (message) return { Found: false, Message: message };
      if (!token) return { Found: false, Message: "no token returned" };

      const detailUrl =
        "https://run.hfd.co.il/runcom.server/request.aspx?APPNAME=run&PRGNAME=ship_locate_random&ARGUMENTS=-A" +
        encodeURIComponent(token);

      const html = await fetchText(detailUrl, {
        headers: { "Accept": "text/html,*/*" }
      });

      const parsed = parseRunComDetail(html);
      if (!parsed.Events.length) {
        return { Found: false, Message: "no events (possibly not found)" };
      }

      return { Found: true, InternalNum: parsed.InternalNum, Events: parsed.Events };
    }

    async function trackChita(num, phone) {
      const step1Url =
        "https://chita-il.com/RunCom.Server/Request.aspx?APPNAME=RUN&PRGNAME=ship_locate_num_and_phone&ARGUMENTS=-N" +
        encodeURIComponent(num) +
        ",-A" +
        encodeURIComponent(phone);

      const xmlText = await fetchText(step1Url, {
        headers: {
          "Accept": "application/xml, text/xml, */*; q=0.01",
          "X-Requested-With": "XMLHttpRequest"
        }
      });

      const message = getXmlTagValue(xmlText, "status_message");
      const token = getXmlTagValue(xmlText, "ship_rand_num");
      if (message) return { Found: false, Message: message };
      if (!token) return { Found: false, Message: "no token returned" };

      const detailUrl =
        "https://chita-il.com/RunCom.Server/Request.aspx?APPNAME=run&PRGNAME=ship_locate_random&ARGUMENTS=-A" +
        encodeURIComponent(token);

      const html = await fetchText(detailUrl, {
        headers: { "Accept": "text/html,*/*" }
      });

      const parsed = parseRunComDetail(html);
      if (!parsed.Events.length) {
        return { Found: false, Message: "no events (possibly not found)" };
      }

      return { Found: true, InternalNum: parsed.InternalNum, Events: parsed.Events };
    }

    function findEventArray(node, bestRef) {
      if (Array.isArray(node)) {
        const objs = node.filter((x) => x && typeof x === "object" && !Array.isArray(x));
        if (objs.length > 0 && objs.length >= bestRef.current.length) {
          bestRef.current = objs;
        }
        for (const item of node) {
          findEventArray(item, bestRef);
        }
      } else if (node && typeof node === "object") {
        for (const key of Object.keys(node)) {
          findEventArray(node[key], bestRef);
        }
      }
    }

    function formatFlat(obj) {
      const parts = [];
      for (const [k, v] of Object.entries(obj || {})) {
        if (v !== null && v !== undefined && typeof v !== "object") {
          const s = String(v).trim();
          if (s && s !== "null") parts.push(`${k}=${s}`);
        }
      }
      return parts.join("  |  ");
    }

    function formatPostEvent(e) {
      const date = String(e?.StatusDate ?? "").trim();
      const cat = String(e?.CategoryName ?? "").trim();
      const st = String(e?.Status ?? "").trim();
      if (date || st) {
        return `${date}  |  ${cat}  |  ${st}`;
      }
      return formatFlat(e);
    }

    async function trackIsraelPost(item) {
      const url = `https://apimftprd.israelpost.co.il/MyPost-itemtrace/items/${encodeURIComponent(item)}/heb`;
      const rawJson = await fetchText(url, {
        headers: {
          "Accept": "application/json, text/plain, */*",
          "Ocp-Apim-Subscription-Key": IPOST_KEY
        }
      });

      if (!rawJson || !rawJson.trim()) {
        return { Found: false, Events: [], Raw: "(empty response from server/proxy)" };
      }

      let obj;
      try {
        obj = JSON.parse(rawJson);
      } catch {
        return { Found: false, Events: [], Raw: rawJson };
      }

      const bestRef = { current: [] };
      findEventArray(obj, bestRef);
      const events = bestRef.current;

      return {
        Found: events.length > 0,
        Events: events,
        Raw: rawJson
      };
    }

    function showRunComResult(carrier, num, res) {
      if (!res.Found) {
        lblStatus.textContent = "";
        writeOut("Not found: " + res.Message);
        return;
      }
      lblStatus.textContent = `${carrier} - found (internal: ${res.InternalNum})`;
      writeOut(`${carrier} - ${num}    internal: ${res.InternalNum}`);
      writeOut("-".repeat(80));
      for (const e of res.Events) {
        writeOut(`${e.Date}  ${e.Time}   ${e.Status}`);
      }
    }

    form.addEventListener("submit", async (ev) => {
      ev.preventDefault();
      const num = normalizeNum(txtNum.value);
      const phone = normalizePhone(txtPhone.value);
      clearOut();

      if (!num) {
        writeOut("Enter a tracking number.");
        return;
      }

      const carrier = detectCarrier(num);
      if (!carrier) {
        lblStatus.textContent = "";
        const seen = num.length >= 2 ? num.slice(0, 2) : num;
        writeOut(`Carrier not recognized from prefix '${seen}' (expected ED / AE / RS).`);
        return;
      }

      if ((carrier === "HFD" || carrier === "Chita") && !phone) {
        lblStatus.textContent = "";
        writeOut(`Detected ${carrier} - a phone number is required.`);
        return;
      }

      btnTrack.disabled = true;
      lblStatus.textContent = `Searching... (${carrier})`;

      try {
        if (carrier === "Post") {
          const res = await trackIsraelPost(num);
          lblStatus.textContent = "";
          if (!res.Found) {
            writeOut("No updates. Raw JSON:");
            writeOut("-".repeat(80));
            writeOut(res.Raw);
          } else {
            const latest = String(res.Events[0]?.CategoryName ?? "").trim();
            if (latest) lblStatus.textContent = `Israel Post - ${latest}`;
            writeOut(`Israel Post - ${num}`);
            writeOut("Date  |  Status  |  Detail");
            writeOut("-".repeat(80));
            for (const e of res.Events) {
              writeOut(formatPostEvent(e));
            }
          }
        } else if (carrier === "Chita") {
          showRunComResult("Chita", num, await trackChita(num, phone));
        } else if (carrier === "HFD") {
          showRunComResult("HFD", num, await trackHfd(num, phone));
        }
      } catch (err) {
        lblStatus.textContent = "";
        const msg = err && err.message ? err.message : String(err);
        writeOut("Error: " + msg);
        if (msg.includes("Failed to fetch") || msg.includes("NetworkError")) {
          writeOut("");
          writeOut("Tip: Verify your proxy is running and reachable at the prefix URL above.");
        }
      } finally {
        btnTrack.disabled = false;
      }
    });
  </script>
</body>
</html>
__HTML_END__
#>