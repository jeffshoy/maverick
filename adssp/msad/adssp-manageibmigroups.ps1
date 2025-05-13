param(
  [string]$timestamp=(get-date -f "yyyyMMdd-HHmmss"),
  [string]$logdir="D:\ManageEngine_repository\management_logs", #Directory containing just logs
  [string]$logfile, #Location of log to be used by this script.
  [string]$logfileprefix="adssp-manageibmigroups", #Prefix to use for all logfiles.
  [string]$logretention=30, #Number of days to keep logs
  [switch]$generateonly, #Don't make changes, only log changes to be made.
  [switch]$cleanup, #Will cleanup logs older than logretention.
  [switch]$silent, #Don't provide any screen output.
  [switch]$step
)

if (!($logfile)) {
  $Global:logfile=$logdir+"\"+$logfileprefix+"_"+$timestamp+".log"
}

function func_eventhandler([string] $outputevent) {
  $outputevent=(get-date -f "[yyyyMMdd-HHmmss]")+" : "+$outputevent
  if (!($silent)) {
    $outputevent
  }
  $outputevent | out-file -append $Global:logfile
}

function func_exit {
  func_eventhandler "$timestamp : End ADSS+ Manage IBMi Groups Script."
  if (!($silent)) {
    get-content $Global:logfile
  }
  write-host "Actions logged to $Global:logfile"
  exit
}


func_eventhandler "$timestamp : Begin ADSS+ Manage IBMi Groups Script."

#Look for Customer accounts which have an IBMi account defined and add them to the proper ADSSp Policy Group:
$customermembers=get-adgroupmember -identity "R_MEADSSP_Policy_ibmi-Customers"
foreach ($u in (get-aduser -filter * -properties mail,office -searchbase "OU=Customers,DC=centroid,DC=cloud,DC=lcl" | where-object {$_.office -ne $null})) {
  $usamaccountname=$nul
  $umail=$nul
  $usamaccountname=$u.samaccountname
  $umail=$u.mail
  if ($customermembers.samaccountname -notcontains $u.samaccountname) {
  try {
      if (!($silent)) { func_eventhandler "Processing $usamaccountname $umail..." }
      if (!($generateonly)) { add-adgroupmember -identity "R_MEADSSP_Policy_ibmi-Customers" -members $usamaccountname -confirm:$false}
	  else { $logcommand=$true}
    }
  catch {
    if (!($silent)) { func_eventhandler "Was unable to add $usamaccountname to R_MEADSSP_Policy_ibmi-Customers" }
  }
  if (($logcommand -eq $true) -OR (!($silent))) { 
    func_eventhandler "add-adgroupmember -identity R_MEADSSP_Policy_ibmi-Customers -members $usamaccountname"
  }
  if ($step) { pause }
  }
}

#Look for Centralsquare staff accounts which have an IBMi account defined and add them to the proper ADSSp Policy Group:
$staffmembers=get-adgroupmember -identity "R_MEADSSP_Policy_ibmi-CentralsquareStaff"
foreach ($u in (get-aduser -filter * -properties mail,office -searchbase "OU=Users,OU=Cloud,DC=centroid,DC=cloud,DC=lcl" | where-object {$_.office -ne $null})) {
  $usamaccountname=$nul
  $umail=$nul
  $usamaccountname=$u.samaccountname
  $umail=$u.mail
  if ($staffmembers.samaccountname -notcontains $u.samaccountname) {
  try { 
    if (!($silent)) { func_eventhandler "Processing $usamaccountname $umail..." }
    if (!($generateonly)) { add-adgroupmember -identity "R_MEADSSP_Policy_ibmi-CentralsquareStaff" -members $usamaccountname -confirm:$false }
    else { $logcommand=$true }
  }
  catch {
    if (!($silent)) { func_eventhandler "Was unable to add $usamaccountname to R_MEADSSP_Policy_ibmi-CentralsquareStaff" }
  }
  if (($logcommand -eq $true) -OR (!($silent))) {
	func_eventhandler "add-adgroupmember -identity R_MEADSSP_Policy_ibmi-CentralsquareStaff -members $usamaccountname"
  }
  if ($step) { pause }
  }
}

#Look for Customer accounts which belong to the IBMi Policy group, but have no IBMI account defined:
foreach ($u in (get-adgroupmember -identity "R_MEADSSP_Policy_ibmi-Customers"|get-aduser -properties office,mail|where-object {$_.office -eq $null}|select samaccountname,mail)) {
  $usamaccountname=$nul
  $umail=$nul
  $usamaccountname=$u.samaccountname
  $umail=$u.mail
  try { 
    if (!($silent)) { func_eventhandler "Processing $usamaccountname $umail..." }
    if (!($generateonly)) { remove-adgroupmember -identity "R_MEADSSP_Policy_ibmi-Customers" -members $usamaccountname -confirm:$false }
    else { $logcommand=$true }
  }
  catch {
    if (!($silent)) { func_eventhandler "Was unable to remove $usamaccountname from R_MEADSSP_Policy_ibmi-Customers" }
  }
  if (($logcommand -eq $true) -OR (!($silent))) {
    func_eventhandler "remove-adgroupmember -identity R_MEADSSP_Policy_ibmi-Customers -members $usamaccountname"
  }
  if ($step) { pause }
}

#Look for Centralsquare staff accounts which belong to the IBMi Policy group, but have no IBMI account defined:
foreach ($u in (get-adgroupmember -identity "R_MEADSSP_Policy_ibmi-CentralsquareStaff"|get-aduser -properties office,mail|where-object {$_.office -eq $null}|select samaccountname,mail)) {
  $usamaccountname=$nul
  $umail=$nul
  $usamaccountname=$u.samaccountname
  $umail=$u.mail
  $logcommand=$false
  try { 
    if (!($silent)) { 
	  func_eventhandler "Processing $usamaccountname $umail..."
	}
    if (!($generateonly)) { remove-adgroupmember -identity "R_MEADSSP_Policy_ibmi-CentralsquareStaff" -members $usamaccountname -confirm:$false  }
	else { $logcommand=$true }
  }
  catch {
    if (!($silent)) { func_eventhandler "Was unable to remove $usamaccountname from R_MEADSSP_Policy_ibmi-CentralsquareStaff" }
  }
  if (($logcommand -eq $true) -OR (!($silent))) {
    func_eventhandler "remove-adgroupmember -identity R_MEADSSP_Policy_ibmi-CentralsquareStaff -members $usamaccountname " 
  }
  if ($step) { pause }
}

#cleanup old logs
if ($cleanup) {
  $logtargets=$logdir+"\"+$logfileprefix+"_*"
  func_eventhandler "Discovering and Deleting any logfiles named $logtargets older than $logretention days..."
  $logtargetlist=get-childitem $logtargets |where-object {$_.creationtime -lt ((get-date).adddays(-$logretention))}|select fullname,creationtime|sort creationtime
  if ($logtargetlist) {
    foreach ($f in $logtargetlist) {
      $removetarget=$f.fullname
      func_eventhandler "Removing $removetarget"
      remove-item $removetarget
    }
  }
}

func_exit