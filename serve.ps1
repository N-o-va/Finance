$port = 3000
$root = $PSScriptRoot
$ProgressPreference = 'SilentlyContinue'

$script:yfSession = $null
$script:yfCrumb   = $null

function Initialize-YFSession {
    try {
        $sess = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
        $sess.UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
        $hdrs = @{ Accept = 'text/plain'; 'Accept-Language' = 'en-US,en;q=0.9' }
        $r = Invoke-WebRequest -Uri 'https://query2.finance.yahoo.com/v1/test/getcrumb' -WebSession $sess -UseBasicParsing -Headers $hdrs
        $script:yfSession = $sess
        $script:yfCrumb   = $r.Content.Trim()
        Write-Output "[YF] Session OK crumb=$($script:yfCrumb)"
        return $true
    } catch {
        Write-Warning "[YF] Session init failed: $_"
        return $false
    }
}

function Get-YahooChart {
    param($Ticker, $Range, $Interval = '1d')
    $crumbQ = ''
    if ($script:yfCrumb) {
        $crumbQ = '&crumb=' + [Uri]::EscapeDataString($script:yfCrumb)
    }
    $url = 'https://query1.finance.yahoo.com/v8/finance/chart/' + $Ticker + '?interval=' + $Interval + '&range=' + $Range + '&includePrePost=false' + $crumbQ
    try {
        $hdrs = @{
            Accept            = 'application/json, text/plain, */*'
            'Accept-Language' = 'en-US,en;q=0.9'
            Referer           = 'https://finance.yahoo.com/'
        }
        if ($script:yfSession) {
            $r = Invoke-WebRequest -Uri $url -WebSession $script:yfSession -UseBasicParsing -Headers $hdrs
        } else {
            $r = Invoke-WebRequest -Uri $url -UseBasicParsing -Headers $hdrs
        }
        return $r.Content
    } catch {
        $code = 0
        if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
        if ($code -eq 401) {
            Write-Warning "[YF] 401 for $Ticker - reinit..."
            Initialize-YFSession | Out-Null
        } else {
            Write-Warning "[YF] $Ticker HTTP $code : $($_.Exception.Message)"
        }
        return $null
    }
}

Initialize-YFSession | Out-Null

$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add('http://localhost:' + $port + '/')
$listener.Start()
Write-Output ('Serving on http://localhost:' + $port)

while ($listener.IsListening) {
    $ctx = $listener.GetContext()
    $req = $ctx.Request
    $res = $ctx.Response
    $res.Headers.Add('Access-Control-Allow-Origin', '*')
    $res.Headers.Add('Access-Control-Allow-Methods', 'GET, OPTIONS')

    if ($req.HttpMethod -eq 'OPTIONS') {
        $res.StatusCode = 204
        $res.Close()
        continue
    }

    $path = $req.Url.LocalPath

    if ($path -eq '/api/finance') {
        $qs = $req.Url.Query.TrimStart('?')
        $qp = @{}
        foreach ($pair in ($qs -split '&')) {
            $kv = $pair -split '=', 2
            if ($kv.Count -eq 2) { $qp[$kv[0]] = [Uri]::UnescapeDataString($kv[1]) }
        }
        $tickers  = @($qp['tickers'] -split ',' | Where-Object { $_ -match '^\w{1,6}$' })
        $range    = if ($qp.ContainsKey('range'))    { $qp['range']    } else { '1d' }
        $interval = if ($qp.ContainsKey('interval')) { $qp['interval'] } else { '1d' }

        $sb    = [System.Text.StringBuilder]::new()
        $sb.Append('{') | Out-Null
        $first = $true
        foreach ($t in $tickers) {
            if (-not $first) { $sb.Append(',') | Out-Null }
            $first = $false
            $sb.Append('"' + $t + '":') | Out-Null
            $json = Get-YahooChart -Ticker $t -Range $range -Interval $interval
            if ($json) { $sb.Append($json) | Out-Null } else { $sb.Append('null') | Out-Null }
        }
        $sb.Append('}') | Out-Null

        $bytes = [System.Text.Encoding]::UTF8.GetBytes($sb.ToString())
        $res.ContentType     = 'application/json; charset=utf-8'
        $res.ContentLength64 = $bytes.Length
        $res.OutputStream.Write($bytes, 0, $bytes.Length)
        $res.Close()
        continue
    }

    $rel  = $path.TrimStart('/')
    if ($rel -eq '') { $rel = 'index.html' }
    $file = Join-Path $root $rel

    if (Test-Path $file -PathType Leaf) {
        $ext  = [System.IO.Path]::GetExtension($file).ToLower()
        $mime = switch ($ext) {
            '.html' { 'text/html; charset=utf-8' }
            '.css'  { 'text/css' }
            '.js'   { 'application/javascript' }
            '.png'  { 'image/png' }
            '.ico'  { 'image/x-icon' }
            default { 'application/octet-stream' }
        }
        $bytes = [System.IO.File]::ReadAllBytes($file)
        $res.ContentType     = $mime
        $res.ContentLength64 = $bytes.Length
        $res.OutputStream.Write($bytes, 0, $bytes.Length)
    } else {
        $res.StatusCode = 404
    }
    $res.Close()
}
