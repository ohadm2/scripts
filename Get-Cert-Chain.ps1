<#
.SYNOPSIS
    Retrieve the TLS/SSL certificate chain from a remote host and port.

.PARAMETER TargetHost
    The hostname (or IP) of the server.

.PARAMETER Port
    The port to connect to (default 443).

.PARAMETER OutputDir
    Directory to store certificate files (default: current directory).

.EXAMPLE
    PS> .\Get-Cert-Chain.ps1 -TargetHost example.com

.EXAMPLE
    PS> .\Get-Cert-Chain.ps1 -TargetHost example.com -OutputDir "C:\certs"
#>

param (
    [Parameter(Mandatory = $true)]
    [string]$TargetHost,

    [int]$Port = 443,

    [string]$OutputDir = "."
)

function Get-RemoteCertChain {
    param(
        [string]$Hostname,
        [int]$PortNumber
    )

    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $tcp.Connect($Hostname, $PortNumber)
        $stream = $tcp.GetStream()

        $sslStream = New-Object System.Net.Security.SslStream($stream, $false, (
            { param($sender, $cert, $chain, $sslPolicyErrors) $true }
        ))

        $sslStream.AuthenticateAsClient($Hostname)

        $remoteCert = $sslStream.RemoteCertificate
        $chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain

        $null = $chain.Build($remoteCert)  # Prevents $true from leaking

        $certs = @()
        foreach ($element in $chain.ChainElements) {
            if ($element.Certificate -is [System.Security.Cryptography.X509Certificates.X509Certificate2]) {
                $certs += $element.Certificate
            }
        }

        $sslStream.Close()
        $tcp.Close()

        return $certs  # Explicitly return only certs

    } catch {
        Write-Error "Failed to retrieve certificate chain from ${Hostname}:${PortNumber} — $_"
        return $null
    }
}

function Export-CertToFile {
    param(
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$Cert,
        [string]$FileName
    )

    $pem = "-----BEGIN CERTIFICATE-----`n"
    $base64 = [System.Convert]::ToBase64String($Cert.RawData, 'InsertLineBreaks')
    $pem += $base64 + "`n-----END CERTIFICATE-----`n"

    $pem | Out-File -FilePath $FileName -Encoding ascii
}

function Print-CertInfo {
    param (
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$Cert,
        [int]$Index
    )

    $subject = $Cert.Subject
    $issuer = $Cert.Issuer
    $validFrom = $Cert.NotBefore
    $validTo = $Cert.NotAfter

    Write-Host "Certificate #$Index"
    Write-Host "  Subject     : $subject"
    Write-Host "  Issuer      : $issuer"
    Write-Host "  Valid From  : $validFrom"
    Write-Host "  Valid Until : $validTo"
    Write-Host "  Thumbprint  : $($Cert.Thumbprint)"
    Write-Host ""
}

# Main script logic

# Ensure output directory exists
if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

Write-Host "Getting certificate chain from ${TargetHost}:${Port} ..." -ForegroundColor Cyan
Write-Host "Saving certificates to: $OutputDir" -ForegroundColor DarkCyan

$certs = Get-RemoteCertChain -Hostname $TargetHost -PortNumber $Port

if (-not $certs) {
    Write-Error "No certificates retrieved."
    exit 1
}

$i = 0
foreach ($cert in $certs) {
    Print-CertInfo -Cert $cert -Index $i

    $filePath = Join-Path -Path $OutputDir -ChildPath "${TargetHost}-$i.crt"
    Export-CertToFile -Cert $cert -FileName $filePath

    Write-Host "Saved certificate #$i to $filePath" -ForegroundColor Green
    Write-Host
    
    $i++
}

