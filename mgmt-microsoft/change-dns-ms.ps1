param(
  [string]$timestamp=(get-date -f "yyyyMMdd-HHmmss"),
  [Parameter(Mandatory=$true)][string]$client, #set to the client code
  [Parameter(Mandatory=$true)][string]$oldip, #Set to Old IP Address
  [Parameter(Mandatory=$true)][string]$newip, #Set to New IP Address
  [Parameter(Mandatory=$true)][string]$zone, #DNS zone
  [Parameter(Mandatory=$true)][string]$server, #DNS server hosting the zone to be changed
  [string]$dnsservervmname=@("inf-svrdns001","inf-svrdc001","inf-svrdc002","inf-svrdc011","inf-svrdc012","inf-svrdc012","inf-svrdc101","inf-svrdc102","inf-svrdc111","inf-svrdc112"),
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
  $Global:logfile="changedns-ms_"+$client+"_"+$timestamp+"_"+$action+".log"
}

function func_eventhandler([string] $outputevent) {
  $outputevent=(get-date -f "[yyyyMMdd-HHmmss]")+" : "+$outputevent
  if (!($quiet)) {
    $outputevent
  }
  $outputevent | out-file -append $Global:logfile
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

$olddns=get-dnsserverresourcerecord -zonename $zone -computername $server | where-object {($_.recorddata.ipv4address -eq $oldip) -AND ($_.recorddata.ipv4address -ne $nul)}

if (!($olddns)) {
  func_eventhandler "ERROR:  No Records on DNSServer=$server in Zone=$zone matching Old IP of $oldip."
  $outputcode=1
}

function func_precheck {
  $newdns=get-dnsserverresourcerecord -zonename $zone -computername $server | where-object {($_.recorddata.ipv4address -eq $newip) -AND ($_.recorddata.ipv4address -ne $nul)}
  if ($newdns) {
    func_eventhandler "ERROR:  EXISTING RECORD FOUND ON DNSServer=$server in Zone=$zone matching NEW IP of $newip."
  }
  if (!($outputcode)) {
    func_eventhandler "INFO:  Precheck passed with no errors."
  }
  else {
    func_exit
  }
}

function func_changedns {
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
}

function func_clearserverdnscache {
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

if ($precheck) { func_precheck }

if ($outputcode -gt 0) {
  func_eventhandler "Exiting due to previos ERRORs..."
  func_exit
}

if ($changedns) { func_changedns }

if ($cleardnsservercache) { func_clearserverdnscache }

func_exit