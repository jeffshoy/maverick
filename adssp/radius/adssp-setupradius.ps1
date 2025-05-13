param(
  #Examples assume an Active Directory domain for customer named VANILLA 
  # with fqdn of vani.cloud.lcl and Netbios Domain Name of VANICLD
  [string]$timestamp=(get-date -f "yyyyMMdd-HHmmss"),
  [string]$configfile=".\cst-radius.xml", #Location of the NPS configuration to be imported.  Stored in NPM
  [string]$logfile, #Optional: Location of log to be used by this script.
  [string]$msadfqdn=((get-addomain -current localcomputer).dnsroot), #Optional: Base domain name fqdn in format "vani.cloud.lcl"
  [string]$mailto,#Optional: Specify email address to mail results to.
  [switch]$step, #Optional: Introduces Pause at various breakpoints for troubleshooting.
  [switch]$verbose,
  [switch]$quiet
)

if (!($logfile)) {
  $Script:logfile="adssp-setupradius_"+$timestamp+".log"
}

function func_eventhandler([string] $outputevent) {
  $outputevent=(get-date -f "[yyyyMMdd-HHmmss]")+" : "+$outputevent
  if (!($quiet)) {
    $outputevent
  }
  $outputevent | out-file -append $Script:logfile
}

function func_exit([string] $outputcode) {
  func_eventhandler "$timestamp : End ADSSp Radius Setup Script."
  write-host "
  Actions logged to $Script:logfile
  "
  if ($mailto) {
    $logcontents=(get-content $Script:logfile) -join '<br>'
	if ($outputcode) {
	  $subject=$timestamp+" - Failed - ADSSp Radius Setup Script:"+(hostname)
	} else {
	  $subject=$timestamp+" - Success - ADSSp Radius Setup Script:"+(hostname)
	}
	if ((test-netconnection relay.aspgov.com -port 25).tcptestsucceeded -eq "True") { $smtprelay="relay.aspgov.com" }
	if (!($smtprelay)) {
	  if ((test-netconnection relay101.aspgov.com -port 25).tcptestsucceeded -eq "True") { $smtprelay="relay101.aspgov.com" }
	}
	if ($smtprelay) { send-mailmessage -from "aspinfrastructure@centralsquare.com" -to "aspinfrastructure+tanium@centralsquare.com" -subject $subject -bodyashtml -body "$logcontents" -smtpserver $smtprelay }
  }
  exit $outputcode
}

function func_runonce {
  	
}
#Validate necessary files exist
$filelist=@(
".\cst-radius.xml",
".\setupNpsExtension.ps1",
"adsspNpsExtension.dll"
)
$missingfiles=$false
foreach ($f in $filelist) {
  if (!(test-path $f)) {
    func_eventhandler "Required File is missing: $f"
	$missingfiles=$true
  }
}
if ($missingfiles -eq $true) {
  func_eventhandler "Ensure missing files are available and rerun script."
  $outputcode+=1
  func_exit $outputcode
}
else {
  func_eventhandler "Precheck:  Package exists..."
}

#Confirm the VPN Group exists.  If not, exit
try {
  $tenant=((hostname).split("-"))[0]
  $vpngroupname=$tenant+"_vpn"
  $VPNGROUPSID=(get-adgroup $vpngroupname).sid.value
  if ($VPNGROUPSID) {
    func_eventhandler "Precheck:  Group $vpngroupname exists..."
  }
}
catch {
  func_eventhandler "Expected a vpn group named $vpngroupname, but it did not exist.  Exiting..."
  $outputcode+=2
  func_exit $outputcode
}

#Install and register NPS
install-windowsfeature NPAS -includemanagementtools
if (((get-windowsfeature NPAS).installstate) -ne "Installed") {
  func_eventhandler "The Network Policy Server is not installed.  Exiting..."
  $outputcode+=4
  func_exit $outputcode
}
else {
  func_eventhandler "Install:  NPS Role successfully installed..."
}

netsh nps add registeredserver
$netshresults=netsh nps show registeredserver
if (!($netshresults | select-string "Status = Registered")) {
  func_eventhandler "Could not register NPS server with Domain.  Exiting..."
  func_eventhandler "$netshresults"
  $outputcode+=8
  func_exit $outputcode
}
else {
  func_eventhandler "Config:  Server successfully registered with Active Directory..."
}

#Transform XML File
[xml]$xmldata=get-content $configfile
[string]$defaultgateway=(Get-WmiObject -Class Win32_NetworkAdapterConfiguration | select defaultipgateway).defaultipgateway
func_eventhandler "Config:  Setting IP Address for the NPS Radius Client to $defaultgateway"
$xmldata.root.children.Microsoft_Internet_Authentication_Service.Children.Protocols.Children.Microsoft_Radius_Protocol.Children.Clients.Children.cloud_asav.Properties.IP_Address."#text"=$defaultgateway
func_eventhandler "Config:  Setting the Network Policy User Group to use the group $vpngroupname with a SID of $VPNGROUPSID"
$xmldata.root.children.Microsoft_Internet_Authentication_Service.Children.NetworkPolicy.Children.np_vpn_mfa.Properties.msNPConstraint."#text"=($xmldata.root.children.Microsoft_Internet_Authentication_Service.Children.NetworkPolicy.Children.np_vpn_mfa.Properties.msNPConstraint."#text").replace("VPNGROUPSID",$VPNGROUPSID)
$newconfigfile=($configfile | split-path)+(((($configfile | split-path -leaf)).split("."))[0])+"_"+$timestamp+".xml"
$xmldata.save("$newconfigfile")

#Import XML File
import-npsconfiguration -path $newconfigfile
if ($? -eq $true) {
  func_eventhandler "Config:  Importing NPS Configuration..."
}
else {
  func_eventhandler "Could not import NPS Configuration from $newconfigfile..."
  $outputcode+=16
  func_exit $outputcode
}

func_eventhandler "Install:  Installing ADSSP NPS Extension..."
#uninstall meadss library
.\setupnpsextension.ps1 -operation uninstall -quiet
#install meadss library
.\setupnpsextension.ps1 -operation install -quiet

func_eventhandler "Deployment of NPS for Cisco Anyconnect successful!"
func_exit