param(
  [string]$Domain = "opc.ren",
  [switch]$Repair,
  [string]$Output = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

if ([string]::IsNullOrWhiteSpace($Output)) {
  $Output = ".\egress-report-$Domain-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"
}

function Write-Log {
  param([string]$Message)
  $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
  $line | Tee-Object -FilePath $Output -Append
}

function Write-Section {
  param([string]$Title)
  "`n========== $Title ==========" | Tee-Object -FilePath $Output -Append
}

function Run-Cmd {
  param(
    [string]$Title,
    [scriptblock]$Command
  )
  Write-Section $Title
  try {
    & $Command 2>&1 | Tee-Object -FilePath $Output -Append
    Write-Log "exit=0"
  } catch {
    Write-Log "exit=1 : $($_.Exception.Message)"
  }
}

function Resolve-A {
  param([string]$HostName)
  try {
    ($r = Resolve-DnsName -Type A -Name $HostName -ErrorAction Stop | Select-Object -ExpandProperty IPAddress) -join " "
  } catch {
    ""
  }
}

function Resolve-A-ByDns {
  param([string]$HostName, [string]$Server)
  try {
    ($r = Resolve-DnsName -Type A -Name $HostName -Server $Server -ErrorAction Stop | Select-Object -ExpandProperty IPAddress) -join " "
  } catch {
    ""
  }
}

function Test-TcpPort {
  param([string]$HostName, [int]$Port)
  try {
    $ok = Test-NetConnection -ComputerName $HostName -Port $Port -WarningAction SilentlyContinue
    "ComputerName={0} Port={1} TcpTestSucceeded={2}" -f $HostName, $Port, $ok.TcpTestSucceeded
  } catch {
    "TCP probe failed: $($_.Exception.Message)"
  }
}

"# Network Egress Doctor Report" | Out-File -FilePath $Output -Encoding UTF8
"# Domain: $Domain" | Out-File -FilePath $Output -Append -Encoding UTF8
"# GeneratedAt: $(Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')" | Out-File -FilePath $Output -Append -Encoding UTF8

Run-Cmd "Host Context" {
  Get-ComputerInfo -Property OsName,OsVersion,OsBuildNumber | Format-List
  whoami
  hostname
  Get-ChildItem Env: | Where-Object { $_.Name -match '^(HTTP|HTTPS|ALL|NO)_PROXY$' } | Format-Table -AutoSize
}

Write-Section "DNS Comparison"
$sysA = Resolve-A -HostName $Domain
$aliA = Resolve-A-ByDns -HostName $Domain -Server "223.5.5.5"
$n114A = Resolve-A-ByDns -HostName $Domain -Server "114.114.114.114"
$cfA = Resolve-A-ByDns -HostName $Domain -Server "1.1.1.1"
$googleA = Resolve-A-ByDns -HostName $Domain -Server "8.8.8.8"
Write-Log "system-resolver A: $sysA"
Write-Log "223.5.5.5 A:      $aliA"
Write-Log "114.114.114.114 A:$n114A"
Write-Log "1.1.1.1 A:        $cfA"
Write-Log "8.8.8.8 A:        $googleA"

Run-Cmd "Connectivity Probes" {
  Test-TcpPort -HostName $Domain -Port 443
  Test-TcpPort -HostName $Domain -Port 80
}

Run-Cmd "HTTP Checks" {
  (Invoke-WebRequest -Uri "http://$Domain" -Method Head -MaximumRedirection 0 -ErrorAction SilentlyContinue).StatusCode
  (Invoke-WebRequest -Uri "https://$Domain" -Method Head -MaximumRedirection 0 -ErrorAction SilentlyContinue).StatusCode
}

if ($Repair) {
  Run-Cmd "Repair: Flush DNS Cache" {
    ipconfig /flushdns
  }
  Run-Cmd "Post-Repair HTTPS Check" {
    (Invoke-WebRequest -Uri "https://$Domain" -Method Head -MaximumRedirection 0 -ErrorAction SilentlyContinue).StatusCode
  }
}

Write-Section "Diagnosis"
if ([string]::IsNullOrWhiteSpace($sysA) -and -not [string]::IsNullOrWhiteSpace($aliA + $n114A + $cfA + $googleA)) {
  Write-Log "Likely local DNS resolver/cache issue."
} elseif (-not [string]::IsNullOrWhiteSpace($sysA)) {
  Write-Log "DNS resolves. If browser still fails, check enterprise proxy, TLS interception, or endpoint policy."
} else {
  Write-Log "No resolver returned records. Check DNS egress policy."
}

Write-Section "Next Actions"
Write-Log "1) Use DNS 223.5.5.5 / 114.114.114.114 and retest."
Write-Log "2) If DNS works but HTTPS fails, escalate to network admin for gateway allowlist."
Write-Log "3) Attach this report for escalation."
Write-Log "Report written to: $Output"
