param(
  #Examples assume an Active Directory domain for customer named VANILLA 
  # with fqdn of vani.cloud.lcl and Netbios Domain Name of VANICLD
  [string]$placeholder, #This is to work past a very strange bug where the first variable in the file never gets set.  Will fix this later.
  [string]$timestamp=(get-date -f "yyyyMMdd-HHmmss"),
  $creds, #Credentials to connect to domain
  [string]$basedn=((get-addomain -current localcomputer).DistinguishedName), #Optional: specify the basedn in format "dc=vani,dc=cloud,dc=lcl"
  [string]$basefqdn=((get-addomain -current localcomputer).dnsroot), #Optional: Base domain name fqdn in format "vani.cloud.lcl"
  [string]$basefqdnsanitized=(($basefqdn).replace(".","-")),
  [string]$dc=$basefqdn, #Optional:  Domain controller to target
  [string]$logfile, #Optional: Location of log to be used by this script.
  [string]$userlistcsv='.\adssp-getusers_list_' + $basefqdnsanitized + '_' + $timestamp + '.csv', #Optional: CSV to be created by this script containint the list of users.
  [string]$baseou=$basedn, #Optional: OU to be searched for users
  [switch]$awsmsad, #Optional:  Indicates this is an AWS Managed Active directory.  The basedn and basefqdn will include the MSAD tenant name.
  [switch]$pipeline, #output is useful for sending to next command in pipeline.
  [switch]$step, #Optional: Introduces Pause at various breakpoints for troubleshooting.
  [switch]$quiet
)
$placeholder

$baseou | out-host
if (!($logfile)) {
  if ($step) {write-host basefqdnsanitized is $basefqdnsanitized}
  $Global:logfile="adssp-getusers_"+$basefqdnsanitized+"_"+$timestamp+".log"
}

function func_eventhandler([string] $outputevent) {
  $outputevent=(get-date -f "[yyyyMMdd-HHmmss]")+" : "+$outputevent
  if (!(($quiet) -OR ($pipeline))) {
    $outputevent | Out-Host
  }
  $outputevent | out-file -append $Global:logfile
}

function func_exit {
  if ($pipeline) {
    $Global:userlistcsv = $userlistcsv
  }
  else {
    func_eventhandler "$timestamp : End ADSS+ Get-Users Script."
    write-host "Actions logged to $Global:logfile"
    write-host "Results saved in $userlistcsv."
    exit
  }    
}

$adproperties = @(
'mail',
'officephone',
'samaccountname',
'userprincipalname',
'distinguishedname',
'givenname',
'surname',
'company',
'name'
)

if (!($searchbase)) {
  $searchbase=$basedn
}

if (!($creds)) { $creds=get-credential }

func_eventhandler "$timestamp : Begin ADSS+ Get-Users Script."
foreach ($ou in $searchbase) {
  if ($step) { write-host Processing OU $ou }
  if ($step) { write-host userlistcsv is $userlistcsv }
  get-aduser -server $dc -properties $adproperties -searchbase $baseou -filter 'enabled -eq $true' -credential $creds | select $adproperties |sort samaccountname | export-csv -NoTypeInformation -append $userlistcsv
}

func_exit