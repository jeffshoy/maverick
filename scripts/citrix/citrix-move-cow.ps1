import-module SQLPS
$databases = @(
    'CitrixWESTLogging',
    'CitrixWESTMonitoring',
    'CitrixWESTSite'
)
$SourceServer = 'COW-PXSF001.COW.cloud.lcl'
$DestinationServer = 'COW-PXSF002.COW.cloud.lcl'
$DBInstance = '\SQLEXPRESS'
$BackupPath = 'C:\Temp\Backups'
$BackupPathRemote = 'C$\Temp\Backups'
$StorageFilePath = 'C:\Program Files\Microsoft SQL Server\MSSQL16.SQLEXPRESS\MSSQL\DATA\'
$DestinationServerInstance = $DestinationServer + $DBInstance

function Backup-Database {
    $SourceServerInstance = $SourceServer + $DBInstance
    Backup-SqlDatabase -ServerInstance $SourceServerInstance -Database $database -BackupFile $BackupFilename
}

function Restore-Database {
    if (Test-Path $BackupPath) {
        remove-item $BackupPath -Recurse -Force
    }
    Copy-Item -Recurse \\$SourceServer\$BackupPathRemote $BackupPath
    $LogFileLogical = $database + '_log'
    $RelocateData = New-Object Microsoft.SqlServer.Management.Smo.RelocateFile("$database", "$dataFilePath")
    $RelocateLog = New-Object Microsoft.SqlServer.Management.Smo.RelocateFile("$LogFileLogical", "$logFilePath")
    Restore-SqlDatabase -ServerInstance $DestinationServerInstance -Database $database -BackupFile $BackupFilename -RelocateFile @($RelocateData,$RelocateLog)
}

function Repair-Citrix {
    $ServerName = $DestinationServerInstance
    $SiteDBName = $databases[2]
    $LogDBName = $databases[0]
    $MonitorDBName = $databases[1]
    $csSite = "Server=$ServerName;Initial Catalog=$SiteDBName;Integrated Security=True"
    $csLogging = "Server=$ServerName;Initial Catalog=$LogDBName;Integrated Security=True"
    $csMonitoring = "Server=$ServerName;Initial Catalog=$MonitorDBName;Integrated Security=True"
    $citrixChangesLog = $backupPath + "\citrixChanges.txt"

    Get-ConfigDBConnection >> $citrixChangesLog
    Get-AcctDBConnection >> $citrixChangesLog
    Get-AnalyticsDBConnection >> $citrixChangesLog
    Get-AppLibDBConnection >> $citrixChangesLog
    Get-OrchDBConnection >> $citrixChangesLog
    Get-TrustDBConnection >> $citrixChangesLog
    Get-HypDBConnection >> $citrixChangesLog
    Get-ProvDBConnection >> $citrixChangesLog
    Get-BrokerDBConnection >> $citrixChangesLog
    Get-EnvTestDBConnection >> $citrixChangesLog
    Get-SfDBConnection >> $citrixChangesLog
    Get-MonitorDBConnection >> $citrixChangesLog
    Get-LogDBConnection >> $citrixChangesLog
    Get-AdminDBConnection >> $citrixChangesLog

    Set-ConfigDBConnection -DBConnection $null -Force
    Set-AcctDBConnection -DBConnection $null -Force
    Set-AnalyticsDBConnection -DBConnection $null -Force
    Set-AppLibDBConnection -DBConnection $null -Force
    Set-OrchDBConnection -DBConnection $null -Force
    Set-TrustDBConnection -DBConnection $null -Force
    Set-HypDBConnection -DBConnection $null -Force
    Set-ProvDBConnection -DBConnection $null -Force
    Set-BrokerDBConnection -DBConnection $null
    Set-EnvTestDBConnection -DBConnection $null -Force
    Set-SfDBConnection -DBConnection $null -Force
    Set-MonitorDBConnection -DataStore Monitor -DBConnection $null -Force
    Set-MonitorDBConnection -DBConnection $null -Force
    Set-LogDBConnection -DataStore Logging -DBConnection $null -Force
    Set-LogDBConnection -DBConnection $null -Force
    Set-AdminDBConnection -DBConnection $null -Force

    Set-AdminDBConnection -DBConnection $csSite
    Set-ConfigDBConnection -DBConnection $csSite
    Set-AcctDBConnection -DBConnection $csSite
    Set-AnalyticsDBConnection -DBConnection $csSite
    Set-HypDBConnection -DBConnection $csSite
    Set-ProvDBConnection -DBConnection $csSite
    Set-AppLibDBConnection -DBConnection $csSite
    Set-OrchDBConnection -DBConnection $csSite
    Set-TrustDBConnection -DBConnection $csSite
    Set-BrokerDBConnection -DBConnection $csSite
    Set-EnvTestDBConnection -DBConnection $csSite
    Set-SfDBConnection -DBConnection $csSite
    Set-LogDBConnection -DBConnection $csSite
    Set-LogDBConnection -DataStore Logging -DBConnection $null -Force
    Set-LogDBConnection -DataStore Logging -DBConnection $csLogging
    Set-MonitorDBConnection -DBConnection $csSite
    Set-MonitorDBConnection -DataStore Monitor -DBConnection $null -Force
    Set-MonitorDBConnection -DataStore Monitor -DBConnection $csMonitoring

    Test-AcctDBConnection -DBConnection $csSite >> $citrixChangesLog
    Test-AdminDBConnection -DBConnection $csSite >> $citrixChangesLog
    Test-AnalyticsDBConnection -DBConnection $csSite >> $citrixChangesLog
    Test-AppLibDBConnection -DBConnection $csSite >> $citrixChangesLog
    Test-BrokerDBConnection -DBConnection $csSite >> $citrixChangesLog
    Test-ConfigDBConnection -DBConnection $csSite >> $citrixChangesLog
    Test-EnvTestDBConnection -DBConnection $csSite >> $citrixChangesLog
    Test-HypDBConnection -DBConnection $csSite >> $citrixChangesLog
    Test-LogDBConnection -DBConnection $csSite >> $citrixChangesLog
    Test-LogDBConnection -DataStore Logging -DBConnection $csLogging >> $citrixChangesLog
    Test-MonitorDBConnection -DBConnection $csSite >> $citrixChangesLog
    Test-MonitorDBConnection -Datastore Monitor -DBConnection $csMonitoring >> $citrixChangesLog
    Test-OrchDBConnection -DBConnection $csSite >> $citrixChangesLog
    Test-ProvDBConnection -DBConnection $csSite >> $citrixChangesLog
    Test-SfDBConnection -DBConnection $csSite >> $citrixChangesLog
    Test-TrustDBConnection -DBConnection $csSite >> $citrixChangesLog

    Get-ConfigDBConnection >> $citrixChangesLog
    Get-AcctDBConnection >> $citrixChangesLog
    Get-AnalyticsDBConnection >> $citrixChangesLog
    Get-AppLibDBConnection >> $citrixChangesLog
    Get-OrchDBConnection >> $citrixChangesLog
    Get-TrustDBConnection >> $citrixChangesLog
    Get-HypDBConnection >> $citrixChangesLog
    Get-ProvDBConnection >> $citrixChangesLog
    Get-BrokerDBConnection >> $citrixChangesLog
    Get-EnvTestDBConnection >> $citrixChangesLog
    Get-SfDBConnection >> $citrixChangesLog
    Get-MonitorDBConnection >> $citrixChangesLog
    Get-LogDBConnection >> $citrixChangesLog
    Get-AdminDBConnection >> $citrixChangesLog
}

if (!(test-path $BackupPath)){
    mkdir $BackupPath
}

$action = "backup","restore","FixDatabase" | Out-GridView -PassThru -Title "Choose action"
switch ($action) {
    "backup" { foreach ($database in $databases) {
        $BackupFilename = $BackupPath + "\" + $database + '.bak'
        $dataFilePath = $StorageFilePath + $database + ".mdf"
        $logFilePath = $StorageFilePath + $database + ".ldf"
        Backup-Database
        }
    }
    "restore" { foreach ($database in $databases) {
        $BackupFilename = $BackupPath + "\" + $database + '.bak'
        $dataFilePath = $StorageFilePath + $database + ".mdf"
        $logFilePath = $StorageFilePath + $database + ".ldf"
        Restore-Database
        }
    }
    "FixDatabase" { Repair-Citrix }
    default {write-error "Invalid action, choose either backup, restore, or FixDatabase."}
}
