# SMB Share Integration - Implementation Guide

## Overview

Phase 0.2 implementation providing centralized bug tracking, logging, and distribution via network share for team collaboration.

## Architecture

### SMB Share Structure
```
\\datacenter\tools\aws-management-studio\
├── bugs\
│   ├── open\              # Active bug reports
│   │   ├── bug-*.json     # Individual bug report files
│   │   └── screenshots\   # Bug screenshots
│   ├── resolved\          # Resolved bugs
│   └── archive\           # Archived bugs
├── logs\
│   └── app-log-*.log      # Daily application logs
├── analytics\
│   └── usage-*.json       # Monthly usage analytics
└── releases\
    ├── current\           # Latest stable release
    └── archive\           # Version history
```

## Components

### 1. SMBShareIntegration.psm1 (NEW)
**Location**: `src/Modules/SMBShareIntegration.psm1`

**Functions**:
- `Initialize-SMBShareConfig()` - Load configuration from settings
- `Test-SMBShareAvailability()` - Check network share accessibility (5-min cache)
- `Save-BugReportToSMB()` - Save bug reports to network share
- `Get-BugReportsFromSMB()` - Retrieve team bug reports
- `Move-BugReportStatus()` - Move bugs between status folders
- `Write-SMBLog()` - Centralized logging
- `Send-UsageAnalytics()` - Track usage metrics
- `Get-SMBShareStatus()` - Get current configuration
- `Set-SMBShareConfiguration()` - Configure SMB settings

**Configuration File**: `%APPDATA%\AWS-Management-Studio\smb-config.json`
```json
{
  "Enabled": true,
  "BasePath": "\\\\datacenter\\tools\\aws-management-studio"
}
```

### 2. BugTracker.psm1 (UPDATED)
**Changes**:
- Imports SMBShareIntegration module
- Automatically saves bug reports to SMB share when available
- Falls back to local-only storage if network unavailable
- Provides user feedback on network save status

### 3. SMB Configuration Panel (NEW)
**Location**: `src/Config/panels/smb-config.json`

**Features**:
- Enable/disable SMB integration
- Configure network share path
- Test connection button
- Visual status feedback
- Team features overview

## Usage

### For End Users

#### Submitting Bug Reports
1. Click "Help" → "Report Bug" (or use existing bug report UI)
2. Fill in bug details and attach screenshots
3. Click "Submit Bug Report"
4. Bug is saved locally AND to network share (if available)
5. Confirmation shows whether bug was shared with team

#### Viewing Team Bugs
```powershell
# Get all open bugs from team
Get-BugReportsFromSMB -Status Open

# Get all bugs (open, resolved, archived)
Get-BugReportsFromSMB -Status All
```

### For Administrators

#### Initial Setup
```powershell
# Configure SMB share
Set-SMBShareConfiguration -BasePath "\\datacenter\tools\aws-management-studio" -Enabled $true

# Test connectivity
Test-SMBShareAvailability -Force

# Check status
Get-SMBShareStatus
```

#### Bug Management
```powershell
# Move bug to resolved
Move-BugReportStatus -BugId "abc123" -NewStatus "Resolved"

# Move bug to archive
Move-BugReportStatus -BugId "abc123" -NewStatus "Archive"
```

#### Monitoring
```powershell
# View centralized logs
Get-Content "\\datacenter\tools\aws-management-studio\logs\app-log-20241219.log"

# View usage analytics
Get-Content "\\datacenter\tools\aws-management-studio\analytics\usage-202412.json" | ConvertFrom-Json
```

## Features

### Centralized Bug Tracking
- **Team Visibility**: All team members see reported bugs
- **Status Management**: Move bugs between open/resolved/archive
- **Screenshot Sharing**: Screenshots automatically copied to network share
- **Individual Files**: Each bug is a separate JSON file for easy management

### Shared Logging
- **Daily Log Files**: One log file per day
- **User Context**: Logs include username and machine name
- **Categorized**: Logs organized by level (Info/Warning/Error) and category
- **Centralized**: All team logs in one location for admin review

### Usage Analytics
- **Monthly Tracking**: Usage data aggregated by month
- **Action Tracking**: Records user actions and features used
- **Version Tracking**: Tracks which versions are in use
- **Metadata**: Extensible metadata for custom tracking

### Automatic Fallback
- **Local Storage**: Always saves locally first
- **Network Optional**: Works without network share
- **Cached Availability**: 5-minute cache reduces network checks
- **Silent Failure**: Network issues don't block functionality

## Configuration

### Enable SMB Integration
1. Open application
2. Go to "Settings" or "Tools" → "SMB Configuration"
3. Check "Enable SMB Share Integration"
4. Enter network share path
5. Click "Test Connection"
6. Click "Save Configuration"

### Disable SMB Integration
1. Open SMB Configuration panel
2. Uncheck "Enable SMB Share Integration"
3. Click "Save Configuration"

## Security Considerations

### Network Share Permissions
- **Read/Write Access**: Users need read/write access to bugs, logs, analytics folders
- **Read-Only Access**: Users only need read access to releases folder
- **Admin Access**: Admins need full control for folder management

### Data Privacy
- **User Information**: Bug reports include username and machine name
- **Screenshots**: May contain sensitive information - users should review before submitting
- **Logs**: May contain operational details - restrict access appropriately

### Network Security
- **UNC Paths**: Use standard Windows UNC paths (\\\\server\\share)
- **Authentication**: Uses Windows integrated authentication
- **VPN Required**: Network share should be on corporate network (VPN required for remote access)

## Troubleshooting

### SMB Share Not Available
**Symptoms**: Bug reports only saved locally, no team visibility

**Solutions**:
1. Check network connectivity
2. Verify UNC path is correct
3. Confirm user has read/write permissions
4. Test path in File Explorer: `\\datacenter\tools\aws-management-studio`
5. Check VPN connection if working remotely

### Bug Reports Not Appearing
**Symptoms**: Submitted bugs don't show in team view

**Solutions**:
1. Verify SMB integration is enabled
2. Check `Get-SMBShareStatus` output
3. Look for error messages in application
4. Verify bugs folder exists and is writable
5. Check local bug reports: `%APPDATA%\AWS-EC2-Management-Studio-WPF\bug-reports.json`

### Permission Denied Errors
**Symptoms**: Errors when saving to network share

**Solutions**:
1. Verify user has write permissions to share
2. Check folder permissions (not just share permissions)
3. Ensure folders exist (bugs\open, logs, analytics)
4. Contact IT admin for permission adjustments

## Testing

### Manual Testing
```powershell
# Test module loading
Import-Module .\src\Modules\SMBShareIntegration.psm1 -Force
Get-Command -Module SMBShareIntegration

# Test configuration
Set-SMBShareConfiguration -BasePath "\\datacenter\tools\aws-management-studio" -Enabled $true

# Test connectivity
Test-SMBShareAvailability -Force

# Test bug save
$testBug = @{
    Id = "test123"
    Title = "Test Bug"
    Description = "Testing SMB integration"
    Status = "Open"
    Severity = "Low"
    SubmittedBy = $env:USERNAME
    SubmittedDate = Get-Date
}
Save-BugReportToSMB -BugReport $testBug

# Verify file created
Test-Path "\\datacenter\tools\aws-management-studio\bugs\open\bug-test123-*.json"
```

### Integration Testing
1. Submit bug report through UI
2. Verify local save: Check `%APPDATA%\AWS-EC2-Management-Studio-WPF\bug-reports.json`
3. Verify network save: Check `\\datacenter\tools\aws-management-studio\bugs\open\`
4. Verify screenshots copied to network
5. Test with network share unavailable (should still save locally)

## Future Enhancements

### Phase 0.3 - Admin Features
- Distribution tracking dashboard
- Usage monitoring UI
- Configuration management console
- Remote diagnostics collection

### Phase 1 - Enhanced Features
- Email notifications for new bugs
- Bug assignment and workflow
- Automated bug report aggregation
- Team collaboration features

## Version History

- **v6.4.0** (Planned): Initial SMB share integration implementation
- **v6.3.1** (Current): Local-only bug tracking

## Related Documentation

- [ROADMAP.md](ROADMAP.md) - Phase 0.2 implementation details
- [BugTracker.psm1](../../src/Modules/BugTracker.psm1) - Bug tracking implementation
- [SMBShareIntegration.psm1](../../src/Modules/SMBShareIntegration.psm1) - SMB integration code

---

**Last Updated**: 2024-12-19  
**Status**: Implementation Complete - Ready for Testing  
**Next Steps**: Integration testing and user acceptance testing
