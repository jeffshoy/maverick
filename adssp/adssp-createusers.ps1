param(
  #Examples assume an Active Directory domain for customer named VANILLA 
  # with fqdn of vani.cloud.lcl and Netbios Domain Name of VANICLD
  [string]$placeholder, #This is to work past a very strange bug where the first variable in the file never gets set.  Will fix this later.
  [string]$timestamp=(get-date -f "yyyyMMdd-HHmmss"),
  [string]$basedn=((get-addomain -current localcomputer).DistinguishedName), #Optional: specify the basedn in format "dc=vani,dc=cloud,dc=lcl"
  [string]$basefqdn=((get-addomain -current localcomputer).dnsroot), #Optional: Base domain name fqdn in format "vani.cloud.lcl"
  [string]$dc=$basefqdn, #Optional:  Domain controller to target
  [string]$logfile, #Optional: Location of log to be used by this script.
  [string]$userlistcsv, #Required: CSV containing the list of users to be imported by this script.
  [string]$salesforceaccount, #Required:  If Centralsquare Staff, set to "cst".  If for customers, set to the "Account Name" Field from Salesforce.
  [switch]$useorg, #Optional:  Don't specify $salesforceaccount.  Org will specified in org column on each record instead.
  [switch]$inventoryonly, #Optional: Checks if users already exist in Centroid and logs results to logfilecentroid.
  [switch]$duplicatesareacceptable, #Optional:  All duplicates have been reviewed and are ok to create.  This is a SECURITY RISK if used inappopriately!
  [switch]$mapadssplogin, #Optional: Do not use with "Duplicatesareacceptable".  Will set the adssplogin to the same value as mail in the csv.
  [switch]$step, #Optional: Introduces Pause at various breakpoints for troubleshooting.
  [switch]$dryrun,
  [switch]$verbose,
  [switch]$quiet
)

if (!($logfile)) {
  $Global:logfile=".\logs\adssp-createusers_"+$timestamp+".log"
  mkdir logs -f
}
$logfilefailed=($Global:logfile).replace(".log","--failed.log")
$logfilecentroid=($Global:logfile).replace(".log","--centroid.log")

function func_eventhandler([string] $outputevent) {
  $outputevent=(get-date -f "[yyyyMMdd-HHmmss]")+" : "+$outputevent
  if (!($quiet)) {
    $outputevent
  }
  $outputevent | out-file -append $Global:logfile
}

function func_exit {
  func_eventhandler "$timestamp : End ADSS+ create-users Script."
  write-host "
  Actions logged to $Global:logfile
  "
  if (test-path $logfilefailed) {
    $errorcount=(Get-content $logfilefailed | measure-object).count
	write-host "$errorcount errors logged to $logfilefailed"
  }
  else {
    write-host "No errors logged to $logfilefailed"
  }
  exit
}

$samaccountnamemaxchar="20"
if ((!($userlistcsv)) -OR ((!($salesforceaccount)) -AND (!($useorg)))) {
  func_eventhandler "$timestamp : Check syntax and rerun script."
  func_exit
}
else {
  $userlist=import-csv $userlistcsv
}

$dupesok=$nul
if ($duplicatesareacceptable) { $dupesok=$true }

function log-centroiduser($adssplogin, $distinguishedname) {
  $centroiddn=$nul
  $centroiddn=(get-aduser -filter "officephone -eq `"$adssplogin`"").DistinguishedName
  [PSCustomObject]@{
    sourcefile=$userlistcsv;
	adssplogin=$ADSSpLogin;
	sourcedn=$distinguishedname;
	centroiddn=$centroiddn;
  } | export-csv -notypeinformation -append $logfilecentroid
}
function Get-RandomCharacters($length, $characters) {
    $random = 1..$length | ForEach-Object { Get-Random -Maximum $characters.length }
    $private:ofs=""
    return [String]$characters[$random]
}

function Scramble-String([string]$inputString){     
    $characterArray = $inputString.ToCharArray()   
    $scrambledStringArray = $characterArray | Get-Random -Count $characterArray.Length     
    $outputString = -join $scrambledStringArray
    return $outputString 
}

function gen-password($options) {
  if (!($pwdlength)) {$pwdlength = 64}
  if (!($pwdminnumeral)) {$pwdminnumeral = 2}
  if (!($pwdminspecial)) {$pwdminspecial = 2}
  if (!($pwdminupper)) {$pwdminupper = 2}
  if (!($pwdminlower)) {$pwdminlower = 2}
  $pwdcharremaining = $pwdlength - $pwdminnumeral - $pwdminspecial - $pwdminupper - $pwdminlower
  $pwdchartally = @()  
  while ($pwdcharremaining -gt 0) {
    $tally=get-random -maximum 4
    $pwdchartally += @("$tally")
	$pwdcharremaining=$pwdcharremaining - 1
  }
  $pwdratio1 = ($pwdchartally.tochararray() -eq "0").count
  $pwdratio2 = ($pwdchartally.tochararray() -eq "1").count
  $pwdratio3 = ($pwdchartally.tochararray() -eq "2").count
  $pwdratio4 = ($pwdchartally.tochararray() -eq "3").count
  $pwdcomponents=@("$pwdratio1","$pwdratio2","$pwdratio3","$pwdratio4")
  $pwdcomponents=$pwdcomponents|get-random -count $pwdcomponents.count
  $pwdlower=($pwdminlower + ($pwdcomponents[0]))
  $pwdupper=($pwdminupper + ($pwdcomponents[1]))
  $pwdnumeral=($pwdminnumeral + ($pwdcomponents[2]))
  $pwdspecial=($pwdminspecial + ($pwdcomponents[3]))
  $password = Get-RandomCharacters -length $pwdlower -characters 'abcdefghiklmnopqrstuvwxyz'
  $password += Get-RandomCharacters -length $pwdupper -characters 'ABCDEFGHJKLMNOPQRSTUVWXYZ'
  $password += Get-RandomCharacters -length $pwdnumeral -characters '1234567890'
  $password += Get-RandomCharacters -length $pwdspecial -characters '!%&/()=?}][{@*+'
  $password = Scramble-String $password
  if ($options -eq "verbose") {
    $d=@(
	  "Password Length = $pwdlength",
	  "Minimum Lower Alpha = $pwdminlower",
	  "Minimum Upper Alpha = $pwdminupper",
	  "Minimum Numeral = $pwdminnumeral",
	  "Minimum Special = $pwdminspecial",
	  "Total Lower Alpha = $pwdlower",
	  "Total Upper Alpha = $pwdupper",
	  "Total Numeral = $pwdnumeral",
	  "Total Special = $pwdspecial",
	  "Generated Password = $password")
	$d
  }
  $password
  if ($step) { pause }
}

function prepare-orgou($salesforceaccount) {
  if ($salesforceaccount) {
    $Global:sfaccountname=($salesforceaccount -replace '[^a-zA-Z]').toupper()
  }
  if ($salesforceaccount -eq "cst") { 
    $Global:userbasedn="OU=Users,OU=Cloud,"+$basedn
    if ($verbose) { func_eventhandler "userbasedn is $Global:userbasedn" }
  }
  else {
    $basedn="OU=Customers,"+$basedn
    #if (!($useorg)) {
      $Global:userbasedn="OU=" + $Global:sfaccountname + "," + $basedn
      if ($verbose) { func_eventhandler "userbasedn is $Global:userbasedn" }
      try { $testOUexist = get-adorganizationalunit -identity "$Global:userbasedn" }
      catch { 
    	  [array]$global:outputmessage+="INFO: Creating OU - $Global:userbasedn"
    	  New-ADOrganizationalUnit -Name $Global:sfaccountname -ProtectedFromAccidentalDeletion 1 -Path $basedn
    	  New-ADOrganizationalUnit -Name Users -ProtectedFromAccidentalDeletion 1 -Path $Global:userbasedn
      }
    #}
  }
  if ($step) {write-host "salesforceaccount, sfaccountname,userbasedn $salesforceaccount, $Global:sfaccountname, $Global:userbasedn" }
}

if ($inventoryonly) { func_eventhandler "Performing inventory of domain only..." }

$samaccountnamemaxchar="20"

if (($salesforceaccount) -AND (!($useorg))) {
  prepare-orgou $salesforceaccount
}

if ($mapadssplogin) {
  if (($userlist|get-member -membertype noteproperty).name -notcontains "adssplogin") {  
    $adssploginprop=@{
	  MemberType = 'NoteProperty'
      Name = 'adssplogin'
      Value = $nul
    }
    $userlist | add-member @adssploginprop -passthru
  }
  $userlist
  pause
}

foreach ($u in $userlist) {
  if ($mapadssplogin) {
    $u.adssplogin = $u.mail
  }
  if ( (!($u.samaccountname)) -OR (!($u.givenname)) -OR (!($u.surname)) -OR (!($u.name)) -OR (!($u.DistinguishedName)) -OR (!($u.mail)) -OR (!($u.adssplogin)) ) {
    $u |export-csv -notypeinformation -append $logfilefailed
    func_eventhandler "FAIL: samaccountname, givenname, surname, name, mail, or adssplogin fields missing value for $u in $userlistcsv"
	continue
  }
  if ( (!($salesforceaccount)) -AND (!($u.company)) ) {
    $u |export-csv -notypeinformation -append $logfilefailed
    func_eventhandler "FAIL: org field missing value for $u in $userlistcsv"
	continue
  }
  if ($inventoryonly) {
	log-centroiduser -adssplogin $u.adssplogin -DistinguishedName $u.DistinguishedName
	continue
  }
  $tdn=$nul
  $samaccountnameexists=$nul
  $mailexists=$nul
  $adssploginexists=$nul
  $criticalfail=$nul
  $samaccountname=$nul
  $samaccountnametest=$nul
  $givenname=$nul
  $surname=$nul
  $name=$nul
  $nametest=$nul
  $mail=$nul
  $DistinguishedName=$nul
  $adssplogin=$nul
  $subou=$nul
  $upn=$nul
  $samaccountnameorig=$u.samaccountname
  if ($useorg) {
	$salesforceaccount=$u.company
	prepare-orgou $salesforceaccount
	if ($step) { pause }
#    $sfaccountname=($salesforceaccount -replace '[^a-zA-Z]').toupper()
#    $userbasedn="OU=" + $sfaccountname + "," + $basedn
#    if ($verbose) { func_eventhandler "userbasedn is $userbasedn" }
#    try { $testOUexist = get-adorganizationalunit -identity "$userbasedn" }
#    catch { 
#  	  [array]$global:outputmessage+="INFO: Creating OU - $userbasedn"
#  	  New-ADOrganizationalUnit -Name $sfaccountname -ProtectedFromAccidentalDeletion 1 -Path $basedn
#  	  New-ADOrganizationalUnit -Name Users -ProtectedFromAccidentalDeletion 1 -Path $userbasedn
#    }
  }
  if ($salesforceaccount -eq "cst") {
    $samaccountname="i_"+$samaccountnameorig
  }
  else {
	$samaccountname="c_"+$samaccountnameorig  
  }
  $givenname=$u.givenname
  $surname=$u.surname
  $name=$u.name
  $mail=$u.mail
  $distinguishedname=$u.distinguishedname
  $adssplogin=$u.adssplogin

  $adssploginexists=get-aduser -filter "officephone -eq `"$adssplogin`""
  $samaccountnameexists=get-aduser -filter "samaccountname -eq `"$samaccountname`""
  $nameexists=get-aduser -filter "name -eq `"$name`""
  $mailexists=get-aduser -filter "mail -eq `"$mail`""
  if ( $adssploginexists ) {
	func_eventhandler "DUPLICATE FAIL: Skipped since ADSSpLogin:$adssplogin collides with existing $adssploginexists.DistinguishedName"
	$criticalfail=$true
  }
  
  if ($dupesok) { $dupemessageprefix="DUPLICATE WARNING:" }
  else { $dupemessageprefix="DUPLICATE FAIL: Skipped since " }
  
#  if ( $samaccountnameexists ) {
#	if (!($dupesok)) { $criticalfail=$true }
#    func_eventhandler "$dupemessageprefix samAccountName:$samaccountname collides with existing $samaccountnameexists.DistinguishedName"
#  }

  if ( $nameexists ) {
	if (!($dupesok)) { $criticalfail=$true }
	func_eventhandler "$dupemessageprefix Name:$name collides with existing $nameexists.DistinguishedName"
  }
  if ( $mailexists ) {
    if (!($dupesok)) { $criticalfail=$true }
	func_eventhandler "$dupemessageprefix EmailAddress:$mail collides with existing $mailexists.DistinguishedName"
  }
  if ($criticalfail -eq $true) {
	$u |export-csv -notypeinformation -append $logfilefailed
	log-centroiduser -adssplogin $adssplogin -DistinguishedName $DistinguishedName
	continue
  }
  
  $samaccountnameexcess=$nul
  $samaccountnamelength=$samaccountname.length
  $samaccountnameexcess=$samaccountnamelength-$samaccountnamemaxchar
  if ( $samaccountnameexists -OR $nameexists -OR ($samaccountnameexcess -ge 1) ) {
    $unique=$false
    $uniquesam=$false
    $uniquename=$false
    $attemptnum=1
    $samaccountnamelength=$samaccountname.length
    while ($unique -eq $false) {
	  $samaccountnameexcess=$nul
      $attemptnumlength=$attemptnum.length
      $samaccountnameexcess=($samaccountnamelength+$attemptnumlength)-$samaccountnamemaxchar
	  if ($verbose) {
	    func_eventhandler "samaccountnameexcess is $samaccountnameexcess"
	  }
#   	  if ($samaccountnameexcess -ge 0) {
#		$charsoriginal=19-$samaccountnameexcess
   	  if ($samaccountnameexcess -ge 1) {
		$charsoriginal=$samaccountnamelength-$samaccountnameexcess-$attemptnumlength
   	    $samaccountnametest=("$samAccountName"[0..$charsoriginal] -join "")+([string]$attemptnum)
   	  }
   	  else {
   	    [string]$samaccountnametest=$samaccountname+([string]$attemptnum)
   	  }
   	  if ($verbose) { func_eventhandler "Testing if this samaccountname exists, $samaccountnametest" }
   	  try { get-aduser $samaccountnametest }
   	    catch { $uniquesam = $true }
   	  $nametest=$name+" "+([string]$attemptnum)
   	  if (($step) -OR ($verbose)) { func_eventhandler "Testing if this nametest exists, $nametest" }
	  try { get-aduser $nametest }
   	    catch { $uniquename = $true }
   	  if (($uniquesam -eq $true) -AND ($uniquename -eq $true)) {
   	    $unique = $true
   	    $samaccountname=$samaccountnametest
   	    $name=$nametest
   	  }
      else {
        $attemptnum=$attemptnum+1
      }
    }
	if ($verbose) {
	  $samaccountnametestlength=$samaccountnametest.length
	  func_eventhandler "samaccountnamelength=$samaccountnamelength,samaccountnameexcess=$samaccountnameexcess,attemptnumlength=$attemptnumlength,samaccountnametestlength=$samaccountnametestlength,samaccountnametest=$samaccountnametest,nametest=$nametest"
	}
  }
  
  $passwordstring=(convertto-securestring -AsPlainText (gen-password) -force)
  $vendorsou="OU=_Vendors,"+$Global:userbasedn
  
  if ($step) { write-host "SFAccountName is $Global:sfaccountname" }
  if ($Global:sfaccountname -eq "CST") {
	if (($u.company -ne "cst") -AND ($u.company)) {
	  $company=$u.company
	  $subou=($company -replace '[^0-9a-zA-Z]').toupper()
      $suboudn="OU="+$subou+","+$vendorsou
      try { $testOUexist = get-adorganizationalunit -identity $suboudn }
      catch {
	    [array]$global:outputmessage+="INFO: Creating OU - $suboudn"
	    New-ADOrganizationalUnit -Name $subou -ProtectedFromAccidentalDeletion 1 -Path $vendorsou
	  }
	  	  if ($step) { 
	   write-host "This is a CST Vendor:  $u.adssplogin"
	   pause }
	}
	else {
      $company=$salesforceaccount
      $subou=($name -replace '[^a-zA-Z]')[0]
      $suboudn="OU="+(($name)[0])+","+$Global:userbasedn
      try { $testOUexist = get-adorganizationalunit -identity $suboudn }
      catch {
	    [array]$global:outputmessage+="INFO: Creating OU - $suboudn"
	    New-ADOrganizationalUnit -Name $subou -ProtectedFromAccidentalDeletion 1 -Path $Global:userbasedn
	  }
	  if ($step) { 
	   write-host "This is a CST User:  $u.adssplogin, $Global:userbasedn"
	   pause }
	}
  }
  else {
	  if ($step) { 
	   write-host "This is a Customer User:  " $u.adssplogin, $u.company
	   pause }
    if ($u.company) {
	  $company=$u.company
	}
	else {
	  $company=$salesforceaccount
	}
	$suboudn="OU=Users," + $Global:userbasedn
  }

  $upn=$samaccountname+"@"+$basefqdn

  func_eventhandler "new-aduser -PATH `"$suboudn`" -samaccountname `"$samaccountname`" -userprincipalname $upn -company `"$company`" -givenname `"$givenname`" -surname `"$surname`" -displayname `"$name`" -name `"$name`" -emailaddress `"$mail`" -officephone `"$adssplogin`" -enabled $true -accountpassword redacted"

  if (!($dryrun)) { new-aduser -PATH "$suboudn" -samaccountname "$samaccountname" -userprincipalname $upn -givenname "$givenname" -surname "$surname" -company "$company" -displayname "$name" -name "$name" -emailaddress "$mail" -officephone "$adssplogin" -enabled $true -accountpassword $passwordstring }
  
  log-centroiduser -adssplogin $adssplogin -DistinguishedName $DistinguishedName
}

func_exit