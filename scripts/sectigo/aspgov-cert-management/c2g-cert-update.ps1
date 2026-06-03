# Begin PowerShell Transcript
$nextYear = (Get-Date).Year + 1
$sourceDir = "C:\temp\ASPGOV_Cert_Renewal\$nextYear"
$logpath  = "$sourceDir\logs"
$username   = "$env:USERNAME"
$datetime   = Get-Date -f 'yyyyMMddHHmmss'
$logname   = "voor-c2g-load-cert-renewal-transcript-$username-$datetime.txt"
$Transcript = Join-Path -Path $logpath -ChildPath $logname
Start-Transcript -Path $Transcript

#connect to vsphere
$VIServerList = ("inf-vmwvc001.cloud.lcl","inf-vmwvc401.cloud.lcl")
foreach ($VIServer in $VIServerList) { connect-viserver $VIServer }
# Get list of servers to deploy cert to
$Servers = get-vm *c2gwb* | where-object {$_.PowerState -eq "PoweredOn"} | Sort-Object

# Create File list (update $sourceDir to your local file directory)
$certSourceDir = "$sourceDir\CertFiles\"
$Cert = "star_aspgov_com_2026.crt"
$Key = "star_aspgov_com_2026-decrypted.key"
$Intermediate = "Sectigo_intermediate.crt"
$TrustedRoot = "Sectigo_CA_root.crt"
$cacert = "cacerts"

$year = (Get-Date).Year

foreach($Server in $Servers) {
    $serverName = $Server.guest.hostname
	$destPath = "\\$serverName\d$\Apache24\conf"
	$backupPath = "\\$serverName\d$\Apache24\conf_$year"
	$javaDir = "\\$serverName\C$\Program Files\Java\jdk1.8.0_181\jre\lib\security"
    write-host "`n *** Beginning $serverName ***`n" -BackgroundColor DarkGreen
	copy-item -recurse $destPath $backupPath

    #httpd.conf
    $httpdPaths = @("$destPath\httpd.conf",
					"$destPath\httpd-custom.conf")

	$searchStrings = @(
		@("c2gkeystore.crt", $Cert),
		@("c2gkeystore.key", $Key),
		@("DigiCertCA.crt", $Intermediate),
		@("DigicertTrustedRoot.crt", $TrustedRoot)
	)

	foreach ($httpdPath in $httpdPaths) {
		foreach ($searchString in $searchStrings){ 
			$searchStringValue = $searchString[0]
			$searchStringReplace = $searchString[1]
			if(Test-Path -Path $httpdPath -PathType Leaf) {
				$httpdContent = Get-Content -Path $httpdPath
		
				$found = $httpdContent | Select-String -Pattern $searchStringValue
		
			# Look for star_aspgov_com in httpd-.conf, if found change it to c2gkeystore
				if ($found) {
					$newContent = $httpdContent -replace $searchStringValue, $searchStringReplace
					Set-Content -Path $httpdPath -Value $newContent
				}	

				else {
					Write-Host "The search string was not found. $searchStringValue $serverName" -BackgroundColor Yellow -ForegroundColor Red
				}
			}

			else {
			write-host "File is not found on: $serverName" -BackgroundColor Red
			}
		}
	}

		# Copy new key and crt over
		Copy-Item -Path "$certSourceDir\$Cert" -Destination "$destPath\$Cert" -Force
		Copy-Item -Path "$certSourceDir\$Key" -Destination "$destPath\$Key" -Force
		Copy-Item -Path "$certSourceDir\$Intermediate" -Destination "$destPath\$Intermediate" -Force
		Copy-Item -Path "$certSourceDir\$TrustedRoot" -Destination "$destPath\$TrustedRoot" -Force
		Copy-Item -Path "$javaDir\$cacert" -Destination "$javaDir\$cacert_$year" -Force
		Copy-Item -Path "$certSourceDir\$cacert" -Destination "$javaDir\$cacert" -Force
       
        write-host "`n *** Ending $serverName ***`n" -BackgroundColor DarkRed
}

foreach ($VIServer in $VIServerList) { disconnect-viserver $VIServer -confirm:$false }
Stop-Transcript