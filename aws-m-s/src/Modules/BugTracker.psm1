#requires -version 7.0
<#
.SYNOPSIS
    Bug Tracker Module for AWS Management Studio

.DESCRIPTION
    Allows users to report bugs directly from within the application
#>

Set-StrictMode -Version Latest

# Import SMB Share Integration
Import-Module "$PSScriptRoot\SMBShareIntegration.psm1" -Force

# Bug storage
$script:BugReportsPath = Join-Path $env:APPDATA 'AWS-EC2-Management-Studio-WPF\bug-reports.json'
$script:BugReportPanel = $null

function New-BugReport {
    <#
    .SYNOPSIS
        Submit a bug report from within the application
    #>
    param(
        [string]$Title,
        [string]$Description,
        [string]$StepsToReproduce = "",
        [string]$ExpectedBehavior = "",
        [string]$ActualBehavior = "",
        [string]$Severity = "Medium",
        [string[]]$Screenshots = @()
    )
    
    # Process screenshots - copy to bug reports folder
    $processedScreenshots = @()
    if ($Screenshots.Count -gt 0) {
        $bugReportsDir = Split-Path $script:BugReportsPath -Parent
        $screenshotsDir = Join-Path $bugReportsDir "screenshots"
        
        if (-not (Test-Path $screenshotsDir)) {
            try {
                New-Item -ItemType Directory -Path $screenshotsDir -Force | Out-Null
            } catch {
                Write-Warning "Failed to create screenshots directory: $($_.Exception.Message)"
                # Fall back to storing original paths if directory creation fails
                $processedScreenshots = $Screenshots
            }
        }
        
        foreach ($screenshot in $Screenshots) {
            if (Test-Path $screenshot) {
                try {
                    $fileName = "bug-$(Get-Date -Format 'yyyyMMdd-HHmmss')-$([System.IO.Path]::GetFileName($screenshot))"
                    $destPath = Join-Path $screenshotsDir $fileName
                    Copy-Item $screenshot $destPath -Force
                    $processedScreenshots += $destPath
                    Write-Verbose "Screenshot copied: $screenshot -> $destPath"
                } catch {
                    Write-Warning "Failed to copy screenshot '$screenshot': $($_.Exception.Message)"
                    # Keep original path if copy fails
                    $processedScreenshots += $screenshot
                }
            } else {
                Write-Warning "Screenshot file not found: $screenshot"
            }
        }
    }
    
    $bugReport = @{
        Id = [System.Guid]::NewGuid().ToString().Substring(0, 8)
        Title = $Title
        Description = $Description
        StepsToReproduce = $StepsToReproduce
        ExpectedBehavior = $ExpectedBehavior
        ActualBehavior = $ActualBehavior
        Severity = $Severity
        Status = "Open"
        SubmittedBy = $env:USERNAME
        SubmittedDate = Get-Date
        Version = "6.0.8"
        Screenshots = $processedScreenshots
        Environment = @{
            PowerShellVersion = $PSVersionTable.PSVersion.ToString()
            OSVersion = [System.Environment]::OSVersion.ToString()
            MachineName = $env:COMPUTERNAME
        }
    }
    
    # Load existing reports
    $existingReports = @()
    if (Test-Path $script:BugReportsPath) {
        try {
            $existingReports = Get-Content $script:BugReportsPath -Raw | ConvertFrom-Json
        } catch {
            Write-Warning "Failed to load existing bug reports"
        }
    }
    
    # Add new report
    $existingReports += $bugReport
    
    # Save reports locally
    try {
        $existingReports | ConvertTo-Json -Depth 10 | Set-Content $script:BugReportsPath -Encoding UTF8
        Write-Verbose "Bug report submitted locally: $($bugReport.Id) - $Title"
        
        # Also save to SMB share for team visibility
        $smbSaved = Save-BugReportToSMB -BugReport $bugReport
        if ($smbSaved) {
            Write-Host "✓ Bug report shared with team via network" -ForegroundColor Green
        } else {
            Write-Verbose "Bug report saved locally only (network share unavailable)"
        }
        
        return $bugReport.Id
    } catch {
        Write-Warning "Failed to save bug report: $($_.Exception.Message)"
        return $null
    }
}

function Get-BugReports {
    <#
    .SYNOPSIS
        Get all bug reports
    #>
    if (Test-Path $script:BugReportsPath) {
        try {
            return Get-Content $script:BugReportsPath -Raw | ConvertFrom-Json
        } catch {
            Write-Warning "Failed to load bug reports"
            return @()
        }
    }
    return @()
}

function Show-BugReportDialog {
    <#
    .SYNOPSIS
        Show bug report submission dialog with screenshot support
    #>
    $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Report Bug - AWS Management Studio" Height="650" Width="700"
        WindowStartupLocation="CenterOwner" ResizeMode="CanResize">
    <Grid Margin="15">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        
        <Label Grid.Row="0" Content="Bug Title:" FontWeight="Bold"/>
        <TextBox Grid.Row="1" Name="txtTitle" Height="25" Margin="0,0,0,10"/>
        
        <Label Grid.Row="2" Content="Description:" FontWeight="Bold"/>
        <TextBox Grid.Row="3" Name="txtDescription" TextWrapping="Wrap" AcceptsReturn="True" 
                 VerticalScrollBarVisibility="Auto" Height="80" Margin="0,0,0,10"/>
        
        <Label Grid.Row="4" Content="Steps to Reproduce:" FontWeight="Bold"/>
        <TextBox Grid.Row="5" Name="txtSteps" TextWrapping="Wrap" AcceptsReturn="True"
                 VerticalScrollBarVisibility="Auto" Height="80" Margin="0,0,0,10"/>
        
        <StackPanel Grid.Row="6" Orientation="Horizontal" Margin="0,0,0,10">
            <Label Content="Severity:" FontWeight="Bold" VerticalAlignment="Center"/>
            <ComboBox Name="cmbSeverity" Width="100" SelectedIndex="1">
                <ComboBoxItem Content="Low"/>
                <ComboBoxItem Content="Medium"/>
                <ComboBoxItem Content="High"/>
                <ComboBoxItem Content="Critical"/>
            </ComboBox>
        </StackPanel>
        
        <StackPanel Grid.Row="7" Margin="0,0,0,15">
            <Label Content="Screenshots (Optional):" FontWeight="Bold"/>
            <TextBlock Text="• Attach existing images or take app-only screenshots" FontSize="10" Foreground="Gray" Margin="0,0,0,5"/>
            <TextBlock Text="• Max 10MB per file • Supported: PNG, JPG, JPEG, BMP, GIF" FontSize="10" Foreground="Gray" Margin="0,0,0,5"/>
            <StackPanel Orientation="Horizontal" Margin="0,5,0,5">
                <Button Name="btnAddScreenshot" Content="📎 Attach Files" Width="100" Height="30" Margin="0,0,10,0" ToolTip="Select existing image files from your computer"/>
                <Button Name="btnTakeScreenshot" Content="📸 App Screenshot" Width="120" Height="30" Margin="0,0,10,0" ToolTip="Capture application window only (secure)"/>
                <Button Name="btnRemoveScreenshot" Content="🗑️ Remove" Width="80" Height="30" ToolTip="Remove selected screenshot"/>
            </StackPanel>
            <ListBox Name="lstScreenshots" Height="80" Margin="0,5,0,0" ToolTip="Attached screenshots will be included with your bug report"/>
        </StackPanel>
        
        <StackPanel Grid.Row="8" Orientation="Horizontal" HorizontalAlignment="Right">
            <Button Name="btnSubmit" Content="Submit Bug Report" Width="120" Height="30" Margin="0,0,10,0"/>
            <Button Name="btnCancel" Content="Cancel" Width="80" Height="30"/>
        </StackPanel>
    </Grid>
</Window>
'@
    
    try {
        $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($xaml))
        $dialog = [Windows.Markup.XamlReader]::Load($reader)
        
        $txtTitle = $dialog.FindName('txtTitle')
        $txtDescription = $dialog.FindName('txtDescription')
        $txtSteps = $dialog.FindName('txtSteps')
        $cmbSeverity = $dialog.FindName('cmbSeverity')
        $lstScreenshots = $dialog.FindName('lstScreenshots')
        $btnAddScreenshot = $dialog.FindName('btnAddScreenshot')
        $btnTakeScreenshot = $dialog.FindName('btnTakeScreenshot')
        $btnRemoveScreenshot = $dialog.FindName('btnRemoveScreenshot')
        $btnSubmit = $dialog.FindName('btnSubmit')
        $btnCancel = $dialog.FindName('btnCancel')
        
        # Screenshot management
        $screenshots = @()
        
        $btnAddScreenshot.Add_Click({
            $openFileDialog = New-Object Microsoft.Win32.OpenFileDialog
            $openFileDialog.Filter = "Image files (*.png;*.jpg;*.jpeg;*.bmp;*.gif)|*.png;*.jpg;*.jpeg;*.bmp;*.gif"
            $openFileDialog.Multiselect = $true
            $openFileDialog.Title = "Select Screenshots (Max 10MB each)"
            
            if ($openFileDialog.ShowDialog() -eq $true) {
                $validFiles = @()
                $invalidFiles = @()
                
                foreach ($file in $openFileDialog.FileNames) {
                    if ($screenshots -notcontains $file) {
                        $validation = Test-ImageFile -FilePath $file
                        if ($validation.Valid) {
                            $screenshots += $file
                            $lstScreenshots.Items.Add("✓ $([System.IO.Path]::GetFileName($file))")
                            $validFiles += [System.IO.Path]::GetFileName($file)
                        } else {
                            $invalidFiles += "$([System.IO.Path]::GetFileName($file)): $($validation.Message)"
                        }
                    }
                }
                
                # Show validation results
                if ($invalidFiles.Count -gt 0) {
                    $message = "Some files were not added:`n`n" + ($invalidFiles -join "`n")
                    if ($validFiles.Count -gt 0) {
                        $message += "`n`nValid files added: $($validFiles.Count)"
                    }
                    [System.Windows.MessageBox]::Show($message, "File Validation", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
                } elseif ($validFiles.Count -gt 0) {
                    # Only show success if no invalid files
                    $lstScreenshots.ToolTip = "$($validFiles.Count) screenshot(s) attached"
                }
            }
        })
        
        $btnTakeScreenshot.Add_Click({
            try {
                # Show security notice for first screenshot
                if ($screenshots.Count -eq 0) {
                    $result = [System.Windows.MessageBox]::Show("This will capture only the application window for security.`n`nNo desktop or other application content will be included.`n`nProceed?", "Secure Screenshot", [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Information)
                    if ($result -eq [System.Windows.MessageBoxResult]::No) {
                        return
                    }
                }
                
                $screenshot = New-ApplicationScreenshot
                if ($screenshot) {
                    $validation = Test-ImageFile -FilePath $screenshot
                    if ($validation.Valid) {
                        $screenshots += $screenshot
                        $lstScreenshots.Items.Add("📸 $([System.IO.Path]::GetFileName($screenshot))")
                        $lstScreenshots.ToolTip = "$($screenshots.Count) screenshot(s) attached"
                    } else {
                        [System.Windows.MessageBox]::Show("Screenshot validation failed: $($validation.Message)", "Screenshot Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
                    }
                } else {
                    [System.Windows.MessageBox]::Show("Failed to capture screenshot. Please try again or attach an existing image file.", "Screenshot Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
                }
            } catch {
                [System.Windows.MessageBox]::Show("Failed to take screenshot: $($_.Exception.Message)", "Screenshot Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
            }
        })
        
        $btnRemoveScreenshot.Add_Click({
            if ($lstScreenshots.SelectedIndex -ge 0) {
                $index = $lstScreenshots.SelectedIndex
                $screenshots = $screenshots | Where-Object { $_ -ne $screenshots[$index] }
                $lstScreenshots.Items.RemoveAt($index)
            }
        })
        
        $btnSubmit.Add_Click({
            if ($txtTitle.Text.Trim()) {
                $severity = $cmbSeverity.SelectedItem.Content
                $bugId = New-BugReport -Title $txtTitle.Text.Trim() -Description $txtDescription.Text.Trim() -StepsToReproduce $txtSteps.Text.Trim() -Severity $severity -Screenshots $screenshots
                
                if ($bugId) {
                    $screenshotCount = $screenshots.Count
                    $message = "Bug report submitted successfully!`nBug ID: $bugId"
                    if ($screenshotCount -gt 0) {
                        $message += "`nScreenshots attached: $screenshotCount"
                    }
                    [System.Windows.MessageBox]::Show($message, "Bug Report Submitted", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
                    $dialog.DialogResult = $true
                } else {
                    [System.Windows.MessageBox]::Show("Failed to submit bug report. Please try again.", "Submission Failed", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
                }
            } else {
                [System.Windows.MessageBox]::Show("Please enter a bug title.", "Missing Information", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
            }
        })
        
        $btnCancel.Add_Click({
            $dialog.DialogResult = $false
        })
        
        return $dialog.ShowDialog()
    } catch {
        Write-Warning "Failed to show bug report dialog: $($_.Exception.Message)"
        return $false
    }
}

function Test-ImageFile {
    <#
    .SYNOPSIS
        Validate image file for bug report attachment
    #>
    param([string]$FilePath)
    
    if (-not (Test-Path $FilePath)) {
        return @{ Valid = $false; Message = "File not found" }
    }
    
    $file = Get-Item $FilePath
    $maxSize = 10MB  # 10MB limit
    $allowedExtensions = @('.png', '.jpg', '.jpeg', '.bmp', '.gif')
    
    # Check file size
    if ($file.Length -gt $maxSize) {
        return @{ Valid = $false; Message = "File too large (max 10MB). Current size: $([math]::Round($file.Length/1MB, 2))MB" }
    }
    
    # Check extension
    $extension = $file.Extension.ToLower()
    if ($extension -notin $allowedExtensions) {
        return @{ Valid = $false; Message = "Invalid file type. Allowed: PNG, JPG, JPEG, BMP, GIF" }
    }
    
    # Try to validate as image
    try {
        Add-Type -AssemblyName System.Drawing
        $image = [System.Drawing.Image]::FromFile($FilePath)
        $width = $image.Width
        $height = $image.Height
        $image.Dispose()
        
        # Check minimum dimensions
        if ($width -lt 50 -or $height -lt 50) {
            return @{ Valid = $false; Message = "Image too small (minimum 50x50 pixels)" }
        }
        
        return @{ Valid = $true; Message = "Valid image file ($width x $height)" }
    } catch {
        return @{ Valid = $false; Message = "Not a valid image file or corrupted" }
    }
}

function New-ApplicationScreenshot {
    <#
    .SYNOPSIS
        Take a screenshot of only the application window for security
    #>
    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        
        # Find the main application window
        $mainWindow = $null
        if ($global:Window) {
            $mainWindow = $global:Window
        } else {
            Write-Warning "Main application window not found, taking full screen"
            return New-FullScreenshot
        }
        
        # Get window bounds in screen coordinates
        $windowBounds = New-Object System.Windows.Rect
        $windowBounds = $mainWindow.RestoreBounds
        if ($windowBounds.IsEmpty) {
            $windowBounds = New-Object System.Windows.Rect($mainWindow.Left, $mainWindow.Top, $mainWindow.ActualWidth, $mainWindow.ActualHeight)
        }
        
        # Convert to screen coordinates
        $left = [int]$windowBounds.Left
        $top = [int]$windowBounds.Top
        $width = [int]$windowBounds.Width
        $height = [int]$windowBounds.Height
        
        # Ensure bounds are valid
        if ($width -le 0 -or $height -le 0) {
            Write-Warning "Invalid window bounds, taking full screen"
            return New-FullScreenshot
        }
        
        # Create bitmap for window area only
        $bitmap = New-Object System.Drawing.Bitmap($width, $height)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        
        # Capture only the application window area
        $graphics.CopyFromScreen($left, $top, 0, 0, [System.Drawing.Size]::new($width, $height))
        
        # Save to temp file
        $tempDir = Join-Path $env:TEMP "AWS-EC2-Management-Studio-Screenshots"
        if (-not (Test-Path $tempDir)) {
            New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        }
        
        $fileName = "app-screenshot-$(Get-Date -Format 'yyyyMMdd-HHmmss').png"
        $filePath = Join-Path $tempDir $fileName
        
        $bitmap.Save($filePath, [System.Drawing.Imaging.ImageFormat]::Png)
        
        # Cleanup
        $graphics.Dispose()
        $bitmap.Dispose()
        
        Write-Verbose "Application screenshot captured: $filePath ($width x $height)"
        return $filePath
    } catch {
        Write-Warning "Failed to take application screenshot: $($_.Exception.Message)"
        # Fallback to full screen if application capture fails
        return New-FullScreenshot
    }
}

function New-FullScreenshot {
    <#
    .SYNOPSIS
        Take a full screen screenshot (fallback method)
    #>
    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        
        # Get screen bounds
        $screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
        $bitmap = New-Object System.Drawing.Bitmap($screen.Width, $screen.Height)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        
        # Capture screen
        $graphics.CopyFromScreen($screen.Location, [System.Drawing.Point]::Empty, $screen.Size)
        
        # Save to temp file
        $tempDir = Join-Path $env:TEMP "AWS-EC2-Management-Studio-Screenshots"
        if (-not (Test-Path $tempDir)) {
            New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        }
        
        $fileName = "screenshot-$(Get-Date -Format 'yyyyMMdd-HHmmss').png"
        $filePath = Join-Path $tempDir $fileName
        
        $bitmap.Save($filePath, [System.Drawing.Imaging.ImageFormat]::Png)
        
        # Cleanup
        $graphics.Dispose()
        $bitmap.Dispose()
        
        Write-Verbose "Full screenshot captured: $filePath"
        return $filePath
    } catch {
        Write-Warning "Failed to take screenshot: $($_.Exception.Message)"
        return $null
    }
}

# Alias for backward compatibility
function New-Screenshot {
    return New-ApplicationScreenshot
}

function Show-BugReportViewer {
    <#
    .SYNOPSIS
        Show bug report viewer with screenshot support
    #>
    $reports = Get-BugReports
    if ($reports.Count -eq 0) {
        [System.Windows.MessageBox]::Show("No bug reports found.", "Bug Reports", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
        return
    }
    
    $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Bug Reports - AWS Management Studio" Height="600" Width="900"
        WindowStartupLocation="CenterOwner" ResizeMode="CanResize">
    <Grid Margin="10">
        <Grid.ColumnDefinitions>
            <ColumnDefinition Width="300"/>
            <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        
        <StackPanel Grid.Column="0" Margin="0,0,10,0">
            <Label Content="Bug Reports:" FontWeight="Bold"/>
            <ListBox Name="lstBugReports" Height="500"/>
        </StackPanel>
        
        <StackPanel Grid.Column="1">
            <StackPanel Orientation="Horizontal" Margin="0,0,0,10">
                <Label Content="Bug Details:" FontWeight="Bold" VerticalAlignment="Center"/>
                <ComboBox Name="cmbStatus" Width="100" Margin="10,0,0,0">
                    <ComboBoxItem Content="Open"/>
                    <ComboBoxItem Content="In Progress"/>
                    <ComboBoxItem Content="Resolved"/>
                    <ComboBoxItem Content="Closed"/>
                    <ComboBoxItem Content="Duplicate"/>
                </ComboBox>
                <Button Name="btnUpdateStatus" Content="Update Status" Width="100" Height="25" Margin="10,0,0,0"/>
            </StackPanel>
            <ScrollViewer Height="460" VerticalScrollBarVisibility="Auto">
                <StackPanel Name="pnlDetails" Margin="10"/>
            </ScrollViewer>
        </StackPanel>
    </Grid>
</Window>
'@
    
    try {
        $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($xaml))
        $viewer = [Windows.Markup.XamlReader]::Load($reader)
        
        $lstBugReports = $viewer.FindName('lstBugReports')
        $pnlDetails = $viewer.FindName('pnlDetails')
        $cmbStatus = $viewer.FindName('cmbStatus')
        $btnUpdateStatus = $viewer.FindName('btnUpdateStatus')
        
        $selectedBugId = $null
        
        # Populate bug reports list
        foreach ($report in $reports) {
            $listItem = "[$($report.Id)] $($report.Title) - $($report.Status) ($($report.Severity))"
            $lstBugReports.Items.Add($listItem)
        }
        
        # Handle selection change
        $lstBugReports.Add_SelectionChanged({
            if ($lstBugReports.SelectedIndex -ge 0) {
                $selectedReport = $reports[$lstBugReports.SelectedIndex]
                $script:selectedBugId = $selectedReport.Id
                $pnlDetails.Children.Clear()
                
                # Update status combo box
                $statusIndex = switch ($selectedReport.Status) {
                    "Open" { 0 }
                    "In Progress" { 1 }
                    "Resolved" { 2 }
                    "Closed" { 3 }
                    "Duplicate" { 4 }
                    default { 0 }
                }
                $cmbStatus.SelectedIndex = $statusIndex
                
                # Add report details
                $details = @(
                    "ID: $($selectedReport.Id)",
                    "Title: $($selectedReport.Title)",
                    "Status: $($selectedReport.Status)",
                    "Severity: $($selectedReport.Severity)",
                    "Submitted By: $($selectedReport.SubmittedBy)",
                    "Date: $($selectedReport.SubmittedDate)",
                    "Version: $($selectedReport.Version)",
                    "",
                    "Description:",
                    $selectedReport.Description,
                    "",
                    "Steps to Reproduce:",
                    $selectedReport.StepsToReproduce
                )
                
                foreach ($detail in $details) {
                    $textBlock = New-Object System.Windows.Controls.TextBlock
                    $textBlock.Text = $detail
                    $textBlock.TextWrapping = "Wrap"
                    $textBlock.Margin = "0,2,0,2"
                    if ($detail.StartsWith("ID:") -or $detail.StartsWith("Title:") -or $detail.StartsWith("Description:") -or $detail.StartsWith("Steps:")) {
                        $textBlock.FontWeight = "Bold"
                    }
                    $pnlDetails.Children.Add($textBlock)
                }
                
                # Add screenshots if available
                if ($selectedReport.Screenshots -and $selectedReport.Screenshots.Count -gt 0) {
                    $screenshotLabel = New-Object System.Windows.Controls.TextBlock
                    $screenshotLabel.Text = "Screenshots:"
                    $screenshotLabel.FontWeight = "Bold"
                    $screenshotLabel.Margin = "0,10,0,5"
                    $pnlDetails.Children.Add($screenshotLabel)
                    
                    foreach ($screenshot in $selectedReport.Screenshots) {
                        if (Test-Path $screenshot) {
                            try {
                                $image = New-Object System.Windows.Controls.Image
                                $bitmap = New-Object System.Windows.Media.Imaging.BitmapImage
                                $bitmap.BeginInit()
                                $bitmap.UriSource = [System.Uri]::new($screenshot)
                                $bitmap.DecodePixelWidth = 400  # Resize for display
                                $bitmap.EndInit()
                                $image.Source = $bitmap
                                $image.Margin = "0,5,0,5"
                                $image.HorizontalAlignment = "Left"
                                $pnlDetails.Children.Add($image)
                                
                                $fileName = New-Object System.Windows.Controls.TextBlock
                                $fileName.Text = [System.IO.Path]::GetFileName($screenshot)
                                $fileName.FontSize = 10
                                $fileName.Foreground = "Gray"
                                $fileName.Margin = "0,0,0,10"
                                $pnlDetails.Children.Add($fileName)
                            } catch {
                                $errorText = New-Object System.Windows.Controls.TextBlock
                                $errorText.Text = "Error loading screenshot: $([System.IO.Path]::GetFileName($screenshot))"
                                $errorText.Foreground = "Red"
                                $errorText.Margin = "0,5,0,5"
                                $pnlDetails.Children.Add($errorText)
                            }
                        }
                    }
                }
            }
        })
        
        # Handle status update
        $btnUpdateStatus.Add_Click({
            if ($script:selectedBugId -and $cmbStatus.SelectedItem) {
                $newStatus = $cmbStatus.SelectedItem.Content
                $success = Set-BugReportStatus -BugId $script:selectedBugId -NewStatus $newStatus
                if ($success) {
                    # Refresh the list
                    $reports = Get-BugReports
                    $lstBugReports.Items.Clear()
                    foreach ($report in $reports) {
                        $listItem = "[$($report.Id)] $($report.Title) - $($report.Status) ($($report.Severity))"
                        $lstBugReports.Items.Add($listItem)
                    }
                    # Reselect the updated item
                    for ($i = 0; $i -lt $reports.Count; $i++) {
                        if ($reports[$i].Id -eq $script:selectedBugId) {
                            $lstBugReports.SelectedIndex = $i
                            break
                        }
                    }
                }
            }
        })
        
        # Select first item if available
        if ($lstBugReports.Items.Count -gt 0) {
            $lstBugReports.SelectedIndex = 0
        }
        
        $viewer.ShowDialog()
    } catch {
        Write-Warning "Failed to show bug report viewer: $($_.Exception.Message)"
    }
}

function Switch-BugReportPanel {
    <#
    .SYNOPSIS
        Toggle bug report panel using configurable framework
    #>
    $configPath = "$PSScriptRoot\..\Config\panels\bug-report.json"
    $screenshots = @()
    
    $eventHandlers = @{
        'submitBug' = {
            param($controls, $dataContext)
            
            if ($controls['txtTitle'].Text.Trim()) {
                $severity = $controls['cmbSeverity'].SelectedItem
                $bugId = New-BugReport -Title $controls['txtTitle'].Text.Trim() -Description $controls['txtDescription'].Text.Trim() -StepsToReproduce $controls['txtSteps'].Text.Trim() -Severity $severity -Screenshots $script:PanelScreenshots
                
                if ($bugId) {
                    $screenshotCount = $script:PanelScreenshots.Count
                    $message = "Bug report submitted!`nID: $bugId"
                    if ($screenshotCount -gt 0) {
                        $message += "`nAttachments: $screenshotCount"
                    }
                    [System.Windows.MessageBox]::Show($message, "Success", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
                    
                    # Clear form
                    $controls['txtTitle'].Text = ""
                    $controls['txtDescription'].Text = ""
                    $controls['txtSteps'].Text = ""
                    $controls['cmbSeverity'].SelectedIndex = 1
                    $script:PanelScreenshots = @()
                    Update-ScreenshotButtons
                } else {
                    [System.Windows.MessageBox]::Show("Failed to submit bug report.", "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
                }
            } else {
                [System.Windows.MessageBox]::Show("Please enter a bug title.", "Missing Info", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
            }
        }
    }
    
    $result = New-ConfigurablePanel -ConfigPath $configPath -EventHandlers $eventHandlers
    
    if ($result -and $result.Controls) {
        # Initialize screenshot tracking
        $script:PanelScreenshots = @()
        
        # Add screenshot button handler
        $result.Controls['btnTakeScreenshot'].Add_Click({
            try {
                # Show security notice for first screenshot
                if ($script:PanelScreenshots.Count -eq 0) {
                    $securityResult = [System.Windows.MessageBox]::Show("This will capture only the application window for security.`n`nNo desktop or other application content will be included.`n`nProceed?", "Secure Screenshot", [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Information)
                    if ($securityResult -eq [System.Windows.MessageBoxResult]::No) {
                        return
                    }
                }
                
                $screenshot = New-ApplicationScreenshot
                if ($screenshot) {
                    $validation = Test-ImageFile -FilePath $screenshot
                    if ($validation.Valid) {
                        $script:PanelScreenshots += $screenshot
                        Update-ScreenshotButtons
                    } else {
                        [System.Windows.MessageBox]::Show("Screenshot validation failed: $($validation.Message)", "Screenshot Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
                    }
                } else {
                    [System.Windows.MessageBox]::Show("Failed to capture application screenshot. Please try again.", "Screenshot Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
                }
            } catch {
                [System.Windows.MessageBox]::Show("Failed to take screenshot: $($_.Exception.Message)", "Screenshot Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
            }
        }.GetNewClosure())
        
        # Add file attachment handler
        if ($result.Controls.ContainsKey('btnAttachFile')) {
            $result.Controls['btnAttachFile'].Add_Click({
                try {
                    $openFileDialog = New-Object Microsoft.Win32.OpenFileDialog
                    $openFileDialog.Filter = "Image files (*.png;*.jpg;*.jpeg;*.bmp;*.gif)|*.png;*.jpg;*.jpeg;*.bmp;*.gif"
                    $openFileDialog.Multiselect = $true
                    $openFileDialog.Title = "Select Image Files (Max 10MB each)"
                    
                    if ($openFileDialog.ShowDialog() -eq $true) {
                        $validFiles = @()
                        $invalidFiles = @()
                        
                        foreach ($file in $openFileDialog.FileNames) {
                            if ($script:PanelScreenshots -notcontains $file) {
                                $validation = Test-ImageFile -FilePath $file
                                if ($validation.Valid) {
                                    $script:PanelScreenshots += $file
                                    $validFiles += [System.IO.Path]::GetFileName($file)
                                } else {
                                    $invalidFiles += "$([System.IO.Path]::GetFileName($file)): $($validation.Message)"
                                }
                            }
                        }
                        
                        Update-ScreenshotButtons
                        
                        # Show validation results
                        if ($invalidFiles.Count -gt 0) {
                            $message = "Some files were not added:`n`n" + ($invalidFiles -join "`n")
                            if ($validFiles.Count -gt 0) {
                                $message += "`n`nValid files added: $($validFiles.Count)"
                            }
                            [System.Windows.MessageBox]::Show($message, "File Validation", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
                        }
                    }
                } catch {
                    [System.Windows.MessageBox]::Show("Failed to attach files: $($_.Exception.Message)", "Attachment Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
                }
            }.GetNewClosure())
        }
        
        # Helper function to update button text
        function Update-ScreenshotButtons {
            $count = $script:PanelScreenshots.Count
            if ($count -gt 0) {
                $result.Controls['btnTakeScreenshot'].Content = "📸 Screenshots ($count)"
                if ($result.Controls.ContainsKey('btnAttachFile')) {
                    $result.Controls['btnAttachFile'].Content = "📎 Files ($count)"
                }
            } else {
                $result.Controls['btnTakeScreenshot'].Content = "📸 App Screenshot"
                if ($result.Controls.ContainsKey('btnAttachFile')) {
                    $result.Controls['btnAttachFile'].Content = "📎 Attach File"
                }
            }
        }
    }
}



function Set-BugReportStatus {
    <#
    .SYNOPSIS
        Update the status of a bug report
    #>
    param(
        [string]$BugId,
        [ValidateSet("Open", "In Progress", "Resolved", "Closed", "Duplicate")]
        [string]$NewStatus
    )
    
    $reports = Get-BugReports
    $targetReport = $reports | Where-Object { $_.Id -eq $BugId }
    
    if (-not $targetReport) {
        Write-Warning "Bug report with ID '$BugId' not found"
        return $false
    }
    
    # Update status
    $targetReport.Status = $NewStatus
    $targetReport.LastModified = Get-Date
    
    # Save updated reports
    try {
        $reports | ConvertTo-Json -Depth 10 | Set-Content $script:BugReportsPath -Encoding UTF8
        Write-Host "Bug $BugId status updated to: $NewStatus" -ForegroundColor Green
        return $true
    } catch {
        Write-Warning "Failed to update bug report: $($_.Exception.Message)"
        return $false
    }
}

function Stop-BugReport {
    <#
    .SYNOPSIS
        Close a bug report
    #>
    param([string]$BugId)
    return Set-BugReportStatus -BugId $BugId -NewStatus "Closed"
}

function Restore-BugReportScreenshots {
    <#
    .SYNOPSIS
        Recover screenshots for bug reports that may have lost their screenshot references
    #>
    param(
        [string]$BugId
    )
    
    $reports = Get-BugReports
    $targetReport = $reports | Where-Object { $_.Id -eq $BugId }
    
    if (-not $targetReport) {
        Write-Warning "Bug report with ID '$BugId' not found"
        return
    }
    
    # Check temp screenshot directory for screenshots around the submission time
    $tempScreenshotsDir = Join-Path $env:TEMP "AWS-EC2-Management-Studio-Screenshots"
    if (Test-Path $tempScreenshotsDir) {
        $submissionDate = [DateTime]::Parse($targetReport.SubmittedDate)
        $screenshots = Get-ChildItem $tempScreenshotsDir -Filter "*.png" | Where-Object {
            $_.CreationTime -ge $submissionDate.AddMinutes(-10) -and
            $_.CreationTime -le $submissionDate.AddMinutes(10)
        }
        
        if ($screenshots.Count -gt 0) {
            Write-Host "Found $($screenshots.Count) potential screenshots for bug ${BugId}:" -ForegroundColor Green
            foreach ($screenshot in $screenshots) {
                Write-Host "  - $($screenshot.Name) (Created: $($screenshot.CreationTime))" -ForegroundColor Cyan
            }
            
            # Show the screenshots
            foreach ($screenshot in $screenshots) {
                try {
                    Start-Process $screenshot.FullName
                } catch {
                    Write-Warning "Failed to open screenshot: $($_.Exception.Message)"
                }
            }
        } else {
            Write-Host "No screenshots found in temp directory for the submission timeframe" -ForegroundColor Yellow
        }
    } else {
        Write-Host "Temp screenshots directory not found" -ForegroundColor Yellow
    }
}

function Export-BugReports {
    <#
    .SYNOPSIS
        Export bug reports to HTML with embedded screenshots
    #>
    param(
        [string]$OutputPath = "bug-reports-$(Get-Date -Format 'yyyyMMdd-HHmmss').html"
    )
    
    $reports = Get-BugReports
    if ($reports.Count -eq 0) {
        Write-Warning "No bug reports to export"
        return
    }
    
    $html = @"
<!DOCTYPE html>
<html>
<head>
    <title>AWS Management Studio - Bug Reports</title>
    <style>
        body { font-family: 'Segoe UI', Arial, sans-serif; margin: 20px; background: #f5f5f5; }
        .header { background: #d13438; color: white; padding: 20px; border-radius: 8px; margin-bottom: 20px; }
        .report { background: white; margin: 20px 0; padding: 20px; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        .report-header { border-bottom: 2px solid #eee; padding-bottom: 10px; margin-bottom: 15px; }
        .severity-critical { border-left: 4px solid #d13438; }
        .severity-high { border-left: 4px solid #ff8c00; }
        .severity-medium { border-left: 4px solid #ffb900; }
        .severity-low { border-left: 4px solid #107c10; }
        .screenshot { max-width: 600px; margin: 10px 0; border: 1px solid #ddd; border-radius: 4px; }
        .meta { color: #666; font-size: 0.9em; }
        .section { margin: 15px 0; }
        .section-title { font-weight: bold; color: #333; margin-bottom: 5px; }
    </style>
</head>
<body>
    <div class="header">
        <h1>🐛 AWS Management Studio - Bug Reports</h1>
        <p>Generated: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss") | Total Reports: $($reports.Count)</p>
    </div>
"@
    
    foreach ($report in $reports) {
        $severityClass = "severity-$($report.Severity.ToLower())"
        $html += @"
    <div class="report $severityClass">
        <div class="report-header">
            <h2>[$($report.Id)] $($report.Title)</h2>
            <div class="meta">
                Status: $($report.Status) | Severity: $($report.Severity) | 
                Submitted by: $($report.SubmittedBy) | Date: $($report.SubmittedDate)
            </div>
        </div>
        
        <div class="section">
            <div class="section-title">Description:</div>
            <p>$($report.Description -replace "`n", "<br>")</p>
        </div>
        
        <div class="section">
            <div class="section-title">Steps to Reproduce:</div>
            <p>$($report.StepsToReproduce -replace "`n", "<br>")</p>
        </div>
"@
        
        if ($report.Screenshots -and $report.Screenshots.Count -gt 0) {
            $html += "        <div class=`"section`">`n            <div class=`"section-title`">Screenshots:</div>`n"
            foreach ($screenshot in $report.Screenshots) {
                if (Test-Path $screenshot) {
                    try {
                        # Convert image to base64 for embedding
                        $imageBytes = [System.IO.File]::ReadAllBytes($screenshot)
                        $base64 = [System.Convert]::ToBase64String($imageBytes)
                        $extension = [System.IO.Path]::GetExtension($screenshot).ToLower()
                        $mimeType = switch ($extension) {
                            ".png" { "image/png" }
                            ".jpg" { "image/jpeg" }
                            ".jpeg" { "image/jpeg" }
                            ".bmp" { "image/bmp" }
                            ".gif" { "image/gif" }
                            default { "image/png" }
                        }
                        
                        $html += "            <img src=`"data:$mimeType;base64,$base64`" class=`"screenshot`" alt=`"Screenshot`" /><br>`n"
                        $html += "            <small>$([System.IO.Path]::GetFileName($screenshot))</small><br><br>`n"
                    } catch {
                        $html += "            <p style=`"color: red;`">Error loading screenshot: $([System.IO.Path]::GetFileName($screenshot))</p>`n"
                    }
                }
            }
            $html += "        </div>`n"
        }
        
        $html += "    </div>`n"
    }
    
    $html += @"
</body>
</html>
"@
    
    try {
        $html | Out-File -FilePath $OutputPath -Encoding UTF8
        Write-Host "Bug reports exported to: $OutputPath" -ForegroundColor Green
        return $OutputPath
    } catch {
        Write-Warning "Failed to export bug reports: $($_.Exception.Message)"
        return $null
    }
}

Export-ModuleMember -Function New-BugReport, Get-BugReports, Show-BugReportDialog, New-Screenshot, New-ApplicationScreenshot, Test-ImageFile, Show-BugReportViewer, Export-BugReports, Switch-BugReportPanel, Restore-BugReportScreenshots, Set-BugReportStatus, Stop-BugReport