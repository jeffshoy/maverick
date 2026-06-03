#Requires -Modules DnsServer

<#
.SYNOPSIS
    Change DNS A records on Microsoft DNS servers across all CloudOps DNS servers.
.DESCRIPTION
    Supports three operation modes via switch parameters:
      -precheck          Validates that oldip exists and newip does not yet exist in the zone.
      -changedns         Replaces all A records with oldip with newip in the specified zone.
      -cleardnsservercache  Flushes the DNS server cache on all CloudOps DNS servers via VMware.

    Results are logged to a timestamped log file. Optional email notification via -mailto.
.PARAMETER client
    Client code used for log file naming (e.g. REDB).
.PARAMETER oldip
    The IP address to find and replace.
.PARAMETER newip
    The new IP address to assign.
.PARAMETER zone
    The DNS zone to search (e.g. aspgov.com).
.PARAMETER server
    The DNS server hosting the authoritative zone.
.PARAMETER precheck
    Run pre-change validation only — no records are modified.
.PARAMETER changedns
    Execute the DNS change from oldip to newip.
.PARAMETER cleardnsservercache
    Flush DNS cache on all CloudOps DNS servers via VMware Invoke-VMScript.
.EXAMPLE
    .\change-dns-ms.ps1 -client REDB -oldip 10.1.2.3 -newip 10.1.2.4 -zone aspgov.com -server inf-svrdns001 -precheck
    .\change-dns-ms.ps1 -client REDB -oldip 10.1.2.3 -newip 10.1.2.4 -zone aspgov.com -server inf-svrdns001 -changedns
.NOTES
    Requires RSAT DnsServer module. -cleardnsservercache requires VMware PowerCLI.
    All operations are logged to changedns-ms_<client>_<timestamp>.log.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
  [string]$timestamp=(get-date -f "yyyyMMdd-HHmmss"),
  [Parameter(Mandatory=$true)][string]$client, #set to the client code
  [Parameter(Mandatory=$true)][string]$oldip, #Set to Old IP Address
  [Parameter(Mandatory=$true)][string]$newip, #Set to New IP Address
  [Parameter(Mandatory=$true)][string]$zone, #DNS zone
  [Parameter(Mandatory=$true)][string]$server, #DNS server hosting the zone to be changed
  $dnsservervmname=@("inf-svrdns001","inf-svrdc001","inf-svrdc002","inf-svrdc011","inf-svrdc012","inf-svrdc012","inf-svrdc101","inf-svrdc102","inf-svrdc111","inf-svrdc112"),
  [string]$logfile, #Optional: Location of log to be used by this script.
  [string]$mailto,#Optional: Specify email address to mail results to.
  $creds, #Optional:  Only needed with cleardnsservercache
  [switch]$precheck, #Checks if the Old or IP Address is in use.
  [switch]$changedns, #Updates the DNS Records from oldip to newip
  [switch]$cleardnsservercache, #Clears the DNSServerCache on specified DNS Servers
  [switch]$step, #Optional: Introduces Pause at various breakpoints for troubleshooting.
  [switch]$quiet
)

if (!($logfile)) {
  $script:logfile="changedns-ms_"+$client+"_"+$timestamp+".log"
}

function func_eventhandler([string] $outputevent) {
  $outputevent=(get-date -f "[yyyyMMdd-HHmmss]")+" : "+$outputevent
  if (!($quiet)) {
    $outputevent
  }
  $outputevent | out-file -append $script:logfile
}

function func_exit([string] $outputcode) {
  func_eventhandler "$timestamp : End changedns-ms Script."
  write-host "
  Actions logged to $Script:logfile
  "
  if ($mailto) {
   $logcontents=(get-content $Script:logfile) -join '<br>'
  if ($outputcode) {
    $subject=$timestamp+" - Failed - changedns-ms Script:"+$client
  } else {
    $subject=$timestamp+" - Success - changedns-ms Script:"+$client
  }
  if ((test-netconnection relay.aspgov.com -port 25).tcptestsucceeded -eq "True") { $smtprelay="relay.aspgov.com" }
  if (!($smtprelay)) {
    if ((test-netconnection relay101.aspgov.com -port 25).tcptestsucceeded -eq "True") { $smtprelay="relay101.aspgov.com" }
  }
  if ($smtprelay) { send-mailmessage -from "aspinfrastructure@centralsquare.com" -to "aspinfrastructure+cloudops@centralsquare.com" -subject $subject -bodyashtml -body "$logcontents" -smtpserver $smtprelay }
  }
  exit $outputcode
}

func_eventhandler "$timestamp : Begin changedns-ms script."

$olddns=get-dnsserverresourcerecord -zonename $zone -computername $server | where-object {($_.recorddata.ipv4address -eq $oldip) -AND ($_.recorddata.ipv4address -ne $null)}

function func_dnscheck($action) {
  if ($action -eq "precheck") { 
    func_eventhandler "INFO:  Starting Precheck..."
	$oldstatus="INFO:"
	$newstatus="WARNING:"
  }
  if ($action -eq "validation") { 
    func_eventhandler "INFO:  Starting validation..." 
	$oldstatus="ERROR:"
	$newstatus="INFO:"
  }
  $foundoldip=$false
  $foundnewip=$false
  if ($olddns) {
	func_eventhandler "$oldstatus  Record found ON DNSServer=$server in Zone=$zone matching OLD IP of $oldip."
	$foundoldip=$True
  }
  else {
    func_eventhandler "$oldstatus  No Records on DNSServer=$server in Zone=$zone matching OLD IP of $oldip."
  }

  $newdns=get-dnsserverresourcerecord -zonename $zone -computername $server | where-object {($_.recorddata.ipv4address -eq $newip) -AND ($_.recorddata.ipv4address -ne $null)}
  if ($newdns) {
    func_eventhandler "$newstatus  Existing record found on DNSServer=$server in Zone=$zone matching NEW IP of $newip."
	$foundnewip=$True
  }
  else {
    func_eventhandler "$oldstatus  No Records on DNSServer=$server in Zone=$zone matching Old IP of $oldip."
  }

$outputcode=$null
  
  if (($action -eq "precheck") -AND (($foundoldip -eq $false) -OR ($foundnewip -eq $true))) {
    $outputcode=1
	$newdnsstring=@("Hostname,RecordType")
	foreach ($d in $newdns) {
	  $newdnsstring+=@($d.hostname+","+$d.RecordType)
	}
	$newdnsstring=$newdnsstring -join '|'
	func_eventhandler "ERROR:  Records with New IP are: $newdnsstring"
  }
  if (($action -eq "validation") -AND (($foundoldip -eq $true) -OR ($foundnewip -eq $false))) {
	$outputcode=1
	$olddnsstring=@("Hostname,RecordType")
	foreach ($d in $olddns) {
	  $olddnsstring+=@($d.hostname+","+$d.RecordType)
	}
	$olddnsstring=$olddnsstring -join '|'
	func_eventhandler "ERROR:  Records with Old IP are: $olddnsstring"
  }
  if ($outputcode -eq 1) {  
    if ($ignoreerrors) { func_eventhandler "WARNING:  Script ran with IgnoreErrors parameter, attempting to continue despite above Errors..." }
	else {
	  func_eventhandler "Exiting with errors..."
	  func_exit $outputcode
	}
  }
  else {
	func_eventhandler "INFO:  Precheck passed with no errors."
  }
}

function func_changedns {
  func_eventhandler "INFO:  Starting ChangeDNS..."
  foreach ($o in $olddns) {
    $ohostname=$o.hostname
    $oipv4address=$o.recorddata.ipv4address
    $otype=$o.recordtype
    $n=[ciminstance]::new($o)
    $n.recorddata.ipv4address=[system.net.ipaddress]::parse($newip)
    func_eventhandler "Updating DNS record: DNSServer=$server, Zone=$zone, type=$otype, host=$ohostname, OLDaddress=$oipv4address, NEWAddress=$newip"
	if ($step) {
      $o
  	  $n
      pause
    }
    set-dnsserverresourcerecord -newinputobject $n -oldinputobject $o -zonename $zone -computername $server
  }
  $olddns=get-dnsserverresourcerecord -zonename $zone -computername $server | where-object {($_.recorddata.ipv4address -eq $oldip) -AND ($_.recorddata.ipv4address -ne $null)}

}

function func_clearserverdnscache {
  func_eventhandler "Starting ClearserverDNSCache..."
  if (!($creds)) {
	func_eventhandler "VM Guest Credentials not set.  Prompting..."
    $creds=get-Credential
  }
  func_eventhandler "INFO: Connecting to Virtual Center..."
  try { $connection=connect-viserver inf-vmwvc001.cloud.lcl }
  catch { func_eventhandler "Unable to connect to inf-vmwvc001.cloud.lcl" }
  try { $connection=connect-viserver inf-vmwvc401.cloud.lcl }
  catch { func_eventhandler "Unable to connect to inf-vmwvc401.cloud.lcl" }
  $vmscript="clear-dnsservercache -force"
  foreach ($vm in $dnsservervmname) {
	func_eventhandler "Clearing DNS Server Cache on $vm"
	if ($step) { pause }
    invoke-vmscript -scripttext $vmscript -GuestCredential $creds -vm $vm
  }
}

if ($precheck) { func_dnscheck precheck }

if ($changedns) { 
  func_changedns
  func_dnscheck validation
}

if ($cleardnsservercache) { func_clearserverdnscache }

func_exit