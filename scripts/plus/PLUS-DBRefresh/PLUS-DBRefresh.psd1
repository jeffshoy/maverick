@{
    RootModule        = 'PLUSDBRefreshKit.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '7b2f4c93-8d1e-4f6a-9b3c-5e8f1d2a6c40'
    Author            = 'Cloud SRE'
    CompanyName       = 'CentralSquare Technologies'
    Copyright         = '(c) CentralSquare Technologies. Internal use.'
    Description       = 'Standalone DBA-self-service renderer for PLUS database training/stage refresh SQL. Produces a complete .sql file from local templates without touching SQL Server or network shares.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @('New-PLUSDBRefreshScript')
    AliasesToExport   = @('PLUS_RenderRefresh','pdbrender')
    CmdletsToExport   = @()
    VariablesToExport = @()
    PrivateData = @{
        PSData = @{
            Tags         = @('PLUS','SQL','DBA','Refresh','Training','Stage')
            ReleaseNotes = 'v1.0.0 - Initial release. Renders refresh SQL from bundled templates without touching SQL or network shares.'
        }
    }
}
