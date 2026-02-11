#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Unified CA Chain Installer for Windows
    
.DESCRIPTION
    Downloads CA certificate chain from a domain and installs it system-wide for all common development tools.
    
.PARAMETER Domain
    Domain to fetch certificates from (default: google.com). Do NOT include http:// or https://
    
.PARAMETER Port
    Port to connect to (default: 443)
    
.PARAMETER CertsDir
    Directory to store certificates (default: $env:TEMP\ca-certs)
    
.PARAMETER SkipSystem
    Skip Windows certificate store installation
    
.PARAMETER SkipPython
    Skip Python certifi installation
    
.PARAMETER SkipRuby
    Skip Ruby installation
    
.PARAMETER SkipNode
    Skip Node.js installation
    
.PARAMETER SkipJava
    Skip Java cacerts installation
    
.PARAMETER SkipPHP
    Skip PHP installation
    
.PARAMETER SkipGit
    Skip Git configuration
    
.PARAMETER SkipGcloud
    Skip Google Cloud SDK installation
    
.PARAMETER SkipAWS
    Skip AWS CLI installation
    
.PARAMETER SkipComposer
    Skip Composer installation
    
.PARAMETER SkipCurl
    Skip curl configuration
    
.EXAMPLE
    .\Install-CAChain.ps1
    
.EXAMPLE
    .\Install-CAChain.ps1 -Domain gitlab.example.com
    
.EXAMPLE
    .\Install-CAChain.ps1 -Domain internal.corp.com -SkipPython -SkipRuby
#>

[CmdletBinding()]
param(
    [Parameter(Position=0)]
    [string]$Domain = "google.com",
    
    [int]$Port = 443,
    
    [string]$CertsDir = "$env:TEMP\ca-certs",
    
    [switch]$SkipSystem,
    [switch]$SkipPython,
    [switch]$SkipRuby,
    [switch]$SkipNode,
    [switch]$SkipJava,
    [switch]$SkipPHP,
    [switch]$SkipGit,
    [switch]$SkipGcloud,
    [switch]$SkipAWS,
    [switch]$SkipComposer,
    [switch]$SkipCurl
)

$ErrorActionPreference = "Stop"
$BackupSuffix = "backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

# Global arrays for detected paths
$script:PythonPaths = @()
$script:RubyPaths = @()
$script:JavaCacerts = @()
$script:PHPCacerts = @()
$script:GcloudPaths = @()
$script:AWSPaths = @()

function Write-Log {
    param([string]$Message)
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message" -ForegroundColor Cyan
}

function Write-ErrorLog {
    param([string]$Message)
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] ERROR: $Message" -ForegroundColor Red
}

function Backup-File {
    param([string]$FilePath)
    
    if (Test-Path $FilePath) {
        $backupPath = "$FilePath.$BackupSuffix"
        Copy-Item -Path $FilePath -Destination $backupPath -Force
        Write-Log "Backed up: $FilePath"
    }
}

function Download-CertChain {
    param(
        [string]$Domain,
        [int]$Port
    )
    
    Write-Log "Downloading certificate chain from ${Domain}:${Port}..."
    
    # Create certs directory
    if (-not (Test-Path $CertsDir)) {
        New-Item -ItemType Directory -Path $CertsDir -Force | Out-Null
    }
    
    # Download certificate chain using .NET
    try {
        $tcpClient = New-Object System.Net.Sockets.TcpClient($Domain, $Port)
        $sslStream = New-Object System.Net.Security.SslStream($tcpClient.GetStream(), $false, {$true})
        $sslStream.AuthenticateAsClient($Domain)
        
        $certChain = $sslStream.RemoteCertificate.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)
        $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList @(,$certChain)
        
        # Get the chain
        $chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain
        $chain.ChainPolicy.RevocationMode = [System.Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
        $chain.ChainPolicy.VerificationFlags = [System.Security.Cryptography.X509Certificates.X509VerificationFlags]::AllFlags
        $buildResult = $chain.Build($cert)
        
        Write-Log "Chain build result: $buildResult, Chain elements: $($chain.ChainElements.Count)"
        
        $sslStream.Close()
        $tcpClient.Close()
        
        # Export certificates (skip the first one - end certificate)
        $certFiles = @()
        $certNum = 1
        
        foreach ($chainElement in $chain.ChainElements) {
            $chainCert = $chainElement.Certificate
            
            # Skip end certificate (first one)
            if ($certNum -eq 1) {
                $certNum++
                continue
            }
            
            $certFile = Join-Path $CertsDir "${Domain}_${certNum}.pem"
            $pemCert = "-----BEGIN CERTIFICATE-----`r`n"
            $pemCert += [Convert]::ToBase64String($chainCert.RawData, [System.Base64FormattingOptions]::InsertLineBreaks)
            $pemCert += "`r`n-----END CERTIFICATE-----`r`n"
            
            Set-Content -Path $certFile -Value $pemCert -Encoding ASCII
            
            Write-Log "Certificate $($certNum): $certFile"
            Write-Log "  Subject: $($chainCert.Subject)"
            Write-Log "  Issuer:  $($chainCert.Issuer)"
            
            $certFiles += $certFile
            $certNum++
        }
        
        if ($certFiles.Count -eq 0) {
            Write-Log "Warning: No CA certificates found in chain. This may be normal for some sites."
            Write-Log "Creating bundle with end certificate only (not recommended for CA trust)."
            
            # Export the end certificate as fallback
            $certFile = Join-Path $CertsDir "${Domain}_1.pem"
            $pemCert = "-----BEGIN CERTIFICATE-----`r`n"
            $pemCert += [Convert]::ToBase64String($cert.RawData, [System.Base64FormattingOptions]::InsertLineBreaks)
            $pemCert += "`r`n-----END CERTIFICATE-----`r`n"
            Set-Content -Path $certFile -Value $pemCert -Encoding ASCII
            $certFiles += $certFile
        }
        
        # Create combined CA bundle
        $caBundlePath = Join-Path $CertsDir "${Domain}_ca_chain.pem"
        $certFiles | ForEach-Object { Get-Content $_ } | Set-Content -Path $caBundlePath -Encoding ASCII
        
        Write-Log "Created CA chain bundle: $caBundlePath"
        
        return $caBundlePath
        
    } catch {
        Write-ErrorLog "Failed to download certificates: $_"
        throw
    }
}

function Detect-PythonCertifi {
    Write-Log "Detecting Python certifi locations..."
    
    $pythonCommands = @("python", "python3", "python2")
    
    foreach ($pythonCmd in $pythonCommands) {
        try {
            $pythonExe = Get-Command $pythonCmd -ErrorAction SilentlyContinue
            if ($pythonExe) {
                # Check certifi
                $certifiPath = & $pythonCmd -c "import certifi; print(certifi.where())" 2>$null
                if ($certifiPath -and (Test-Path $certifiPath)) {
                    $script:PythonPaths += $certifiPath
                    Write-Log "Found Python certifi: $certifiPath ($pythonCmd)"
                }
                
                # Check pip vendor certifi
                $pipCertifi = & $pythonCmd -c "import pip._vendor.certifi as c; print(c.where())" 2>$null
                if ($pipCertifi -and (Test-Path $pipCertifi) -and ($pipCertifi -ne $certifiPath)) {
                    $script:PythonPaths += $pipCertifi
                    Write-Log "Found pip certifi: $pipCertifi ($pythonCmd)"
                }
            }
        } catch {
            # Silently continue
        }
    }
}

function Detect-RubyCerts {
    Write-Log "Detecting Ruby SSL cert locations..."
    
    try {
        $rubyExe = Get-Command ruby -ErrorAction SilentlyContinue
        if ($rubyExe) {
            $rubyCertFile = & ruby -ropenssl -e "p OpenSSL::X509::DEFAULT_CERT_FILE" 2>$null
            $rubyCertFile = $rubyCertFile -replace '"', ''
            
            if ($rubyCertFile -and (Test-Path $rubyCertFile)) {
                $script:RubyPaths += $rubyCertFile
                Write-Log "Found Ruby cert file: $rubyCertFile"
            }
            
            # Check gem SSL certs directory
            $rubyVersion = & ruby -e "print RUBY_VERSION" 2>$null
            if ($rubyVersion) {
                $rubyBase = Split-Path (Split-Path $rubyExe.Source)
                $gemSslDir = Join-Path $rubyBase "lib\ruby\$rubyVersion\rubygems\ssl_certs"
                if (Test-Path $gemSslDir) {
                    $script:RubyPaths += $gemSslDir
                    Write-Log "Found Ruby gem SSL dir: $gemSslDir"
                }
            }
        }
    } catch {
        # Silently continue
    }
}

function Detect-JavaCacerts {
    Write-Log "Detecting Java cacerts..."
    
    try {
        $javaExe = Get-Command java -ErrorAction SilentlyContinue
        if ($javaExe) {
            $javaHome = [System.Environment]::GetEnvironmentVariable("JAVA_HOME", "Machine")
            if (-not $javaHome) {
                $javaHome = Split-Path (Split-Path $javaExe.Source)
            }
            
            $cacertsPath = Join-Path $javaHome "lib\security\cacerts"
            if (Test-Path $cacertsPath) {
                $script:JavaCacerts += $cacertsPath
                Write-Log "Found Java cacerts: $cacertsPath"
            }
        }
    } catch {
        # Silently continue
    }
}

function Detect-PHPCacerts {
    Write-Log "Detecting PHP cacert locations..."
    
    try {
        $phpExe = Get-Command php -ErrorAction SilentlyContinue
        if ($phpExe) {
            $phpIni = & php -i 2>$null | Select-String "Loaded Configuration File" | ForEach-Object { ($_ -split "=>")[1].Trim() }
            
            if ($phpIni -and (Test-Path $phpIni)) {
                Write-Log "Found PHP ini: $phpIni"
                
                # Check for openssl.cafile
                $cafile = & php -i 2>$null | Select-String "openssl.cafile" | ForEach-Object { ($_ -split "=>")[1].Trim() }
                if ($cafile -and ($cafile -ne "no value") -and (Test-Path $cafile)) {
                    $script:PHPCacerts += $cafile
                    Write-Log "Found PHP openssl.cafile: $cafile"
                }
            }
        }
    } catch {
        # Silently continue
    }
}

function Detect-GcloudCerts {
    Write-Log "Detecting Google Cloud SDK cert locations..."
    
    try {
        $gcloudExe = Get-Command gcloud -ErrorAction SilentlyContinue
        if ($gcloudExe) {
            $gcloudRoot = & gcloud info --format="value(installation.sdk_root)" 2>$null
            
            if ($gcloudRoot -and (Test-Path $gcloudRoot)) {
                $certPaths = @(
                    "$gcloudRoot\lib\third_party\certifi\cacert.pem",
                    "$gcloudRoot\lib\third_party\botocore\cacert.pem",
                    "$gcloudRoot\lib\third_party\requests\cacert.pem"
                )
                
                foreach ($path in $certPaths) {
                    if (Test-Path $path) {
                        $script:GcloudPaths += $path
                        Write-Log "Found gcloud cert: $path"
                    }
                }
            }
        }
    } catch {
        # Silently continue
    }
}

function Detect-AWSCerts {
    Write-Log "Detecting AWS CLI cert locations..."
    
    try {
        $awsExe = Get-Command aws -ErrorAction SilentlyContinue
        if ($awsExe) {
            # Check common AWS CLI installation paths
            $awsPaths = @(
                "$env:ProgramFiles\Amazon\AWSCLIV2\awscli\botocore\cacert.pem",
                "$env:LOCALAPPDATA\Programs\Python\*\Lib\site-packages\botocore\cacert.pem"
            )
            
            foreach ($path in $awsPaths) {
                $resolvedPaths = Resolve-Path $path -ErrorAction SilentlyContinue
                if ($resolvedPaths) {
                    foreach ($resolved in $resolvedPaths) {
                        $script:AWSPaths += $resolved.Path
                        Write-Log "Found AWS CLI cert: $($resolved.Path)"
                    }
                }
            }
        }
    } catch {
        # Silently continue
    }
}

function Install-SystemCA {
    param([string]$CABundle)
    
    Write-Log "Installing to Windows certificate store..."
    
    try {
        # Read all certificates from bundle
        $certContent = Get-Content $CABundle -Raw
        $certMatches = [regex]::Matches($certContent, "-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", [System.Text.RegularExpressions.RegexOptions]::Singleline)
        
        foreach ($match in $certMatches) {
            $certPem = $match.Value
            
            # Convert PEM to bytes
            $certText = $certPem -replace "-----BEGIN CERTIFICATE-----", "" -replace "-----END CERTIFICATE-----", "" -replace "`r", "" -replace "`n", ""
            $certBytes = [Convert]::FromBase64String($certText)
            
            $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList @(,$certBytes)
            
            # Install to Root store
            $store = New-Object System.Security.Cryptography.X509Certificates.X509Store("Root", "LocalMachine")
            $store.Open("ReadWrite")
            
            # Check if cert already exists
            $existing = $store.Certificates | Where-Object { $_.Thumbprint -eq $cert.Thumbprint }
            if (-not $existing) {
                $store.Add($cert)
                Write-Log "Installed to Windows Root store: $($cert.Subject)"
            } else {
                Write-Log "Certificate already exists in Root store: $($cert.Subject)"
            }
            
            $store.Close()
        }
    } catch {
        Write-ErrorLog "Failed to install to Windows certificate store: $_"
    }
}

function Install-PythonCA {
    param([string]$CABundle)
    
    if ($script:PythonPaths.Count -eq 0) {
        Write-Log "No Python certifi installations found"
        return
    }
    
    Write-Log "Installing to Python certifi..."
    
    foreach ($certifiPath in $script:PythonPaths) {
        Backup-File $certifiPath
        Get-Content $CABundle | Add-Content -Path $certifiPath -Encoding ASCII
        Write-Log "Installed to: $certifiPath"
    }
}

function Install-RubyCA {
    param([string]$CABundle)
    
    if ($script:RubyPaths.Count -eq 0) {
        Write-Log "No Ruby installations found"
        return
    }
    
    Write-Log "Installing to Ruby..."
    
    foreach ($rubyPath in $script:RubyPaths) {
        if (Test-Path $rubyPath -PathType Container) {
            # It's a directory, copy the bundle
            $destFile = Join-Path $rubyPath (Split-Path $CABundle -Leaf)
            Copy-Item -Path $CABundle -Destination $destFile -Force
            Write-Log "Copied to Ruby SSL dir: $rubyPath"
        } else {
            # It's a file, append
            Backup-File $rubyPath
            Get-Content $CABundle | Add-Content -Path $rubyPath -Encoding ASCII
            Write-Log "Installed to: $rubyPath"
        }
    }
}

function Install-NodeCA {
    param([string]$CABundle)
    
    $nodeExe = Get-Command node -ErrorAction SilentlyContinue
    if (-not $nodeExe) {
        Write-Log "Node.js not found"
        return
    }
    
    Write-Log "Configuring Node.js CA..."
    
    # Set system environment variable
    [System.Environment]::SetEnvironmentVariable("NODE_EXTRA_CA_CERTS", $CABundle, "Machine")
    Write-Log "Set NODE_EXTRA_CA_CERTS environment variable"
}

function Install-JavaCA {
    param([string]$CABundle)
    
    if ($script:JavaCacerts.Count -eq 0) {
        Write-Log "No Java installations found"
        return
    }
    
    $keytoolExe = Get-Command keytool -ErrorAction SilentlyContinue
    if (-not $keytoolExe) {
        Write-Log "Java keytool not found"
        return
    }
    
    Write-Log "Installing to Java cacerts..."
    
    # Extract individual certs
    $tempDir = Join-Path $env:TEMP "java-certs-$(Get-Random)"
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    
    $certContent = Get-Content $CABundle -Raw
    $certMatches = [regex]::Matches($certContent, "-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", [System.Text.RegularExpressions.RegexOptions]::Singleline)
    
    $certNum = 1
    $certFiles = @()
    
    foreach ($match in $certMatches) {
        $certFile = Join-Path $tempDir "cert-$certNum.pem"
        Set-Content -Path $certFile -Value $match.Value -Encoding ASCII
        $certFiles += $certFile
        $certNum++
    }
    
    foreach ($cacerts in $script:JavaCacerts) {
        Backup-File $cacerts
        
        $certNum = 1
        foreach ($certFile in $certFiles) {
            $alias = "custom-ca-$certNum"
            
            try {
                & keytool -import -trustcacerts -alias $alias -file $certFile `
                    -keystore $cacerts -storepass changeit -noprompt 2>$null
            } catch {
                # Cert might already exist, continue
            }
            
            $certNum++
        }
        
        Write-Log "Installed to: $cacerts"
    }
    
    Remove-Item -Path $tempDir -Recurse -Force
}

function Install-PHPCA {
    param([string]$CABundle)
    
    $phpExe = Get-Command php -ErrorAction SilentlyContinue
    if (-not $phpExe) {
        Write-Log "PHP not found"
        return
    }
    
    Write-Log "Configuring PHP..."
    
    $phpIni = & php -i 2>$null | Select-String "Loaded Configuration File" | ForEach-Object { ($_ -split "=>")[1].Trim() }
    
    if ($phpIni -and (Test-Path $phpIni)) {
        Backup-File $phpIni
        
        $iniContent = Get-Content $phpIni
        $updated = $false
        
        for ($i = 0; $i -lt $iniContent.Count; $i++) {
            if ($iniContent[$i] -match "^openssl\.cafile") {
                $iniContent[$i] = "openssl.cafile=`"$CABundle`""
                $updated = $true
                break
            }
        }
        
        if (-not $updated) {
            $iniContent += "openssl.cafile=`"$CABundle`""
        }
        
        Set-Content -Path $phpIni -Value $iniContent
        Write-Log "Updated PHP openssl.cafile in: $phpIni"
    }
    
    # Install to detected PHP cacerts
    foreach ($cacert in $script:PHPCacerts) {
        if (Test-Path $cacert) {
            Backup-File $cacert
            Get-Content $CABundle | Add-Content -Path $cacert -Encoding ASCII
            Write-Log "Installed to: $cacert"
        }
    }
}

function Configure-Git {
    param([string]$CABundle)
    
    $gitExe = Get-Command git -ErrorAction SilentlyContinue
    if (-not $gitExe) {
        Write-Log "Git not found"
        return
    }
    
    Write-Log "Configuring Git..."
    
    # Convert to Unix-style path for Git
    $gitPath = $CABundle -replace '\\', '/'
    & git config --system http.sslCAInfo $gitPath
    
    Write-Log "Set git http.sslCAInfo to: $gitPath"
}

function Install-GcloudCA {
    param([string]$CABundle)
    
    if ($script:GcloudPaths.Count -eq 0) {
        Write-Log "Google Cloud SDK not found"
        return
    }
    
    Write-Log "Installing to Google Cloud SDK..."
    
    foreach ($gcloudCert in $script:GcloudPaths) {
        Backup-File $gcloudCert
        Get-Content $CABundle | Add-Content -Path $gcloudCert -Encoding ASCII
        Write-Log "Installed to: $gcloudCert"
    }
}

function Install-AWSCA {
    param([string]$CABundle)
    
    if ($script:AWSPaths.Count -eq 0) {
        Write-Log "AWS CLI not found"
        return
    }
    
    Write-Log "Installing to AWS CLI..."
    
    foreach ($awsCert in $script:AWSPaths) {
        Backup-File $awsCert
        Get-Content $CABundle | Add-Content -Path $awsCert -Encoding ASCII
        Write-Log "Installed to: $awsCert"
    }
    
    # Set AWS_CA_BUNDLE environment variable
    [System.Environment]::SetEnvironmentVariable("AWS_CA_BUNDLE", $CABundle, "Machine")
    Write-Log "Set AWS_CA_BUNDLE environment variable"
}

function Install-ComposerCA {
    param([string]$CABundle)
    
    $composerExe = Get-Command composer -ErrorAction SilentlyContinue
    if (-not $composerExe) {
        Write-Log "Composer not found"
        return
    }
    
    Write-Log "Configuring Composer..."
    
    & composer config --global cafile $CABundle
    Write-Log "Set Composer cafile to: $CABundle"
}

function Configure-Curl {
    param([string]$CABundle)
    
    $curlExe = Get-Command curl -ErrorAction SilentlyContinue
    if (-not $curlExe) {
        Write-Log "curl not found"
        return
    }
    
    Write-Log "Configuring curl..."
    
    # Set system environment variable
    [System.Environment]::SetEnvironmentVariable("CURL_CA_BUNDLE", $CABundle, "Machine")
    Write-Log "Set CURL_CA_BUNDLE environment variable"
    
    # Also install to Windows System32 curl's default location
    $curlCaBundle = "C:\Windows\System32\curl-ca-bundle.crt"
    
    if (Test-Path "C:\Windows\System32\curl.exe") {
        try {
            Backup-File $curlCaBundle
            Copy-Item -Path $CABundle -Destination $curlCaBundle -Force
            Write-Log "Installed to: $curlCaBundle"
        } catch {
            Write-Log "Could not install to System32 curl location: $_"
        }
    }
}

# Main execution
try {
    Write-Log "Starting CA chain installation for: $Domain"
    
    # Download certificates
    $caBundle = Download-CertChain -Domain $Domain -Port $Port
    
    # Detect installations
    if (-not $SkipPython) { Detect-PythonCertifi }
    if (-not $SkipRuby) { Detect-RubyCerts }
    if (-not $SkipJava) { Detect-JavaCacerts }
    if (-not $SkipPHP) { Detect-PHPCacerts }
    if (-not $SkipGcloud) { Detect-GcloudCerts }
    if (-not $SkipAWS) { Detect-AWSCerts }
    
    # Install certificates
    if (-not $SkipSystem) { Install-SystemCA -CABundle $caBundle }
    if (-not $SkipPython) { Install-PythonCA -CABundle $caBundle }
    if (-not $SkipRuby) { Install-RubyCA -CABundle $caBundle }
    if (-not $SkipNode) { Install-NodeCA -CABundle $caBundle }
    if (-not $SkipJava) { Install-JavaCA -CABundle $caBundle }
    if (-not $SkipPHP) { Install-PHPCA -CABundle $caBundle }
    if (-not $SkipGit) { Configure-Git -CABundle $caBundle }
    if (-not $SkipGcloud) { Install-GcloudCA -CABundle $caBundle }
    if (-not $SkipAWS) { Install-AWSCA -CABundle $caBundle }
    if (-not $SkipComposer) { Install-ComposerCA -CABundle $caBundle }
    if (-not $SkipCurl) { Configure-Curl -CABundle $caBundle }
    
    Write-Log ""
    Write-Log "CA chain installation completed successfully!" -ForegroundColor Green
    Write-Log "Certificates stored in: $CertsDir"
    Write-Log "CA bundle: $caBundle"
    Write-Log ""
    Write-Log "Environment variables set:"
    Write-Log "  - NODE_EXTRA_CA_CERTS"
    Write-Log "  - AWS_CA_BUNDLE"
    Write-Log "  - CURL_CA_BUNDLE"
    Write-Log ""
    Write-Log "You may need to restart applications or re-login for changes to take effect."
    
} catch {
    Write-ErrorLog "Installation failed: $_"
    exit 1
}
