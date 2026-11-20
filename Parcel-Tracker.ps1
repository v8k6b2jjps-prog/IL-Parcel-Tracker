<#
    Parcel Tracker  —  WinForms GUI. Auto-detects the carrier from the number prefix.

      ED… -> HFD          (RunCom: number + phone)
      AE… -> Chita        (RunCom: number + phone)
      RS… -> Israel Post  (MyPost JSON: number only)

    Run:  right-click > Run with PowerShell
          or:  powershell -ExecutionPolicy Bypass -File .\HFD-Tracker.ps1
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/158.0.0.0 Safari/537.36'
$IPOST_KEY = '5ccb5b137e7444d885be752eda7f767a'   # public subscription key from doar.israelpost.co.il

# ---------------- shared helpers ----------------
function Decode-Html([byte[]]$bytes) {
    $u = [Text.Encoding]::UTF8.GetString($bytes)
    if ($u.IndexOf([char]0xFFFD) -ge 0) {
        try { [Text.Encoding]::RegisterProvider([Text.CodePagesEncodingProvider]::Instance) } catch {}
        return [Text.Encoding]::GetEncoding(1255).GetString($bytes)
    }
    return $u
}

function Get-XmlVal([xml]$doc, [string]$name) {
    $n = $doc.SelectSingleNode("//*[local-name()='$name']")
    if ($n) { $n.InnerText.Trim() } else { '' }
}

function Parse-RunComDetail([string]$html) {
    $internal = if ($html -match ':\s*([0-9]{4,})\s*</span>') { $matches[1] } else { '' }
    $events = @(foreach ($m in [regex]::Matches($html, '(?s)<tr>\s*<td>([^<]*?)</td>\s*<td>([^<]*?)</td>\s*<td>(.*?)</td>\s*</tr>')) {
        $desc = ($m.Groups[3].Value -replace '<[^>]+>', ' ').Trim()
        $desc = ([System.Net.WebUtility]::HtmlDecode($desc)) -replace '\s{2,}', ' '
        [pscustomobject]@{ Date = $m.Groups[1].Value.Trim(); Time = $m.Groups[2].Value.Trim(); Status = $desc }
    })
    @{ InternalNum = $internal; Events = $events }
}

# Keep only ASCII letters/digits (drops spaces, RTL/LRM marks, paste artifacts), then upper-case.
function Normalize-Num([string]$num) { ([regex]::Replace($num, '[^A-Za-z0-9]', '')).ToUpper() }

function Detect-Carrier([string]$num) {
    $n = Normalize-Num $num
    if ($n -like 'ED*') { return 'HFD' }
    if ($n -like 'AE*') { return 'Chita' }
    if ($n -like 'SN*') { return 'GCX' }
    if ($n -like 'RS*') { return 'Post' }
    if ($n -match '^[A-Z]{2}\d{6,}[A-Z]?$') { return 'Post' }   # S10-style international mail
    return $null
}

# ---------------- HFD (api.hfd.co.il wrapper for step 1) ----------------
function Invoke-HfdTrack([string]$num, [string]$phone) {
    $h = @{ 'User-Agent' = $UA; 'Accept' = '*/*'; 'Referer' = 'https://run.hfd.co.il/run_public/pub_random_form.htm' }
    $api = 'https://api.hfd.co.il/rest/v3/api/ship-locate-num-and-phone?num=' +
           [uri]::EscapeDataString($num) + '&phone=' + [uri]::EscapeDataString($phone)
    $r1 = Invoke-WebRequest -Uri $api -Headers $h -UseBasicParsing -ErrorAction Stop

    $doc = New-Object System.Xml.XmlDocument
    $doc.Load((New-Object System.IO.MemoryStream (,$r1.RawContentStream.ToArray())))
    $message = Get-XmlVal $doc 'status_message'
    $token   = Get-XmlVal $doc 'ship_rand_num'
    if ($message)   { return @{ Found = $false; Message = $message } }
    if (-not $token){ return @{ Found = $false; Message = 'no token returned' } }

    $detailUrl = 'https://run.hfd.co.il/runcom.server/request.aspx?APPNAME=run&PRGNAME=ship_locate_random&ARGUMENTS=-A' + $token
    $r2  = Invoke-WebRequest -Uri $detailUrl -Headers $h -UseBasicParsing -ErrorAction Stop
    $p   = Parse-RunComDetail (Decode-Html $r2.RawContentStream.ToArray())
    if (@($p.Events).Count -eq 0) { return @{ Found = $false; Message = 'no events (possibly not found)' } }
    return @{ Found = $true; InternalNum = $p.InternalNum; Events = $p.Events }
}

# ---------------- Chita (direct RunCom, same system as HFD) ----------------
function Invoke-ChitaTrack([string]$num, [string]$phone) {
    $h = @{ 'User-Agent' = $UA; 'Accept' = 'application/xml, text/xml, */*; q=0.01';
            'X-Requested-With' = 'XMLHttpRequest'; 'Referer' = 'https://chita-il.com/run_public1/' }

    $step1 = 'https://chita-il.com/RunCom.Server/Request.aspx?APPNAME=RUN&PRGNAME=ship_locate_num_and_phone&ARGUMENTS=-N' +
             [uri]::EscapeDataString($num) + ',-A' + [uri]::EscapeDataString($phone)
    $r1 = Invoke-WebRequest -Uri $step1 -Headers $h -UseBasicParsing -ErrorAction Stop

    $doc = New-Object System.Xml.XmlDocument
    $doc.Load((New-Object System.IO.MemoryStream (,$r1.RawContentStream.ToArray())))
    $message = Get-XmlVal $doc 'status_message'
    $token   = Get-XmlVal $doc 'ship_rand_num'
    if ($message)   { return @{ Found = $false; Message = $message } }
    if (-not $token){ return @{ Found = $false; Message = 'no token returned' } }

    $detailUrl = 'https://chita-il.com/RunCom.Server/Request.aspx?APPNAME=run&PRGNAME=ship_locate_random&ARGUMENTS=-A' + $token
    $r2  = Invoke-WebRequest -Uri $detailUrl -Headers @{ 'User-Agent' = $UA; 'Accept' = 'text/html,*/*'; 'Referer' = 'https://chita-il.com/run_public1/' } -UseBasicParsing -ErrorAction Stop
    $p   = Parse-RunComDetail (Decode-Html $r2.RawContentStream.ToArray())
    if (@($p.Events).Count -eq 0) { return @{ Found = $false; Message = 'no events (possibly not found)' } }
    return @{ Found = $true; InternalNum = $p.InternalNum; Events = $p.Events }
}

# ---------------- Israel Post ----------------
function Find-EventArray($node, [ref]$best) {
    if ($node -is [System.Array]) {
        $objs = @($node | Where-Object { $_ -is [System.Management.Automation.PSCustomObject] })
        if ($objs.Count -gt 0 -and $objs.Count -ge @($best.Value).Count) { $best.Value = $objs }
        foreach ($it in $node) { Find-EventArray $it $best }
    }
    elseif ($node -is [System.Management.Automation.PSCustomObject]) {
        foreach ($p in $node.PSObject.Properties) { Find-EventArray $p.Value $best }
    }
}

function Format-Flat($obj) {
    $parts = foreach ($p in $obj.PSObject.Properties) {
        $v = $p.Value
        if ($null -ne $v -and $v -isnot [System.Array] -and $v -isnot [System.Management.Automation.PSCustomObject]) {
            $s = ("$v").Trim(); if ($s -and $s -ne 'null') { "$($p.Name)=$s" }
        }
    }
    $parts -join '  |  '
}

function Format-PostEvent($e) {
    $date = ("$($e.StatusDate)").Trim()
    $cat  = ("$($e.CategoryName)").Trim()
    $st   = ("$($e.Status)").Trim()
    if ($date -or $st) { '{0}  |  {1}  |  {2}' -f $date, $cat, $st } else { Format-Flat $e }
}

function Invoke-IsraelPostTrack([string]$item) {
    $url = "https://apimftprd.israelpost.co.il/MyPost-itemtrace/items/$([uri]::EscapeDataString($item))/heb"
    $h = @{ 'User-Agent' = $UA; 'Accept' = 'application/json, text/plain, */*';
            'Origin' = 'https://doar.israelpost.co.il'; 'Ocp-Apim-Subscription-Key' = $IPOST_KEY }
    $r = Invoke-WebRequest -Uri $url -Headers $h -UseBasicParsing -ErrorAction Stop
    $json = [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
    $obj  = $json | ConvertFrom-Json
    $best = [ref]@(); Find-EventArray $obj $best
    $events = @($best.Value)
    return @{ Found = ($events.Count -gt 0); Events = $events; Raw = $json }
}

# ---------------- GCX (info.gcx.co.il — ASP.NET postback: GET tokens, then POST) ----------------
function Get-GcxSpan([string]$html, [string]$id) {
    $m = [regex]::Match($html, '(?s)<span[^>]*id="' + [regex]::Escape($id) + '"[^>]*>(.*?)</span>')
    if (-not $m.Success) { return '' }
    $t = ($m.Groups[1].Value -replace '<[^>]+>', ' ')
    (([System.Net.WebUtility]::HtmlDecode($t)) -replace '\s{2,}', ' ').Trim()
}

function Invoke-GcxTrack([string]$num) {
    $gurl = 'https://info.gcx.co.il/gcx_event/Default.aspx'
    $r1 = Invoke-WebRequest -Uri $gurl -Headers @{ 'User-Agent' = $UA; 'Accept' = 'text/html,*/*' } `
            -SessionVariable gs -UseBasicParsing -TimeoutSec 25 -ErrorAction Stop
    $html1 = $r1.Content

    $pick = {
        param([string]$name)
        $m = [regex]::Match($html1, 'name="' + $name + '"[^>]*?value="([^"]*)"')
        if ($m.Success) { [System.Net.WebUtility]::HtmlDecode($m.Groups[1].Value) } else { '' }
    }
    $vs = & $pick '__VIEWSTATE'
    if (-not $vs) { return @{ Found = $false; Message = 'no __VIEWSTATE (GCX page changed or blocked)' } }

    $body = [ordered]@{
        '__EVENTTARGET'        = ''
        '__EVENTARGUMENT'      = ''
        '__VIEWSTATE'          = $vs
        '__VIEWSTATEGENERATOR' = (& $pick '__VIEWSTATEGENERATOR')
        '__EVENTVALIDATION'    = (& $pick '__EVENTVALIDATION')
        'tbHAWB_NUM'           = $num
        'BtnTrack'             = 'TRACK / עקוב'
    }
    $r2 = Invoke-WebRequest -Uri $gurl -Method POST -Body $body -WebSession $gs `
            -Headers @{ 'User-Agent' = $UA; 'Accept' = 'text/html,*/*'; 'Referer' = $gurl; 'Origin' = 'https://info.gcx.co.il' } `
            -UseBasicParsing -TimeoutSec 25 -ErrorAction Stop
    $html = Decode-Html $r2.RawContentStream.ToArray()

    $idx = @([regex]::Matches($html, 'id="lbEventDescrEng(\d+)"') | ForEach-Object { [int]$_.Groups[1].Value } | Sort-Object -Unique)
    $events = @(foreach ($i in $idx) {
        $eng = Get-GcxSpan $html ('lbEventDescrEng' + $i)
        $heb = Get-GcxSpan $html ('lbEventDescrHeb' + $i)
        $st  = if ($heb) { if ($eng) { "$eng / $heb" } else { $heb } } else { $eng }
        [pscustomobject]@{
            Date   = (Get-GcxSpan $html ('lbEventDate' + $i))
            Time   = (Get-GcxSpan $html ('lbEventTime' + $i))
            Status = $st
        }
    })
    $cur = Get-GcxSpan $html 'LbCurrentStatusEng'
    if (-not $cur -and $events.Count -eq 0) { return @{ Found = $false; Message = 'not found / no data' } }
    $company = Get-GcxSpan $html 'lbDeliveryCompnyName'
    $via = if ($company) { "via $company" } else { '' }
    return @{ Found = $true; InternalNum = $via; Events = $events }
}

# ================= GUI =================
$dark    = [Drawing.Color]::FromArgb(37, 52, 68)
$accent  = [Drawing.Color]::FromArgb(238, 104, 95)
$bg      = [Drawing.Color]::FromArgb(245, 246, 248)
$conBg   = [Drawing.Color]::FromArgb(28, 30, 34)
$conFg   = [Drawing.Color]::FromArgb(222, 226, 230)
$muted   = [Drawing.Color]::FromArgb(130, 138, 148)

$form = New-Object Windows.Forms.Form
$form.Text = 'Parcel Tracker'
$form.ClientSize = New-Object Drawing.Size(700, 560)
$form.FormBorderStyle = 'FixedSingle'   # fixed size
$form.MaximizeBox = $false
$form.StartPosition = 'CenterScreen'
$form.BackColor = $bg
$form.Font = New-Object Drawing.Font('Segoe UI', 10)

# --- header band ---
$header = New-Object Windows.Forms.Panel
$header.Location = New-Object Drawing.Point(0, 0); $header.Size = New-Object Drawing.Size(700, 58)
$header.BackColor = $dark
$title = New-Object Windows.Forms.Label
$title.Text = 'Parcel Tracker'; $title.ForeColor = [Drawing.Color]::White
$title.Font = New-Object Drawing.Font('Segoe UI Semibold', 15, [Drawing.FontStyle]::Bold)
$title.TextAlign = 'MiddleLeft'; $title.Dock = 'Fill'; $title.Padding = New-Object Windows.Forms.Padding(20, 0, 0, 0)
$sub = New-Object Windows.Forms.Label
$sub.Text = 'HFD  /  Israel Post  /  Cheetah  /  GCX'; $sub.ForeColor = $accent
$sub.Font = New-Object Drawing.Font('Segoe UI', 9); $sub.TextAlign = 'MiddleRight'
$sub.Dock = 'Right'; $sub.Width = 240; $sub.Padding = New-Object Windows.Forms.Padding(0, 0, 20, 0)
$header.Controls.AddRange(@($sub, $title))
$accentBar = New-Object Windows.Forms.Panel
$accentBar.Location = New-Object Drawing.Point(0, 58); $accentBar.Size = New-Object Drawing.Size(700, 3); $accentBar.BackColor = $accent

# --- input fields ---
$lblNum = New-Object Windows.Forms.Label
$lblNum.Text = 'Tracking number'; $lblNum.ForeColor = $dark
$lblNum.Location = New-Object Drawing.Point(20, 73); $lblNum.AutoSize = $true
$txtNum = New-Object Windows.Forms.TextBox
$txtNum.Location = New-Object Drawing.Point(20, 100); $txtNum.Size = New-Object Drawing.Size(330, 28)
$txtNum.Font = New-Object Drawing.Font('Segoe UI', 11); $txtNum.BorderStyle = 'FixedSingle'

$lblPhone = New-Object Windows.Forms.Label
$lblPhone.Text = 'Phone  (HFD / Cheetah)'; $lblPhone.ForeColor = $dark
$lblPhone.Location = New-Object Drawing.Point(370, 73); $lblPhone.AutoSize = $true
$txtPhone = New-Object Windows.Forms.TextBox
$txtPhone.Location = New-Object Drawing.Point(370, 100); $txtPhone.Size = New-Object Drawing.Size(310, 28)
$txtPhone.Font = New-Object Drawing.Font('Segoe UI', 11); $txtPhone.BorderStyle = 'FixedSingle'

$lblHint = New-Object Windows.Forms.Label
$lblHint.Text = 'Auto-detect:   ED -> HFD    AE -> Cheetah    SN -> GCX    RS -> Israel Post'
$lblHint.ForeColor = $muted; $lblHint.Location = New-Object Drawing.Point(20, 136); $lblHint.AutoSize = $true

$btn = New-Object Windows.Forms.Button
$btn.Text = 'Track'; $btn.FlatStyle = 'Flat'; $btn.BackColor = $dark; $btn.ForeColor = [Drawing.Color]::White
$btn.FlatAppearance.BorderSize = 0; $btn.FlatAppearance.MouseOverBackColor = $accent
$btn.Font = New-Object Drawing.Font('Segoe UI Semibold', 11, [Drawing.FontStyle]::Bold)
$btn.Location = New-Object Drawing.Point(20, 166); $btn.Size = New-Object Drawing.Size(160, 40)
$btn.Cursor = [Windows.Forms.Cursors]::Hand

$lblStatus = New-Object Windows.Forms.Label
$lblStatus.Location = New-Object Drawing.Point(196, 176); $lblStatus.Size = New-Object Drawing.Size(484, 22)
$lblStatus.ForeColor = $dark; $lblStatus.TextAlign = 'MiddleLeft'

$out = New-Object Windows.Forms.TextBox
$out.Multiline = $true; $out.ReadOnly = $true; $out.ScrollBars = 'Both'; $out.WordWrap = $false
$out.BackColor = $conBg; $out.ForeColor = $conFg; $out.BorderStyle = 'FixedSingle'
$out.Font = New-Object Drawing.Font('Consolas', 10)
$out.Location = New-Object Drawing.Point(20, 222); $out.Size = New-Object Drawing.Size(660, 322)

$form.Controls.AddRange(@($header, $accentBar, $lblNum, $txtNum, $lblPhone, $txtPhone, $lblHint, $btn, $lblStatus, $out))
$form.AcceptButton = $btn

function Write-Out([string]$text) { $out.AppendText($text + "`r`n") }

function Show-RunComResult([string]$carrier, [string]$num, $res) {
    if (-not $res.Found) { $lblStatus.Text = ''; Write-Out ('Not found: ' + $res.Message); return }
    $lblStatus.Text = "$carrier - found (internal: $($res.InternalNum))"
    Write-Out ("$carrier - $num    internal: $($res.InternalNum)")
    Write-Out ('-' * 80)
    foreach ($e in $res.Events) { Write-Out ('{0}  {1}   {2}' -f $e.Date, $e.Time, $e.Status) }
}

$btn.Add_Click({
    $num   = Normalize-Num $txtNum.Text         # strip spaces / hidden chars
    $phone = ($txtPhone.Text -replace '\D', '')  # digits only
    $out.Clear()
    if (-not $num) { Write-Out 'Enter a tracking number.'; return }

    $carrier = Detect-Carrier $num
    if (-not $carrier) {
        $lblStatus.Text = ''
        $seen = if ($num.Length -ge 2) { $num.Substring(0, 2) } else { $num }
        Write-Out "Carrier not recognized from prefix '$seen' (expected ED / AE / SN / RS)."
        return
    }
    if (($carrier -eq 'HFD' -or $carrier -eq 'Chita') -and -not $phone) {
        $lblStatus.Text = ''; Write-Out "Detected $carrier - a phone number is required."; return
    }

    $btn.Enabled = $false; $lblStatus.Text = "Searching... ($carrier)"; [Windows.Forms.Application]::DoEvents()
    try {
        switch ($carrier) {
            'Post' {
                $res = Invoke-IsraelPostTrack $num
                $lblStatus.Text = ''
                if (-not $res.Found) { Write-Out 'No updates. Raw JSON:'; Write-Out ('-' * 80); Write-Out $res.Raw; break }
                $latest = ("$($res.Events[0].CategoryName)").Trim(); if ($latest) { $lblStatus.Text = "Israel Post - $latest" }
                Write-Out ("Israel Post - $num")
                Write-Out ('Date  |  Status  |  Detail'); Write-Out ('-' * 80)
                foreach ($e in $res.Events) { Write-Out (Format-PostEvent $e) }
            }
            'Chita' { Show-RunComResult 'Chita' $num (Invoke-ChitaTrack $num $phone) }
            'HFD'   { Show-RunComResult 'HFD'   $num (Invoke-HfdTrack  $num $phone) }
            'GCX'   {
                $res = Invoke-GcxTrack $num
                $lblStatus.Text = ''
                if (-not $res.Found) { Write-Out ('Not found: ' + $res.Message); break }
                $lblStatus.Text = "GCX - found  $($res.InternalNum)"
                Write-Out ("GCX - $num    $($res.InternalNum)")
                Write-Out ('-' * 80)
                foreach ($e in $res.Events) { Write-Out ('{0}  {1}   {2}' -f $e.Date, $e.Time, $e.Status) }
            }
        }
    }
    catch { $lblStatus.Text = ''; Write-Out ('Error: ' + $_.Exception.Message) }
    finally { $btn.Enabled = $true }
})

[void]$form.ShowDialog()
