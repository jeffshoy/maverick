param (
  [string]$timestamp=(get-date -f "yyyyMMdd-HHmmss"),
  [string]$logfile, #Optional: Location of log to be used by this script.
  [switch]$quiet,
  [Parameter(Mandatory=$true)][string]$operation
 )


if (!($logfile)) {
  $Global:logfile="adssp-setupnpsextension_"+$timestamp+".log"
}

function func_eventhandler([string] $outputevent) {
  $outputevent=(get-date -f "[yyyyMMdd-HHmmss]")+" : "+$outputevent
  if (!($quiet)) {
    $outputevent
  }
  $outputevent | out-file -append $Global:logfile
}

function func_exit {
  func_eventhandler "$timestamp : End setupNpsExtension script."
  func_eventhandler "
  Actions logged to $Global:logfile
  "
  exit
}

$currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
if(!(New-Object Security.Principal.WindowsPrincipal $currentUser).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator))
{
	func_eventhandler ("Please run the setup script as administrator")
	func_exit
}


############# ADSSP NPS Extension CONFIGURATION Settings #####################

### Server/Nps/Mfa settings
$serverName = "accountportal.centralsquarecloud.com"
$serverPortNo = "443"
$secretKey = "g2Gw5zH3bTKZXb7TqWsbNzha6SJnwCCbZYVfmwy4"
$mfaStatus = "true"
$radiusApp = "VPN"
$serverSSLValidation = "true"
$bypassMFAOnConnectionError = "false"
$serverContextPath = ""

### NPS extension additional settings(optional)
#all timeout settings wil be considered in seconds
$cRPolicies = ""
$networkPolicies = ""
$logLevel = "NORMAL"
$userIPAttribute = ""

### ACL settings for the configuration Registry key(HKLM:\SOFTWARE\ZOHO Corp\ADSelfService Plus NPS Extension)
$adsspRegKeyOwner = "BUILTIN\Administrators"
$fullControlIdentities = @("NT AUTHORITY\SYSTEM","BUILTIN\Administrators") #DO NOT remove NT AUTHORITY accounts
$queryOnlyIdentities = @("NT AUTHORITY\NETWORK SERVICE") #DO NOT remove NT AUTHORITY accounts

#########################################################


function normalOut($errorMsg)
{
	if($errorMsg.Count){
	  func_eventhandler $errorMsg
	}
    func_exit
}

function errorOut($errorMsg)
{
	if($errorMsg.Count){
	  Write-Error ("Error: " + $errorMsg)
	}
    func_exit
}

function preCheckOS()
{
	$osDetails = Get-WmiObject -Class Win32_OperatingSystem
    $osType = $osDetails.ProductType
    $osMajorVersion = [int]$osDetails.version.split(".")[0]
    $osMinorVersion = [int]$osDetails.version.split(".")[1]
    if($osType -eq 1 -or $osMajorVersion -lt 6 -or ($osMajorVersion -eq 6 -and $osMinorVersion -eq 0))
    {
        normalOut("Unsupported operating system. ADSelfService Plus NPS extension is supported for Windows Server 2008 R2(SP1) & later versions only.")
    }
}

function checkConfigSettings()
{
    if( (([string]::IsNullOrEmpty($serverName)) -or ($serverName.StartsWith('%') -and $serverName.EndsWith('%'))) -or
        (([string]::IsNullOrEmpty($secretKey)) -or ($secretKey.StartsWith('%') -and $secretKey.EndsWith('%'))) -or
        ($serverPortNo.StartsWith('%') -and $serverPortNo.EndsWith('%')) -or
        ($mfaStatus.StartsWith('%') -and $mfaStatus.EndsWith('%')) -or
        ($radiusApp.StartsWith('%') -and $radiusApp.EndsWith('%')) -or
        ($serverSSLValidation.StartsWith('%') -and $serverSSLValidation.EndsWith('%')) -or
        ($bypassMFAOnConnectionError.StartsWith('%') -and $bypassMFAOnConnectionError.EndsWith('%')) -or
        ($serverContextPath.StartsWith('%') -and $serverContextPath.EndsWith('%')) )
    {
        normalOut("One or more configuration settings are missing or invalid in the script.")
    }
    return $true
}

$adsspParentRegKey = "HKLM:\SOFTWARE\ZOHO Corp";
$adsspRegKey = "$adsspParentRegKey\ADSelfService Plus NPS Extension";
$adsspInstallDir = "C:\Program Files\ManageEngine\ADSelfService Plus NPS Extension"
$authSrvRegKey = "HKLM:\System\CurrentControlSet\Services\AuthSrv";
$authSrvParamsRegKey = "$authSrvRegKey\Parameters";
$adsspNpsExtDll = "AdsspNpsExtension.dll";
$psScriptName = "setupNpsExtension.ps1";

function install()
{
    if(Test-Path $adsspRegKey)
    {
        normalOut("Already ADSelfService Plus NPS extension is installed in this machine.")
    }

    preCheckOS

    $npsService = Get-Service ias
    if ($npsService.Length -eq 0)
    {
        if ($quiet) { $confirmation = 'n' }
		else {
		  $confirmation = Read-Host "Network Policy Server(ias) service is not present in this machine. Do you still want to proceed [y/n] ?"
		}
        if ($confirmation -ne 'y' -or $confirmation -ne 'Y') {
            normalOut("Please install Network Policy Server(ias) service component. Exiting...")
        }
    }

    $currentPath = Get-Location
    if(-Not(Test-Path "$currentPath\$adsspNpsExtDll"))
    {
        normalOut("Extension library $adsspNpsExtDll is missing. Please place the .dll file in the same directory as the PS1 script.")
    }

    checkConfigSettings

    func_eventhandler "Installing ADSelfService Plus NPS Extension..."
    func_eventhandler "Copying files to $adsspInstallDir"

    try
    {
        New-Item -Path "$adsspInstallDir" -ItemType Directory  | Out-Null
        Copy-item -Path "$currentPath\$adsspNpsExtDll" -Destination "$adsspInstallDir" -Force  | Out-Null
        Copy-item -Path "$currentPath\$psScriptName" -Destination "$adsspInstallDir" -Force  | Out-Null

        if(-Not(Test-Path "$adsspInstallDir\$adsspNpsExtDll"))
        {
            errorOut("Failed while Setting up installation directory")
        }
    }
    catch
    {
        func_eventhandler "Failed while Setting up installation directory"
        errorOut("$_")
    }

    $extnDllPath = "$adsspInstallDir\$adsspNpsExtDll"
    
    func_eventhandler "Adding registry entries for NPS extension"

    #Preparing for adding NPS extension Registry entries
    if(-Not(Test-Path $authSrvRegKey))
    {
        New-Item -Path $authSrvRegKey | Out-Null
        if( -not $? )
        {
            $errorMsg = $Error[0].Exception.Message
            errorOut("Failed while creating Registry key : $authSrvRegKey with error: $errorMsg")
        }
        if(-Not(Test-Path $authSrvRegKey))
        {
            errorOut("Failed while creating Registry key : $authSrvRegKey")
        }
    }
    if(-Not(Test-Path $authSrvParamsRegKey))
    {
        New-Item -Path $authSrvParamsRegKey | Out-Null
        if( -not $? )
        {
            $errorMsg = $Error[0].Exception.Message
            errorOut("Failed while creating Registry key : $authSrvParamsRegKey with error: $errorMsg")
        }
        if(-Not(Test-Path $authSrvParamsRegKey))
        {
            errorOut("Failed while creating Registry key : $authSrvParamsRegKey")
        }
    }
    
    #Adding NPS extension Registry entries
    $extensionRegkey = Get-Item "$authSrvParamsRegKey"
    $extensionDllVal = $extensionRegkey.GetValue("ExtensionDLLs")
    $authzDllVal = $extensionRegkey.GetValue("AuthorizationDLLs")
    try
    {
        if($extensionDllVal -eq $null)
        {
            New-ItemProperty -Path "$authSrvParamsRegKey" -Name "ExtensionDLLs" -PropertyType MultiString -VALUE $extnDllPath  | Out-Null
            if( -not $? )
            {
                $errorMsg = $Error[0].Exception.Message
                errorOut("Failed while setting ExtensionDLLs with error: $errorMsg")
            }
        }
        else
        {
            $extensionDllVal += $extnDllPath
            Set-ItemProperty -Path "$authSrvParamsRegKey" -Name "ExtensionDLLs" -VALUE $extensionDllVal  | Out-Null
            if( -not $? )
            {
                $errorMsg = $Error[0].Exception.Message
                errorOut("Failed while setting ExtensionDLLs with error: $errorMsg")
            }
            func_eventhandler "Third-party NPS authentication extension(s) found, appending ADSelfService Plus NPS extension at last. Based on your need, reorder the values(at $authSrvParamsRegKey) manually after the installation."
        }

        if($authzDllVal -eq $null)
        {
            New-ItemProperty -Path "$authSrvParamsRegKey" -Name "AuthorizationDLLs" -PropertyType MultiString -VALUE $extnDllPath  | Out-Null
            if( -not $? )
            {
                $errorMsg = $Error[0].Exception.Message
                errorOut("Failed while setting AuthorizationDLLs with error: $errorMsg")
            }
        }
        else
        {
            $authzDllVal += $extnDllPath
            Set-ItemProperty -Path "$authSrvParamsRegKey" -Name "AuthorizationDLLs" -VALUE $authzDllVal  | Out-Null
            if( -not $? )
            {
                $errorMsg = $Error[0].Exception.Message
                errorOut("Failed while setting AuthorizationDLLs with error: $errorMsg")
            }
            func_eventhandler "Third-party NPS authorization extension(s) found, appending ADSelfService Plus NPS extension at last. Based on your need, reorder the values(at $authSrvParamsRegKey) manually after the installation."
        }
    }
    catch
    {
        func_eventhandler "Failed while setting Extension DDL path Registry entries"
        errorOut("$_")
    }

    func_eventhandler "Setting up registry entries for ADSSP configuration"

    #Preparing for adding ADSSP NPS config Registry entries
    if(-Not(Test-Path $adsspParentRegKey))
    {
        New-Item -Path $adsspParentRegKey | Out-Null
        if( -not $? )
        {
            $errorMsg = $Error[0].Exception.Message
            errorOut("Failed while creating Registry key : $adsspParentRegKey with error: $errorMsg")
        }
        if(-Not(Test-Path $adsspParentRegKey))
        {
            errorOut("Failed while creating Registry key : $adsspParentRegKey")
        }
    }
    if(-Not(Test-Path $adsspRegKey))
    {
        New-Item -Path $adsspRegKey | Out-Null
        if( -not $? )
        {
            $errorMsg = $Error[0].Exception.Message
            errorOut("Failed while creating Registry key : $adsspRegKey with error: $errorMsg")
        }
        if(-Not(Test-Path $adsspRegKey))
        {
            errorOut("Failed while creating Registry key : $adsspRegKey")
        }
    }

    try
    {
        New-ItemProperty -Path "$adsspRegKey" -Name "ServerName" -PropertyType String -VALUE "$serverName"  | Out-Null
        New-ItemProperty -Path "$adsspRegKey" -Name "ServerPortNo" -PropertyType String -VALUE "$serverPortNo"  | Out-Null
        New-ItemProperty -Path "$adsspRegKey" -Name "SecretKey" -PropertyType String -VALUE "$secretKey"  | Out-Null
        New-ItemProperty -Path "$adsspRegKey" -Name "MfaStatus" -PropertyType String -VALUE "$mfaStatus"  | Out-Null
        New-ItemProperty -Path "$adsspRegKey" -Name "RadiusApp" -PropertyType String -VALUE "$radiusApp"  | Out-Null
        New-ItemProperty -Path "$adsspRegKey" -Name "ServerSSLValidation" -PropertyType String -VALUE "$serverSSLValidation"  | Out-Null
        New-ItemProperty -Path "$adsspRegKey" -Name "BypassMFAOnConnectionError" -PropertyType String -VALUE "$bypassMFAOnConnectionError"  | Out-Null
        New-ItemProperty -Path "$adsspRegKey" -Name "ServerContextPath" -PropertyType String -VALUE "$serverContextPath"  | Out-Null
        New-ItemProperty -Path "$adsspRegKey" -Name "ExtensionVersion" -PropertyType String -VALUE "2.3"  | Out-Null
        New-ItemProperty -Path "$adsspRegKey" -Name "InstallationDirectory" -PropertyType String -VALUE "$adsspInstallDir"  | Out-Null
        New-ItemProperty -Path "$adsspRegKey" -Name "CRPolicies" -PropertyType String -VALUE "$cRPolicies"  | Out-Null
        New-ItemProperty -Path "$adsspRegKey" -Name "NetworkPolicies" -PropertyType String -VALUE "$networkPolicies"  | Out-Null
        New-ItemProperty -Path "$adsspRegKey" -Name "LogLevel" -PropertyType String -VALUE "$logLevel"  | Out-Null
        New-ItemProperty -Path "$adsspRegKey" -Name "UserIPAttribute" -PropertyType String -VALUE "$userIPAttribute"  | Out-Null
    }
    catch
    {
        func_eventhandler "Failed while setting ADSSP NPS configuration Registry entries"
        errorOut("$_")
    }

    #Adding ACL for the installation directory
	func_eventhandler "Setting Access control permissions for the installation directory"
    try
    {
        $installDirAcl = (Get-Acl -Path $adsspInstallDir)
	    $newACLRule = New-Object  System.Security.AccessControl.FileSystemAccessRule("NT AUTHORITY\NETWORK SERVICE", "ReadAndExecute,Write", "ObjectInherit", "None", "Allow") 
	    $installDirAcl.SetAccessRule($newACLRule)
        Set-Acl -Path $adsspInstallDir -AclObject $installDirAcl
        if( -not $? )
        {
            $errorMsg = $Error[0].Exception.Message
            func_eventhandler "Error : $errorMsg"
            func_eventhandler "Failed to give Network Service user READ permission for the install directory, Please do it manually."
        }
        else
        {
            func_eventhandler "Successfully set ACL for the installation directory"
        }
    }
	catch
    {
        func_eventhandler "$_"
        func_eventhandler "Failed to give Network Service user READ permission for the install directory, Please do it manually."
    }

    #Setting ACL for the ADSSP config Registry key
    try
    {
        $adsspRegAcl = (Get-Acl -Path $adsspRegKey)

        func_eventhandler "Setting Access control permissions for the Registry key $adsspRegKey"

        #Setting only the required ACL rules
        $adsspRegKeyOwnerPrincipal = [System.Security.Principal.NTAccount]"$adsspRegKeyOwner"
        $adsspRegAcl.SetOwner($adsspRegKeyOwnerPrincipal);
        $newACLRule = New-Object  System.Security.AccessControl.RegistryAccessRule($adsspRegKeyOwner, "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
        $adsspRegAcl.SetAccessRule($newACLRule)
        foreach ($identity in $fullControlIdentities) 
        {
            $newACLRule = New-Object  System.Security.AccessControl.RegistryAccessRule($identity, "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
            $adsspRegAcl.SetAccessRule($newACLRule)
        }
        foreach ($identity in $queryOnlyIdentities) 
        {
            $newACLRule = New-Object  System.Security.AccessControl.RegistryAccessRule($identity, "QueryValues", "ObjectInherit", "None", "Allow")
            $adsspRegAcl.SetAccessRule($newACLRule)
        }

        Set-Acl -Path $adsspRegKey -AclObject $adsspRegAcl
        if( -not $? )
        {
            $errorMsg = $Error[0].Exception.Message
            func_eventhandler "Error : $errorMsg"
            func_eventhandler "Failed to set ACL for $adsspRegKey, Please do it manually."
        }
        else
        {
            #Disabling inheritance
            $adsspRegAcl.SetAccessRuleProtection($true, $false)
            Set-Acl -Path $adsspRegKey -AclObject $adsspRegAcl
            if( -not $? )
            {
                $errorMsg = $Error[0].Exception.Message
                func_eventhandler "Error : $errorMsg"
                func_eventhandler "Failed to disable deafult ACL inheritance for the Registry key, Please do it manually."
            }

            func_eventhandler "Successfully set ACL for the Registry key"
        }
    }
	catch
    {
        func_eventhandler "$_"
        func_eventhandler "Failed to set customized ACL for $adsspRegKey, Please do it manually."
    }
    
	if ($quiet) { $confirmation = 'y' }
	else {
      $confirmation = Read-Host "Do you want to restart Network Policy Server(ias) now [y/n] ?"
    }
    if ($confirmation -ne 'y' -or $confirmation -ne 'Y') 
    {
        func_eventhandler "Please manually restart the Network Policy Server(ias) service for the installation to take effect."
    }
    else
    {
        func_eventhandler ("Restarting Network Policy Server(ias) service")
        Restart-Service ias
    }

    func_eventhandler "Installation completed successfully"
}

function uninstall()
{
    if(-Not(Test-Path $adsspRegKey))
    {
        normalOut("ADSelfService Plus NPS extension is not found in this machine or already uninstalled.")
    }
    if ($quiet) { $confirmation = 'y' }
	else {
      $confirmation = Read-Host "Uninstalling NPS extension requires restart of Network Policy Server(ias) service. Are you sure you want to Proceed [y/n] ?"
	}
    if ($confirmation -ne 'y' -or $confirmation -ne 'Y') {
        normalOut("Access denied to restart Network Policy Server(ias) service.")
    }

	func_eventhandler "Uninstalling ADSelfService Plus NPS Extension..."

    $installDir = (Get-ItemProperty -Path $adsspRegKey).InstallationDirectory

    func_eventhandler "Removing NPS extension Registry entries"
    if(Test-Path $authSrvParamsRegKey)
    {
        $adsspExtDllPath = "$installDir\$adsspNpsExtDll";
        $extensionRegkey = Get-Item "$authSrvParamsRegKey"

        try
        {
            $extensionDllVal = $extensionRegkey.GetValue("ExtensionDLLs")
            if((-Not([string]::IsNullOrEmpty($extensionDllVal))) -and ($extensionDllVal.Contains($adsspExtDllPath)))
            { 
                if($extensionDllVal.Count -eq 1)
                {
                    Remove-ItemProperty -Path "$authSrvParamsRegKey" -Name "ExtensionDLLs"
                }
                else
                {
                    $newExtensionDllVal = $extensionDllVal | ? {$_ -ne "$adsspExtDllPath"}
                    Set-ItemProperty -Path "$authSrvParamsRegKey" -Name "ExtensionDLLs" -VALUE $newExtensionDllVal  | Out-Null
                }
                if( -not $? )
                {
                    $errorMsg = $Error[0].Exception.Message
                    $errorMsg = "Error while removing extension from ExtensionDLLs : $errorMsg"
                    throw $errorMsg
                }
            }
            $authzDllVal = $extensionRegkey.GetValue("AuthorizationDLLs")
            if((-Not([string]::IsNullOrEmpty($authzDllVal))) -and ($authzDllVal.Contains($adsspExtDllPath)))
            { 
                if($authzDllVal.Count -eq 1)
                {
                    Remove-ItemProperty -Path "$authSrvParamsRegKey" -Name "AuthorizationDLLs"
                }
                else
                {
                    $newAuthzDllVal = $authzDllVal | ? {$_ -ne "$adsspExtDllPath"}
                    Set-ItemProperty -Path "$authSrvParamsRegKey" -Name "AuthorizationDLLs" -VALUE $newAuthzDllVal  | Out-Null
                }
                if( -not $? )
                {
                    $errorMsg = $Error[0].Exception.Message
                    $errorMsg = "Error while removing extension from AuthorizationDLLs : $errorMsg"
                    throw $errorMsg
                }
            }
        }
        catch
        {
            func_eventhandler "Failed while Removing NPS Extension Registry entries"
            errorOut("$_")
        }
    }

    func_eventhandler ("Stopping Network Policy Server (ias) service")
    Stop-Service -Force ias

    func_eventhandler "Clearing Installation directory"
    Remove-Item -Path "$adsspInstallDir" -Force -Recurse
    if( -not $? )
    {
        $errorMsg = $Error[0].Exception.Message
        func_eventhandler "Error : $errorMsg"
        func_eventhandler "Failed to remove the install directory:$adsspInstallDir , Please do it manually."
    }

    func_eventhandler ("Starting back the Network Policy Server (ias) service")
    Start-Service ias
    if( -not $? )
    {
        func_eventhandler "Failed to start Network Policy Server (ias) service , Please do it manually."
    }

    func_eventhandler "Clearing ADSSP NPS configuration registry entries"
    Remove-Item -Path "$adsspRegKey" -Force -Recurse
    if( -not $? )
    {
        $errorMsg = $Error[0].Exception.Message
        func_eventhandler "Error : $errorMsg"
        func_eventhandler "Failed to remove the ADSSP NPS configuration registry Key: $adsspRegKey, Please do it manually."
    }

    func_eventhandler "Uninstallation completed successfully"
}

function update()
{
    if(-Not(Test-Path $adsspRegKey) -or -Not(Test-Path $adsspInstallDir))
    {
        normalOut("ADSelfService Plus NPS extension is not found in this machine to perform update.")
    }

    $currentPath = Get-Location
    if(-Not(Test-Path "$currentPath\$adsspNpsExtDll"))
    {
        normalOut("Extension library $adsspNpsExtDll is missing. Please place the .dll file in the same directory as the PS1 script.")
    }

    checkConfigSettings

    if ($quiet) { $confirmation = 'y' }
	else {
	  $confirmation = Read-Host "Updating NPS extension requires restart of Network Policy Server(ias) service. Are you sure you want to Proceed [y/n] ?"
	}
    if ($confirmation -ne 'y' -or $confirmation -ne 'Y') {
        normalOut("Access denied to restart Network Policy Server(ias) service.")
    }

	func_eventhandler "Updating ADSelfService Plus NPS Extension..."

    func_eventhandler ("Stopping Network Policy Server (ias) service")
    Stop-Service -Force ias

    try
    {
        func_eventhandler "Updating NPS Extension files"
        Copy-item -Path "$currentPath\$adsspNpsExtDll" -Destination "$adsspInstallDir" -Force  | Out-Null
        if( -not $? )
        {
            $errorMsg = $Error[0].Exception.Message
            throw "$errorMsg"
        }
        Copy-item -Path "$currentPath\$psScriptName" -Destination "$adsspInstallDir" -Force  | Out-Null
    }
    catch
    {
        func_eventhandler "Failed while updating Extension files"
        func_eventhandler ("Starting back the Network Policy Server (ias) service")
        Start-Service ias
        errorOut("$_")
    }

    try
    {
        func_eventhandler "Updating configuration settings at registry"
        Set-ItemProperty -Path "$adsspRegKey" -Name "ServerName" -VALUE "$serverName"  | Out-Null
        Set-ItemProperty -Path "$adsspRegKey" -Name "ServerPortNo" -VALUE "$serverPortNo"  | Out-Null
        Set-ItemProperty -Path "$adsspRegKey" -Name "SecretKey" -VALUE "$secretKey"  | Out-Null
        Set-ItemProperty -Path "$adsspRegKey" -Name "MfaStatus" -VALUE "$mfaStatus"  | Out-Null
        Set-ItemProperty -Path "$adsspRegKey" -Name "RadiusApp" -VALUE "$radiusApp"  | Out-Null
        Set-ItemProperty -Path "$adsspRegKey" -Name "ServerSSLValidation" -VALUE "$serverSSLValidation"  | Out-Null
        Set-ItemProperty -Path "$adsspRegKey" -Name "BypassMFAOnConnectionError" -VALUE "$bypassMFAOnConnectionError"  | Out-Null
        Set-ItemProperty -Path "$adsspRegKey" -Name "ServerContextPath" -VALUE "$serverContextPath"  | Out-Null
        Set-ItemProperty -Path "$adsspRegKey" -Name "ExtensionVersion" -VALUE "2.3"  | Out-Null
        Set-ItemProperty -Path "$adsspRegKey" -Name "InstallationDirectory" -VALUE "$adsspInstallDir"  | Out-Null
        Set-ItemProperty -Path "$adsspRegKey" -Name "CRPolicies" -VALUE "$cRPolicies"  | Out-Null
        Set-ItemProperty -Path "$adsspRegKey" -Name "NetworkPolicies" -VALUE "$networkPolicies"  | Out-Null
        Set-ItemProperty -Path "$adsspRegKey" -Name "LogLevel" -VALUE "$logLevel"  | Out-Null
        Set-ItemProperty -Path "$adsspRegKey" -Name "UserIPAttribute" -VALUE "$userIPAttribute"  | Out-Null
    }
    catch
    {
        func_eventhandler "Failed while updating ADSSP NPS configuration Registry entries"
        func_eventhandler ("Starting back the Network Policy Server (ias) service")
        Start-Service ias
        errorOut("$_")
    }

    func_eventhandler ("Starting back the Network Policy Server (ias) service")
    Start-Service ias
    if( -not $? )
    {
        func_eventhandler "Failed to start Network Policy Server (ias) service , Please do it manually."
    }

    func_eventhandler "Successfully updated ADSelfService Plus NPS Extension to 2.3"
}

switch -Exact ($operation)
{
    'install'{
        install
    }
    'uninstall'{
        uninstall
    }
    'update'{
        update
    }
    default { 
        normalOut("Please enter a valid operation in commandline: -operation install/uninstall/update")
    }
}

if (!($quiet)) {
  Read-Host -Prompt 'Setup complete. Press Enter to continue...'
}
