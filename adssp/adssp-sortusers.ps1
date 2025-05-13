param(
  #Examples assume an Active Directory domain for customer named VANILLA 
  # with fqdn of vani.cloud.lcl and Netbios Domain Name of VANICLD
  [string]$timestamp=(get-date -f "yyyyMMdd-HHmmss"),
  [string]$logfile, #Optional: Location of log to be used by this script.
  [string]$userlistcsv='.\adssp-getusers_list'+$timestamp+'.csv', #Optional: CSV to be created by this script containint the list of users.
  [string]$filterou, #Optional: OU to be searched for users
  [array]$domainscst,
  [array]$domainscustomer=@("vanilla"),
  [switch]$reports,
  [switch]$filtercst,
  [switch]$filtercustomer,
  [switch]$filterunclassified,
  [switch]$identifydomains,
  [switch]$finddupes,
  [switch]$checkmail,
  [switch]$checknomail,
  [switch]$finduniquemail,
  [switch]$pipeline,
  [switch]$step, #Optional: Introduces Pause at various breakpoints for troubleshooting.
  [switch]$quiet
)
#Sort cases
#Users in "Users" OU without an email address
#Users in other OUs with and without an email address
#Users in "Users" OU with an email address
#check if user named "admin" exists and flag if it does

if (!($logfile)) {
  $Global:logfile="adssp-sortusers_"+$timestamp+".log"
}

function func_eventhandler([string] $outputevent) {
  $outputevent=(get-date -f "[yyyyMMdd-HHmmss]")+" : "+$outputevent
  if (!($quiet)) {
    $outputevent
  }
  $outputevent | out-file -append $Global:logfile
}

function func_exit {
  func_eventhandler "$timestamp : End ADSS+ sort-users Script."
  write-host "Actions logged to $Global:logfile"
  exit
}

if (!($domainscst)) {
  [array]$domainscst=@(
"centralsaquare.com",
"centralsquare.com",
"centralsquare.com ",
"centralsquare.com.com",
"centrasquare.com",
"cetralsquare.com",
"coa.sungardpsasp.com",
"sungardp.com",
"sungardps.com",
"superion.com",
"superionn.com"
  )
}
$csv=import-csv $userlistcsv

if ($step) {
  $csvlines=(($csv | measure-object).count)
  write-host "Imported csv with $csvlines lines"}

if (!($filterou)) {
  func_eventhandler "Please Specify a working OU from $userlistcsv..."
  func_exit
}

if (($checkmail) -OR ($reports)) {
  if ($step) {func_eventhandler "Checking for user accounts with an email address specified."}
  $cmail=$csv | where-object {($_.DistinguishedName -match $filterou) -AND ($_.mail -match "@")}
  if ($step) { write-host A sample is: 
               $cmail[0] }
  if ($cmail) {
    $cmailcsv=(($userlistcsv).replace(".csv","--checkmail.csv"))
    $cmail | export-csv -notypeinformation -force $cmailcsv
	write-host "Results saved in $cmailcsv."
  }

}

if (($checknomail) -OR ($reports)) {
  if ($step) {func_eventhandler "Checking for user accounts with no email address specified."}
  $cnomail=$csv | where-object {($_.DistinguishedName -match $filterou) -AND ($_.mail -notmatch "@")}
  if ($cnomail) {
    $cnomailcsv=(($userlistcsv).replace(".csv","--checknomail.csv"))
    $cnomail | export-csv -notypeinformation -force $cnomailcsv
	write-host "Results saved in $cnomailcsv."
  }
  
}

if (($filtercst) -OR ($reports)) {
  if ($step) {func_eventhandler "Checking for user accounts with Centralsquare-related email addresses."}
  $cstmail=@()
  foreach ($domain in $domainscst) {$cstmail+=@($csv | where-object {$_.mail -match $domain})}
  if ($cstmail) {
    $cstmailcsv=(($userlistcsv).replace(".csv","--cstmail.csv"))
    $cstmail | export-csv -notypeinformation -force $cstmailcsv
	write-host "Results saved in $cstmailcsv."
  }
}

if (($filtercustomer -AND $domainscustomer) -OR ($reports -AND $domainscustomer)) {
  if ($step) {func_eventhandler "Checking for user accounts with customer-related email addresses."}
  $customermail=@()
  foreach ($domain in $domainscustomer) {$customermail+=@($csv | where-object {$_.mail -match $domain})}
  if ($customermail) {
    $customermailcsv=(($userlistcsv).replace(".csv","--customermail.csv"))
    $customermail | export-csv -notypeinformation -force $customermailcsv
	write-host "Results saved in $customermailcsv."
  }
}

if (($filterunclassified) -OR ($reports)) {
  if ($step) {func_eventhandler "Checking for user accounts with email addresses not related to Centralsquare or the Customer."}
  $unclassifiedmail=@()
  [array]$domainsclassified=$domainscst #+ $domainscustomer
  if ($step) {write-host Domainsclassified is $Domainsclassified}
  foreach ($u in $csv) {
    $unclassifiedmail+=$u | where { ($_.mail -match "@") -AND (((($_.mail).split("@"))[1]) -notin $domainsclassified) }
  }
  if ($unclassifiedmail) {
    $unclassifiedmailcsv=(($userlistcsv).replace(".csv","--unclassifiedmail.csv"))
    $unclassifiedmail | export-csv -notypeinformation -force $unclassifiedmailcsv
	write-host "Results saved in $unclassifiedmailcsv."
  }
}

if (($identifydomains) -OR ($reports)) {
  if ($step) {func_eventhandler "Checking what email address domains are assigned to accounts."}
  $maildomains=@()
  foreach ($u in ($csv | where-object {$_.mail -match "@"})) {
    $maildomains+=((($u.mail).split("@"))[1])
  }
  if ($maildomains) {
    $maildomains=$maildomains | sort -unique
    if ($step) { $maildomains }
    $maildomainscsv=(($userlistcsv).replace(".csv","--maildomains.csv"))
    $maildomains | out-file  -force $maildomainscsv
	write-host "Results saved in $maildomainscsv."
  }
}

if (($finddupes) -OR ($reports)) {
  if ($step) {func_eventhandler "Checking for user accounts with sharing the same email address."}
  $duplicatemail=$csv |where-object {$_.mail -match "@"} | group-object -property mail |where-object {$_.count -ge 2} |foreach-object {$_.group}
  if ($duplicatemail) {
    $duplicatemailcsv=(($userlistcsv).replace(".csv","--duplicatemail.csv"))
    $duplicatemail | export-csv -notypeinformation -force $duplicatemailcsv
	write-host "Results saved in $duplicatemailcsv."
  }
}

if (($finduniquemail) -OR ($reports)) {
  if ($step) {func_eventhandler "Checking for user accounts with a unique email address."}
  $uniquemail=$csv |where-object {$_.mail -match "@"} | group-object -property mail |where-object {$_.count -eq 1} |foreach-object {$_.group}
  if ($uniquemail) {
    $uniquemailcsv=(($userlistcsv).replace(".csv","--uniquemail.csv"))
    $uniquemail | export-csv -notypeinformation -force $uniquemailcsv
	write-host "Results saved in $uniquemailcsv."
  }
}

if ($pipeline) {
  $Global:userlistcsv = $uniquemailcsv
}