<#
.SYNOPSIS
    Retrieve the TLS/SSL certificate chain from a remote host and port.

.PARAMETER TargetHost
    The hostname (or IP) of the server.

.PARAMETER Port
    The port to connect to (default 443).

.PARAMETER OutputDir
    Directory to store certificate files (default: current directory).

.PARAMETER Proxy
    Route the connection through an HTTP proxy (e.g., http://proxy:8080 or proxy:8080).

.EXAMPLE
    PS> .\Get-Cert-Chain.ps1 -TargetHost example.com

.EXAMPLE
    PS> .\Get-Cert-Chain.ps1 -TargetHost example.com -OutputDir "C:\certs"

.EXAMPLE
    PS> .\Get-Cert-Chain.ps1 -TargetHost example.com -Proxy http://proxy:8080
#>

param (
    [Parameter(Mandatory = $true)]
    [string]$TargetHost,

    [int]$Port = 443,

    [string]$OutputDir = ".",

    [string]$Proxy
)

# BlueCoat Cloud Services Root CA
$ROOT_CA_CERT = @"
-----BEGIN CERTIFICATE-----
MIIDkjCCAnqgAwIBAgIQYh7PD8WR0TDUDVENFkFmfDANBgkqhkiG9w0BAQsFADBP
MQswCQYDVQQGEwJVUzEfMB0GA1UEChMWQmx1ZUNvYXQgU3lzdGVtcywgSW5jLjEf
MB0GA1UEAxMWQ2xvdWQgU2VydmljZXMgUm9vdCBDQTAeFw0xMTA5MDYwMDAwMDBa
Fw0zNjA5MDUyMzU5NTlaME8xCzAJBgNVBAYTAlVTMR8wHQYDVQQKExZCbHVlQ29h
dCBTeXN0ZW1zLCBJbmMuMR8wHQYDVQQDExZDbG91ZCBTZXJ2aWNlcyBSb290IENB
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAxAB79qIpN0NApUS0be0N
FYDqnY3g9jJsYZ6HVRsbw2eJnO2BKYhoBOW5fmUc9FaT0VbhIokHFRj4w3c2keWV
gTlFHbp6EZaaK1H8yczTf57WlXILuCrJ9eGYsWE2doJePnFpT1QejDRQYMKTjAfQ
A0twCBSxxmZ5TzEJ/xAu4cYTc3CnMrgA3n+/tcH7Yn5PDNGAiwZMWf5OPbktH33b
2r7yex+bgXXivY1Mw6k82RYLTLRsa8AoluBDTplqMbHo1QE7AuveeFkLL5GXX/8U
xao0mBvud2NJCHTZ9EcyHn5/Y2gnqJW4tmbMNXrrhAE+5Y1dWMAU8QFSF0aszQQE
2wIDAQABo2owaDAOBgNVHQ8BAf8EBAMCAQYwDwYDVR0TAQH/BAUwAwEB/zAmBgNV
HREEHzAdpBswGTEXMBUGA1UEAxMOTVBLSS0yMDQ4LTEtOTkwHQYDVR0OBBYEFKZK
F9G8WLV3JRaSK9JMlSPPKBQ2MA0GCSqGSIb3DQEBCwUAA4IBAQCJszHQDBq6Flgo
NRcgmgfn8LvyT1kWmBvM5UdZbPJwquKt4eqz67lXKzEnIUcWwdnJnkt0gmzXLw0z
N5jwISiDbV5iGuJp6x+ftwwvHf9WxqM/aF9xQ9V5767GP4HCz0XfVcx0A1h+nJnh
2suSISN6rPFhIhC5r/hbmBzzs/mjj60wFACDoP13Q2U3D+Jwm3Gf+LjQNHfLfPcB
rJx9hKP8MJEDYPjHyLZTPd9keF3YfG5JevANWIK+4gzgbeVaLEV9/yXWRNEYxYhC
y1nLwUcano2K8mgWkbUHctv7xw/SGymDCIrDnkHBrHqQ59YEfXWBZlLR0gyY56S1
X7G8bD+o
-----END CERTIFICATE-----
"@

# Main script logic

if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

Write-Host "Getting certificate chain from ${TargetHost}:${Port} ..." -ForegroundColor Cyan
if ($Proxy) { Write-Host "Using proxy: $Proxy" -ForegroundColor DarkCyan }
Write-Host "Saving certificates to: $OutputDir" -ForegroundColor DarkCyan
Write-Host ""

# Script-scope variable to capture certs from the callback
$script:capturedCerts = @()

try {
    if ($Proxy) {
        if ($Proxy -notmatch '^https?://') { $Proxy = "http://$Proxy" }
        $proxyUri = [System.Uri]::new($Proxy)
        $tcp = New-Object System.Net.Sockets.TcpClient
        $tcp.Connect($proxyUri.Host, $proxyUri.Port)
        $proxyStream = $tcp.GetStream()
        $connectRequest = [System.Text.Encoding]::ASCII.GetBytes("CONNECT ${TargetHost}:${Port} HTTP/1.1`r`nHost: ${TargetHost}:${Port}`r`n`r`n")
        $proxyStream.Write($connectRequest, 0, $connectRequest.Length)
        $buffer = New-Object byte[] 4096
        $bytesRead = $proxyStream.Read($buffer, 0, $buffer.Length)
        $response = [System.Text.Encoding]::ASCII.GetString($buffer, 0, $bytesRead)
        if ($response -notmatch "200") { throw "Proxy CONNECT failed: $response" }
        $stream = $proxyStream
    } else {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $tcp.Connect($TargetHost, $Port)
        $stream = $tcp.GetStream()
    }

    $certCallback = {
        param($sender, $cert, $chain, $sslPolicyErrors)
        foreach ($element in $chain.ChainElements) {
            $script:capturedCerts += New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($element.Certificate)
        }
        return $true
    }

    $sslStream = New-Object System.Net.Security.SslStream($stream, $false, $certCallback)
    $sslStream.AuthenticateAsClient($TargetHost)
    $sslStream.Close()
    $tcp.Close()
}
catch {
    Write-Error "Failed to retrieve certificate chain from ${TargetHost}:${Port} - $_"
    exit 1
}

if ($script:capturedCerts.Count -eq 0) {
    Write-Error "No certificates captured from chain."
    exit 1
}

Write-Host "Captured $($script:capturedCerts.Count) certificates from chain" -ForegroundColor Cyan
Write-Host ""

# Export all certificates in the chain
$certFiles = @()
$certNum = 1

foreach ($cert in $script:capturedCerts) {
    $certFile = Join-Path $OutputDir "${TargetHost}_${certNum}.pem"
    $pemCert = "-----BEGIN CERTIFICATE-----`r`n"
    $pemCert += [Convert]::ToBase64String($cert.RawData, [System.Base64FormattingOptions]::InsertLineBreaks)
    $pemCert += "`r`n-----END CERTIFICATE-----`r`n"
    Set-Content -Path $certFile -Value $pemCert -Encoding ASCII

    $certType = if ($certNum -eq 1) { "End/Leaf" } elseif ($cert.Subject -eq $cert.Issuer) { "Root CA" } else { "Intermediate CA" }
    Write-Host "Certificate $($certNum) [$certType]:" -ForegroundColor Green
    Write-Host "  Subject : $($cert.Subject)"
    Write-Host "  Issuer  : $($cert.Issuer)"
    Write-Host "  Valid   : $($cert.NotBefore) - $($cert.NotAfter)"
    Write-Host "  File    : $certFile"
    Write-Host ""

    $certFiles += $certFile
    $certNum++
}

# Create combined CA bundle
$caBundlePath = Join-Path $OutputDir "${TargetHost}_ca_chain.pem"
$certFiles | ForEach-Object { Get-Content $_ } | Set-Content -Path $caBundlePath -Encoding ASCII

# Check if chain is incomplete and append root CA
$lastCert = $script:capturedCerts[$script:capturedCerts.Count - 1]
if ($lastCert.Subject -ne $lastCert.Issuer) {
    Write-Host "Chain is incomplete (last cert is not self-signed), appending BlueCoat Root CA" -ForegroundColor Yellow
    Add-Content -Path $caBundlePath -Value $ROOT_CA_CERT -Encoding ASCII
} else {
    Write-Host "Chain is complete (last cert is self-signed)" -ForegroundColor Green
}

Write-Host ""
Write-Host "CA chain bundle saved to: $caBundlePath" -ForegroundColor Cyan
