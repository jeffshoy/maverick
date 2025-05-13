param(
  #Examples assume an Active Directory domain for customer named VANILLA 
  # with fqdn of vani.cloud.lcl and Netbios Domain Name of VANICLD
  [string]$target, #Target DNS Name or IP
  [string]$testport, #Optional: Specify a single port to test.
  [string]$timestamp=(get-date -f "yyyyMMdd-HHmmss"),
  [string]$logfile, #Optional: Location of log to be used by this script.
  [switch]$msad, #Performs test against Active Directory
  [switch]$ibmi, #Performs test against IBMi
  [switch]$step, #Optional: Introduces Pause at various breakpoints for troubleshooting.
  [switch]$verbose,
  [switch]$quiet
)

if ($msad) {
  $tcpports=@(
  "135",
  "139",
  "3268",
  "3269",
  "389",
  "445",
  "464",
  "593",
  "5985",
  "636",
  "88"
  )
  $udpports=@(
  "137",
  "138",
  "389",
  "445",
  "464"
  )
  
  if (!($testport)) {
    write-host "IMPORTANT:  This script currently only tests if TCP Ports are open, and does not test UDP ports.
    The following Ports cannot be checked by this script:
    UDP PORTS
    $udpports
    TCP PORTS
    49152-65535
  
    The following TCP ports WILL be checked by this script:
    $tcpports"
  
    [array]$testport=$tcpports
  }
}

if ($ibmi) {
  $tcpports=@(
  "449",
  "8470",
  "8471",
  "8472",
  "8473",
  "8474",
  "8475",
  "8476",
  "9470",
  "9471",
  "9472",
  "9473",
  "9474",
  "9475",
  "9476"
  )
  
  if (!($testport)) {
    write-host "The following TCP ports WILL be checked by this script:
    $tcpports"
    [array]$testport=$tcpports
  }
}

$testresults=@()
if ($target) {
  foreach ($port in $testport) {
    $r=(test-netconnection $target -port $port)
    $raddress=$r.remoteaddress.ipaddresstostring
    $rresult=$r.tcptestsucceeded
    $testresults+=@("$target,$raddress,$port,$rresult")  
  }
}
else {
  write-host Rerun the script and provide -target option appropriately.
  exit
}

write-host RESULTS ARE:
$testresults

if ($logfile -AND $testresults) {
  $testresults | out-file -append $logfile
}