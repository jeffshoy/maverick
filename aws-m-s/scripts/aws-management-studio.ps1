#requires -version 7.0
<#
.SYNOPSIS
    AWS Management Studio - Modular Version

.VERSION
    6.2.3 (Enhanced Test Result Display & JSON Export)

.DOCUMENTATION
    All changes must be documented in CHANGELOG.md with specific file paths and function names.
    See CONTRIBUTING.md for detailed documentation standards and git rollback procedures.
    This format enables precise rollbacks and development tracking.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Disable verbose output for clean startup
$VerbosePreference = 'SilentlyContinue'
$DebugPreference = 'SilentlyContinue'

# Trap all errors for detailed reporting
trap {
    Write-Host "[TRAP] Error caught: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "[TRAP] Error type: $($_.Exception.GetType().FullName)" -ForegroundColor Red
    Write-Host "[TRAP] Stack trace: $($_.ScriptStackTrace)" -ForegroundColor Red
    Write-Host "[TRAP] Position: $($_.InvocationInfo.PositionMessage)" -ForegroundColor Red
    continue
}

# Check if running in STA mode (required for WPF)
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    Write-Warning "WPF requires STA threading model. Please run with: pwsh -STA -File $($MyInvocation.MyCommand.Path)"
    Read-Host "Press Enter to exit"
    exit 1
}

# Assembly Imports
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName Microsoft.VisualBasic

# Windows API for console positioning
Add-Type @'
    using System;
    using System.Runtime.InteropServices;
    public class Win32 {
        [DllImport("kernel32.dll")]
        public static extern IntPtr GetConsoleWindow();
        
        [DllImport("user32.dll")]
        public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
        
        [DllImport("user32.dll")]
        public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
        
        [StructLayout(LayoutKind.Sequential)]
        public struct RECT {
            public int Left;
            public int Top;
            public int Right;
            public int Bottom;
        }
        
        public const uint SWP_NOZORDER = 0x0004;
        public const uint SWP_NOACTIVATE = 0x0010;
    }
'@

# Application Constants
$script:AppVersion = "6.2.3"
$script:AppName = "AWS Management Studio"

# Settings paths - Define before importing modules
$script:SettingsDirectory = Join-Path $env:APPDATA 'AWS-Management-Studio'
$script:SettingsFilePath = Join-Path $script:SettingsDirectory 'settings.json'
$script:UserSettingsFile = Join-Path $script:SettingsDirectory 'user-settings.json'
$script:SearchHistoryFile = Join-Path $script:SettingsDirectory 'search-history.json'
$script:FavoritesFile = Join-Path $script:SettingsDirectory 'favorites.json'

# Create settings directory if it doesn't exist
if (-not (Test-Path -LiteralPath $script:SettingsDirectory)) {
    New-Item -ItemType Directory -Path $script:SettingsDirectory -Force | Out-Null
}

# Make version and settings paths available globally for modules
$global:AppVersion = $script:AppVersion
$global:AppName = $script:AppName
$global:SettingsDirectory = $script:SettingsDirectory
$global:SettingsFilePath = $script:SettingsFilePath
$global:UserSettingsFile = $script:UserSettingsFile
$global:SearchHistoryFile = $script:SearchHistoryFile
$global:FavoritesFile = $script:FavoritesFile

# Import modules with warning suppression
Import-Module "$PSScriptRoot\..\src\Modules\Core.psm1" -Force -WarningAction SilentlyContinue
Import-Module "$PSScriptRoot\..\src\Modules\AWS.psm1" -Force -WarningAction SilentlyContinue
# ValidationFix module removed - functionality integrated into other modules
Import-Module "$PSScriptRoot\..\src\Modules\TestFix.psm1" -Force -WarningAction SilentlyContinue
Import-Module "$PSScriptRoot\..\src\Modules\AWSServiceManager.psm1" -Force -WarningAction SilentlyContinue
Import-Module "$PSScriptRoot\..\src\Modules\DebugLogger.psm1" -Force -WarningAction SilentlyContinue
Import-Module "$PSScriptRoot\..\src\Modules\TestRunner.psm1" -Force -WarningAction SilentlyContinue
Import-Module "$PSScriptRoot\..\src\Modules\UI.psm1" -Force -WarningAction SilentlyContinue
Import-Module "$PSScriptRoot\..\src\Modules\MultiServiceSearch.psm1" -Force -WarningAction SilentlyContinue
Import-Module "$PSScriptRoot\..\src\Modules\UniversalAWSDiscovery.psm1" -Force -WarningAction SilentlyContinue
Import-Module "$PSScriptRoot\..\src\Modules\BugTracker.psm1" -Force -WarningAction SilentlyContinue
Import-Module "$PSScriptRoot\..\src\Modules\VersionTracker.psm1" -Force -WarningAction SilentlyContinue
Import-Module "$PSScriptRoot\..\src\Modules\PanelFramework.psm1" -Force -WarningAction SilentlyContinue

# Initialize application
try {
    $global:Settings = Get-Settings
    $global:UserSettings = Get-UserSettings
} catch {
    Write-Warning "Settings initialization failed: $($_.Exception.Message)"
    $global:Settings = Get-DefaultSettings
    $global:UserSettings = Get-DefaultUserSettings
}

# Initialize global variables
$global:LastRefreshTime = $null
$global:UpdatingPanelPosition = $false
$global:DebugMode = $false
$global:OriginalItems = @()  # Initialize as empty array to prevent null access
$global:WindowInitializing = $true  # Flag to prevent event handlers during initialization

# Initialize service search jobs hashtable (required by AWSServiceManager)
$global:ServiceSearchJobs = @{}

# Make script-level variables globally accessible for modules
$global:PendingProfile = $null

# Initialize debug logger
try {
    Initialize-DebugLogger
    Write-DebugLog "Debug logger initialized successfully" "INFO" "Application"
} catch {
    Write-Warning "Debug logger initialization failed: $($_.Exception.Message)"
}

# =========================
#   WPF UI Creation
# =========================
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="AWS Management Studio - Multi-Service Platform" Height="600" Width="800" MinHeight="500" MinWidth="800"
        WindowStartupLocation="CenterScreen">
    <DockPanel>
        <!-- Menu Bar -->
        <Menu DockPanel.Dock="Top" Background="#F0F0F0">
            <MenuItem Header="_File">
                <MenuItem Name="miExit" Header="E_xit" InputGestureText="Alt+F4"/>
            </MenuItem>
            <MenuItem Header="_Edit">
                <MenuItem Name="miClearHistory" Header="Clear Search _History"/>
                <MenuItem Name="miClearFavorites" Header="Clear _Favorites"/>
                <Separator/>
                <MenuItem Name="miPreferences" Header="_Preferences" InputGestureText="Ctrl+,"/>
            </MenuItem>
            <MenuItem Header="_View">
                <MenuItem Name="miRefresh" Header="_Refresh" InputGestureText="F5"/>
                <Separator/>
                <MenuItem Name="miToggleConnections" Header="Toggle _Connection Manager"/>
            </MenuItem>
            <MenuItem Header="_Help">
                <MenuItem Name="miRunTests" Header="Run _Tests">
                    <MenuItem Name="miQuickTest" Header="_Quick Test"/>
                    <MenuItem Name="miComprehensiveTest" Header="_Comprehensive Test"/>
                    <MenuItem Name="miIntegrationTest" Header="_Integration Test"/>
                </MenuItem>
                <MenuItem Name="miViewLogs" Header="View _Debug Logs">
                    <MenuItem Name="miViewLogsWindow" Header="View in _Window"/>
                    <MenuItem Name="miExportLogsJson" Header="Export as _JSON"/>
                    <MenuItem Name="miExportLogsHtml" Header="Export as _HTML"/>
                    <Separator/>
                    <MenuItem Name="miClearLogs" Header="_Clear Logs"/>
                </MenuItem>
                <Separator/>
                <MenuItem Name="miReportBug" Header="📝 Report _Bug"/>
                <MenuItem Name="miViewBugs" Header="🐛 View Bug _Reports">
                    <MenuItem Name="miViewBugsWindow" Header="View in _Window"/>
                    <MenuItem Name="miExportBugsHtml" Header="Export as _HTML"/>
                </MenuItem>
                <Separator/>
                <MenuItem Name="miDebugMode" Header="Enable _Debug Mode" IsCheckable="True" InputGestureText="F12, Ctrl+Shift+I"/>
                <Separator/>
                <MenuItem Name="miAbout" Header="_About"/>
            </MenuItem>
        </Menu>
        
        <!-- Main Content -->
        <Grid Margin="10" Name="MainGrid">
        <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        
        <!-- Main Content Area -->
        <Grid Grid.Column="0" Name="MainContentGrid">
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>
        
        <!-- Profile Configuration -->
        <GroupBox Grid.Row="0" Name="ProfileSection" Margin="0,0,0,10" Padding="10">
            <GroupBox.Header>
                <Label Name="ProfileSectionHeader" Content="AWS Profile Management" FontWeight="Bold"/>
            </GroupBox.Header>
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="200"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                
                <Label Grid.Column="0" Content="Profile:" VerticalAlignment="Center"/>
                <ComboBox Grid.Column="1" Name="cmbProfile" Margin="5,0" Height="25" VerticalAlignment="Center" IsEditable="True" ToolTip="Select or type AWS SSO profile name - recent profiles appear at top"/>
                <Button Grid.Column="2" Name="btnRefreshProfiles" Content="🔄" Width="30" Height="25" Margin="5,0" ToolTip="Refresh the list of available AWS profiles from CLI configuration"/>
                <Button Grid.Column="3" Name="btnCheckStatus" Content="Check Status" Width="90" Height="25" Margin="5,0" ToolTip="Verify SSO authentication status and permissions for selected profile"/>
                
                <StackPanel Grid.Column="4" Orientation="Horizontal" Margin="10,0">
                    <Label Name="lblProfileStatus" Content="Select a profile to check SSO status" VerticalAlignment="Center" FontSize="10" Foreground="Gray"/>
                    <Button Name="btnSsoLogin" Content="🔐 SSO Login" Width="100" Height="25" Margin="5,0" Visibility="Collapsed" ToolTip="Login to AWS SSO"/>
                    <Button Name="btnSsoLogout" Content="🚪 Logout (All SSO)" Width="130" Height="25" Margin="5,0" Visibility="Collapsed" ToolTip="Logout from ALL AWS SSO sessions"/>
                    <Border Name="pnlProfileConfirmation" Background="LightYellow" BorderBrush="Orange" BorderThickness="1" CornerRadius="3" Padding="8,4" Margin="10,0" Visibility="Collapsed">
                        <StackPanel Orientation="Horizontal">
                            <TextBlock Name="txtConfirmationMessage" Text="Confirm profile selection?" FontSize="10" VerticalAlignment="Center" Margin="0,0,8,0"/>
                            <Button Name="btnConfirmProfile" Content="✓" Width="20" Height="20" FontSize="10" Margin="0,0,4,0" ToolTip="Confirm profile selection"/>
                            <Button Name="btnCancelProfile" Content="✗" Width="20" Height="20" FontSize="10" ToolTip="Cancel profile selection"/>
                        </StackPanel>
                    </Border>
                    <Border Name="pnlSsoUrl" Background="LightBlue" BorderBrush="Blue" BorderThickness="1" CornerRadius="3" Padding="8,4" Margin="10,0" Visibility="Collapsed">
                        <StackPanel Orientation="Horizontal">
                            <TextBlock Name="txtSsoUrl" FontSize="10" VerticalAlignment="Center" Margin="0,0,8,0"/>
                            <Button Name="btnCopySsoUrl" Content="📋" Width="20" Height="20" FontSize="10" Margin="0,0,4,0" ToolTip="Copy URL to clipboard"/>
                            <Button Name="btnCloseSsoUrl" Content="✗" Width="20" Height="20" FontSize="10" ToolTip="Close URL panel"/>
                        </StackPanel>
                    </Border>
                </StackPanel>
            </Grid>
        </GroupBox>
        
        <!-- Search Configuration -->
        <GroupBox Grid.Row="1" Name="SearchSection" Margin="0,0,0,10" Padding="10">
            <GroupBox.Header>
                <Label Name="SearchSectionHeader" Content="AWS Resource Management" FontWeight="Bold"/>
            </GroupBox.Header>
            <Grid>
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>
                
                <!-- Search Row -->
                <Grid Grid.Row="0">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="155"/>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="140"/>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="140"/>
                        <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>
                    
                    <Label Grid.Column="0" Content="Search:" VerticalAlignment="Center"/>
                    <Button Grid.Column="1" Name="btnSearch" Content="🔍 Search" Height="25" Margin="5,0"/>
                    <Label Grid.Column="2" Content="History:" VerticalAlignment="Center" Margin="10,0,5,0"/>
                    <ComboBox Grid.Column="3" Name="cmbSearchHistory" Height="25" Margin="0,0,5,0" ToolTip="Select from recent search terms to quickly apply filters"/>
                    <Label Grid.Column="4" Content="Favorites:" VerticalAlignment="Center" Margin="5,0,5,0"/>
                    <ComboBox Grid.Column="5" Name="cmbFavorites" Height="25" Margin="0,0,5,0" ToolTip="Select from saved search combinations with filters"/>
                    <StackPanel Grid.Column="6" Orientation="Horizontal" Margin="5,0">
                        <Button Name="btnAddFavorite" Content="⭐" Width="25" Height="25" Margin="0,0,2,0" ToolTip="Add current search and filter settings as a favorite"/>
                        <Button Name="btnRemoveFavorite" Content="➖" Width="25" Height="25" ToolTip="Remove selected favorite from saved searches"/>
                    </StackPanel>
                </Grid>
                
                <!-- Filter Row -->
                <Grid Grid.Row="1" Margin="0,5,0,0">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="150"/>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="110"/>
                        <ColumnDefinition Width="110"/>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>
                    
                    <Label Grid.Column="0" Content="Filter:" VerticalAlignment="Center"/>
                    <TextBox Grid.Column="1" Name="txtNameFilter" Margin="5,0" Height="25" VerticalAlignment="Center" ToolTip="Type to filter instances by name or instance ID - supports partial matching"/>
                    <StackPanel Grid.Column="2" Orientation="Horizontal" Margin="15,0,0,0" VerticalAlignment="Center">
                        <CheckBox Name="chkAutoRefresh" Content="Auto Refresh" VerticalAlignment="Center" ToolTip="Automatically refresh instance list every 2 minutes"/>
                        <Label Name="lblLastRefresh" Content="" FontSize="9" Foreground="Gray" Margin="10,0,0,0" VerticalAlignment="Center"/>
                    </StackPanel>
                    <ComboBox Grid.Column="3" Name="cmbStateFilter" Margin="5,0" Height="25" VerticalAlignment="Center" ToolTip="Filter instances by their current state (running, stopped, etc.)"/>
                    <ComboBox Grid.Column="4" Name="cmbTypeFilter" Margin="5,0" Height="25" VerticalAlignment="Center" ToolTip="Filter instances by their type (t3.micro, m5.large, etc.)"/>
                    <Button Grid.Column="5" Name="btnConnectionManager" Content="🔗 Connections" Width="100" Height="25" Margin="15,0,5,0" ToolTip="Toggle connection manager panel"/>
                    <Button Grid.Column="6" Name="btnSettings" Content="⚙️" Width="30" Height="25" Margin="5,0,10,0" ToolTip="Toggle settings panel - Configure UI preferences and DataGrid spacing"/>
                </Grid>
            </Grid>
        </GroupBox>
        
        <!-- Results with Service Tabs -->
        <GroupBox Grid.Row="2" Name="ResultsSection" Padding="10">
            <GroupBox.Header>
                <Label Name="ResultsSectionHeader" Content="AWS Resources" FontWeight="Bold"/>
            </GroupBox.Header>
            <TabControl Name="tcServices" Margin="5">
                <!-- Service tabs will be dynamically generated -->
                <TabItem Header="🖥️ EC2 Instances" Name="tabEC2">
                    <DataGrid Name="dgEC2" AutoGenerateColumns="False" IsReadOnly="True" GridLinesVisibility="All" HeadersVisibility="All" FontFamily="Segoe UI" FontSize="12" Height="300" MinHeight="200">
                <DataGrid.ContextMenu>
                    <ContextMenu Name="cmInstanceActions">
                        <MenuItem Name="miRDPConnection" Header="🖥️ RDP Connection" />
                        <MenuItem Name="miSSHConnection" Header="🖥️ SSH Connection" />
                        <Separator/>
                        <MenuItem Name="miPortForward" Header="🔗 Port Forward..." />
                        <MenuItem Name="miSendCommand" Header="📋 Send Command..." />
                    </ContextMenu>
                </DataGrid.ContextMenu>
                <DataGrid.Columns>
                    <DataGridTextColumn Header="Name" Binding="{Binding Name}" Width="120"/>
                    <DataGridTextColumn Header="Instance ID" Binding="{Binding InstanceId}" Width="100"/>
                    <DataGridTextColumn Header="State" Binding="{Binding State}" Width="80">
                        <DataGridTextColumn.ElementStyle>
                            <Style TargetType="TextBlock">
                                <Setter Property="Padding" Value="8,4"/>
                                <Style.Triggers>
                                    <Trigger Property="Text" Value="running">
                                        <Setter Property="Foreground" Value="Green"/>
                                        <Setter Property="FontWeight" Value="Bold"/>
                                    </Trigger>
                                    <Trigger Property="Text" Value="stopped">
                                        <Setter Property="Foreground" Value="Red"/>
                                    </Trigger>
                                    <Trigger Property="Text" Value="stopping">
                                        <Setter Property="Foreground" Value="Orange"/>
                                    </Trigger>
                                    <Trigger Property="Text" Value="pending">
                                        <Setter Property="Foreground" Value="Blue"/>
                                    </Trigger>
                                </Style.Triggers>
                            </Style>
                        </DataGridTextColumn.ElementStyle>
                    </DataGridTextColumn>
                    <DataGridTextColumn Header="Health" Binding="{Binding HealthStatus}" Width="80">
                        <DataGridTextColumn.ElementStyle>
                            <Style TargetType="TextBlock">
                                <Setter Property="Padding" Value="8,4"/>
                                <Style.Triggers>
                                    <Trigger Property="Text" Value="✅ OK">
                                        <Setter Property="Foreground" Value="Green"/>
                                    </Trigger>
                                    <Trigger Property="Text" Value="❌ Failed">
                                        <Setter Property="Foreground" Value="Red"/>
                                    </Trigger>
                                    <Trigger Property="Text" Value="⚠️ Impaired">
                                        <Setter Property="Foreground" Value="Orange"/>
                                    </Trigger>
                                </Style.Triggers>
                            </Style>
                        </DataGridTextColumn.ElementStyle>
                    </DataGridTextColumn>
                    <DataGridTextColumn Header="IP Address" Binding="{Binding PrivateIp}" Width="100"/>
                    <DataGridTextColumn Header="Platform" Binding="{Binding Platform}" Width="70"/>
                    <DataGridTextColumn Header="Type" Binding="{Binding InstanceType}" Width="90"/>
                    <DataGridTextColumn Header="Region" Binding="{Binding Region}" Width="80"/>
                    <DataGridTextColumn Header="Uptime" Binding="{Binding Uptime}" Width="60"/>
                </DataGrid.Columns>
                    </DataGrid>
                </TabItem>
            </TabControl>
        </GroupBox>
        
        <!-- Status Bar -->
        <StatusBar Grid.Row="3">
            <StatusBarItem>
                <Label Name="lblStatus" Content="Ready" HorizontalAlignment="Left"/>
            </StatusBarItem>
            <StatusBarItem Width="200">
                <Label Name="lblInstanceCount" Content="" FontSize="10" Foreground="Gray" HorizontalAlignment="Right"/>
            </StatusBarItem>
        </StatusBar>
        </Grid>
        
        <!-- Side Panel Area -->
        <StackPanel Grid.Column="1" Name="SidePanelContainer" Orientation="Horizontal" Visibility="Collapsed">
            <!-- Panels will be added here dynamically -->
        </StackPanel>
        </Grid>
    </DockPanel>
</Window>
'@

# Create WPF Window
try {
    $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($xaml))
    $window = [Windows.Markup.XamlReader]::Load($reader)
} catch {
    Write-Error "Failed to create WPF window: $($_.Exception.Message)"
    throw
}

# Get menu elements
try {
    $script:miExit = $window.FindName('miExit')
    $script:miClearHistory = $window.FindName('miClearHistory')
    $script:miClearFavorites = $window.FindName('miClearFavorites')
    $script:miPreferences = $window.FindName('miPreferences')
    $script:miRefresh = $window.FindName('miRefresh')
    $script:miToggleConnections = $window.FindName('miToggleConnections')
    $script:miRunTests = $window.FindName('miRunTests')
    $script:miQuickTest = $window.FindName('miQuickTest')
    $script:miComprehensiveTest = $window.FindName('miComprehensiveTest')
    $script:miIntegrationTest = $window.FindName('miIntegrationTest')
    $script:miViewLogs = $window.FindName('miViewLogs')
    $script:miViewLogsWindow = $window.FindName('miViewLogsWindow')
    $script:miExportLogsJson = $window.FindName('miExportLogsJson')
    $script:miExportLogsHtml = $window.FindName('miExportLogsHtml')
    $script:miClearLogs = $window.FindName('miClearLogs')
    $script:miDebugMode = $window.FindName('miDebugMode')
    $script:miReportBug = $window.FindName('miReportBug')
    $script:miViewBugs = $window.FindName('miViewBugs')
    $script:miViewBugsWindow = $window.FindName('miViewBugsWindow')
    $script:miExportBugsHtml = $window.FindName('miExportBugsHtml')
    $script:miAbout = $window.FindName('miAbout')
} catch {
    Write-Error "Failed to find menu elements: $($_.Exception.Message)"
    throw
}

# Get UI elements and make them available to modules
$script:cmbProfile = $window.FindName('cmbProfile')
$script:btnRefreshProfiles = $window.FindName('btnRefreshProfiles')
$script:btnCheckStatus = $window.FindName('btnCheckStatus')
$script:btnSsoLogin = $window.FindName('btnSsoLogin')
$script:btnSsoLogout = $window.FindName('btnSsoLogout')
$script:lblProfileStatus = $window.FindName('lblProfileStatus')
$script:pnlProfileConfirmation = $window.FindName('pnlProfileConfirmation')
$script:txtConfirmationMessage = $window.FindName('txtConfirmationMessage')
$script:btnConfirmProfile = $window.FindName('btnConfirmProfile')
$script:btnCancelProfile = $window.FindName('btnCancelProfile')
$script:pnlSsoUrl = $window.FindName('pnlSsoUrl')
$script:txtSsoUrl = $window.FindName('txtSsoUrl')
$script:btnCopySsoUrl = $window.FindName('btnCopySsoUrl')
$script:btnCloseSsoUrl = $window.FindName('btnCloseSsoUrl')
$script:btnSearch = $window.FindName('btnSearch')
$script:cmbSearchHistory = $window.FindName('cmbSearchHistory')
$script:cmbFavorites = $window.FindName('cmbFavorites')
$script:btnAddFavorite = $window.FindName('btnAddFavorite')
$script:btnRemoveFavorite = $window.FindName('btnRemoveFavorite')
$script:txtNameFilter = $window.FindName('txtNameFilter')
$script:chkAutoRefresh = $window.FindName('chkAutoRefresh')
$script:cmbStateFilter = $window.FindName('cmbStateFilter')
$script:cmbTypeFilter = $window.FindName('cmbTypeFilter')
$script:dgEC2 = $window.FindName('dgEC2')
$script:lblStatus = $window.FindName('lblStatus')
$script:lblInstanceCount = $window.FindName('lblInstanceCount')
$script:lblLastRefresh = $window.FindName('lblLastRefresh')
$script:btnConnectionManager = $window.FindName('btnConnectionManager')
$script:btnSettings = $window.FindName('btnSettings')

# Get service management elements
$script:tcServices = $window.FindName('tcServices')
$script:ProfileSectionHeader = $window.FindName('ProfileSectionHeader')
$script:SearchSectionHeader = $window.FindName('SearchSectionHeader')
$script:ResultsSectionHeader = $window.FindName('ResultsSectionHeader')

# Get side panel container
$script:SidePanelContainer = $window.FindName('SidePanelContainer')

# Get context menu elements
$script:cmInstanceActions = $window.FindName('cmInstanceActions')
$script:miRDPConnection = $window.FindName('miRDPConnection')
$script:miSSHConnection = $window.FindName('miSSHConnection')
$script:miPortForward = $window.FindName('miPortForward')
$script:miSendCommand = $window.FindName('miSendCommand')

# Make all UI elements available globally for modules (consolidated)
$global:cmbProfile = $script:cmbProfile
$global:btnRefreshProfiles = $script:btnRefreshProfiles
$global:btnCheckStatus = $script:btnCheckStatus
$global:btnSsoLogin = $script:btnSsoLogin
$global:btnSsoLogout = $script:btnSsoLogout
$global:lblProfileStatus = $script:lblProfileStatus
$global:pnlProfileConfirmation = $script:pnlProfileConfirmation
$global:txtConfirmationMessage = $script:txtConfirmationMessage
$global:btnConfirmProfile = $script:btnConfirmProfile
$global:btnCancelProfile = $script:btnCancelProfile
$global:pnlSsoUrl = $script:pnlSsoUrl
$global:txtSsoUrl = $script:txtSsoUrl
$global:btnCopySsoUrl = $script:btnCopySsoUrl
$global:btnCloseSsoUrl = $script:btnCloseSsoUrl
$global:btnSearch = $script:btnSearch
$global:cmbSearchHistory = $script:cmbSearchHistory
$global:cmbFavorites = $script:cmbFavorites
$global:btnAddFavorite = $script:btnAddFavorite
$global:btnRemoveFavorite = $script:btnRemoveFavorite
$global:txtNameFilter = $script:txtNameFilter
$global:chkAutoRefresh = $script:chkAutoRefresh
$global:cmbStateFilter = $script:cmbStateFilter
$global:cmbTypeFilter = $script:cmbTypeFilter
$global:dgEC2 = $script:dgEC2
$global:lblStatus = $script:lblStatus
$global:lblInstanceCount = $script:lblInstanceCount
$global:lblLastRefresh = $script:lblLastRefresh
$global:btnConnectionManager = $script:btnConnectionManager
$global:btnSettings = $script:btnSettings
$global:tcServices = $script:tcServices
$global:ProfileSectionHeader = $script:ProfileSectionHeader
$global:SearchSectionHeader = $script:SearchSectionHeader
$global:ResultsSectionHeader = $script:ResultsSectionHeader
$global:SidePanelContainer = $script:SidePanelContainer
$global:cmInstanceActions = $script:cmInstanceActions
$global:miRDPConnection = $script:miRDPConnection
$global:miSSHConnection = $script:miSSHConnection
$global:miPortForward = $script:miPortForward
$global:miSendCommand = $script:miSendCommand

# Check for version changes and run automatic tests (after UI elements are available)
try {
    if ($script:AppVersion) {
        $versionChanged = Test-VersionChange -CurrentVersion $script:AppVersion
        if ($versionChanged) {
            Write-Host "📋 Automatic testing completed - check TEST_RESULTS.md for details" -ForegroundColor Green
        }
    }
} catch {
    Write-Warning "Version tracking failed: $($_.Exception.Message)"
}

# Add menu event handlers
$script:miExit.Add_Click({ $window.Close() })

$script:miClearHistory.Add_Click({
    $result = [System.Windows.MessageBox]::Show("Clear all search history?", "Clear History", [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
    if ($result -eq [System.Windows.MessageBoxResult]::Yes) {
        Clear-SearchHistory
        Update-SearchHistoryDropdown
        if ($global:DebugMode) { Write-Host "[DEBUG] Search history cleared" -ForegroundColor Yellow }
    }
})

$script:miClearFavorites.Add_Click({
    $result = [System.Windows.MessageBox]::Show("Clear all favorites?", "Clear Favorites", [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
    if ($result -eq [System.Windows.MessageBoxResult]::Yes) {
        Clear-Favorites
        Update-FavoritesDropdown
        if ($global:DebugMode) { Write-Host "[DEBUG] Favorites cleared" -ForegroundColor Yellow }
    }
})

$script:miPreferences.Add_Click({
    Switch-SettingsPanel
})

$script:miRefresh.Add_Click({
    if ($btnSearch.Content -eq "🔍 Search Instances") {
        $btnSearch.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))
    }
})

$script:miToggleConnections.Add_Click({
    $btnConnectionManager.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))
})

$script:miDebugMode.Add_Click({
    $global:DebugMode = $script:miDebugMode.IsChecked
    $status = if ($global:DebugMode) { "enabled" } else { "disabled" }
    $lblStatus.Content = "Debug mode $status"
    Write-Host "[INFO] Debug mode $status" -ForegroundColor $(if ($global:DebugMode) { "Green" } else { "Gray" })
    Write-DebugLog "Debug mode $status" "INFO" "Application"
    
    # Enable/disable verbose logging based on debug mode
    if ($global:DebugMode) {
        $global:VerbosePreference = 'Continue'
        $global:DebugPreference = 'Continue'
        Write-Host "[DEBUG] Enhanced logging enabled - all operations will be logged" -ForegroundColor Yellow
        Write-DebugLog "Enhanced debug logging enabled" "INFO" "Application"
    } else {
        $global:VerbosePreference = 'SilentlyContinue'
        $global:DebugPreference = 'SilentlyContinue'
        Write-Host "[INFO] Enhanced logging disabled" -ForegroundColor Gray
        Write-DebugLog "Enhanced debug logging disabled" "INFO" "Application"
    }
})

# Test menu handlers
$script:miQuickTest.Add_Click({
    try {
        Write-DebugLog "Starting Quick Test from menu" "INFO" "TestRunner"
        $lblStatus.Content = "Running quick tests..."
        
        $results = Start-QuickTest -ShowProgress
        $passedResults = @($results | Where-Object { $_.Status -eq "PASS" })
        $failedResults = @($results | Where-Object { $_.Status -eq "FAIL" })
        $warningResults = @($results | Where-Object { $_.Status -eq "WARN" })
        $passCount = $passedResults.Count
        $failCount = $failedResults.Count
        $warnCount = $warningResults.Count
        
        $lblStatus.Content = "Quick tests completed: $passCount passed, $failCount failed, $warnCount warnings"
        
        # Service configuration is handled by UniversalAWSDiscovery module
        
        # Update TEST_RESULTS.md file
        try {
            Update-MainTestResultsFile
        } catch {
            Write-DebugLog "Failed to update TEST_RESULTS.md: $($_.Exception.Message)" "WARN" "TestRunner"
        }
        
        # Show detailed results with option to view JSON details if there are failures/warnings
        $detailsText = "Quick Test Results:`n`n"
        foreach ($result in $results) {
            $statusIcon = switch ($result.Status) {
                "PASS" { "✅" }
                "FAIL" { "❌" }
                "WARN" { "⚠️" }
                default { "❔" }
            }
            $detailsText += "$statusIcon $($result.TestName): $($result.Details)`n"
        }
        
        $detailsText += "`n📝 Results automatically saved to docs/TEST_RESULTS.md"
        
        # Show different dialog based on whether there are failures/warnings
        if ($failCount -gt 0 -or $warnCount -gt 0) {
            $detailsText += "`n`n💡 Click 'Yes' to view detailed JSON results for troubleshooting"
            $dialogResult = [System.Windows.MessageBox]::Show($detailsText, "Quick Test Results", [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Information)
            
            if ($dialogResult -eq [System.Windows.MessageBoxResult]::Yes) {
                # Export and open JSON results
                try {
                    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
                    $jsonPath = Join-Path $env:TEMP "AWS-Management-Studio-QuickTest-$timestamp.json"
                    
                    # Create simple JSON export for quick test results
                    $exportData = @{
                        TestSuite = "Quick Test"
                        Version = if ($global:AppVersion) { $global:AppVersion } else { "6.2.2" }
                        StartTime = Get-Date
                        EndTime = Get-Date
                        Results = $results
                        Summary = @{
                            TotalTests = $results.Count
                            PassedTests = $passCount
                            FailedTests = $failCount
                            WarningTests = $warnCount
                        }
                    }
                    
                    $exportData | ConvertTo-Json -Depth 10 | Out-File -FilePath $jsonPath -Encoding UTF8
                    Start-Process "notepad.exe" -ArgumentList $jsonPath
                } catch {
                    [System.Windows.MessageBox]::Show("Failed to open detailed results: $($_.Exception.Message)", "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
                }
            }
        } else {
            [System.Windows.MessageBox]::Show($detailsText, "Quick Test Results", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
        }
    } catch {
        Write-DebugLog "Quick test failed: $($_.Exception.Message)" "ERROR" "TestRunner"
        [System.Windows.MessageBox]::Show("Quick test failed: $($_.Exception.Message)", "Test Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
    }
})

$script:miComprehensiveTest.Add_Click({
    try {
        Write-DebugLog "Starting Comprehensive Test from menu" "INFO" "TestRunner"
        $lblStatus.Content = "Running comprehensive tests..."
        
        $results = Start-ComprehensiveTest -ShowProgress
        $passedResults = @($results | Where-Object { $_.Status -eq "PASS" })
        $failedResults = @($results | Where-Object { $_.Status -eq "FAIL" })
        $warningResults = @($results | Where-Object { $_.Status -eq "WARN" })
        $passCount = $passedResults.Count
        $failCount = $failedResults.Count
        $warnCount = $warningResults.Count
        
        $lblStatus.Content = "Comprehensive tests completed: $passCount passed, $failCount failed, $warnCount warnings"
        
        # Update TEST_RESULTS.md file
        try {
            Update-MainTestResultsFile
        } catch {
            Write-DebugLog "Failed to update TEST_RESULTS.md: $($_.Exception.Message)" "WARN" "TestRunner"
        }
        
        # Show detailed results with option to view JSON details if there are failures/warnings
        $detailsText = "Comprehensive Test Results:`n`n"
        foreach ($result in $results) {
            $statusIcon = switch ($result.Status) {
                "PASS" { "✅" }
                "FAIL" { "❌" }
                "WARN" { "⚠️" }
                default { "❔" }
            }
            $detailsText += "$statusIcon $($result.TestName): $($result.Details)`n"
        }
        
        $detailsText += "`n📝 Results automatically saved to docs/TEST_RESULTS.md"
        
        # Show different dialog based on whether there are failures/warnings
        if ($failCount -gt 0 -or $warnCount -gt 0) {
            $detailsText += "`n`n💡 Click 'Yes' to view detailed JSON results for troubleshooting"
            $dialogResult = [System.Windows.MessageBox]::Show($detailsText, "Comprehensive Test Results", [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Information)
            
            if ($dialogResult -eq [System.Windows.MessageBoxResult]::Yes) {
                # Export and open JSON results
                try {
                    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
                    $jsonPath = Join-Path $env:TEMP "AWS-Management-Studio-ComprehensiveTest-$timestamp.json"
                    Export-TestResultsJSON -Path $jsonPath
                    Start-Process "notepad.exe" -ArgumentList $jsonPath
                } catch {
                    [System.Windows.MessageBox]::Show("Failed to open detailed results: $($_.Exception.Message)", "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
                }
            }
        } else {
            [System.Windows.MessageBox]::Show($detailsText, "Comprehensive Test Results", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
        }
    } catch {
        Write-DebugLog "Comprehensive test failed: $($_.Exception.Message)" "ERROR" "TestRunner"
        [System.Windows.MessageBox]::Show("Comprehensive test failed: $($_.Exception.Message)", "Test Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
    }
})

$script:miIntegrationTest.Add_Click({
    try {
        Write-DebugLog "Starting Integration Test from menu" "INFO" "TestRunner"
        $lblStatus.Content = "Running integration tests..."
        
        $results = Start-IntegrationTest -ShowProgress
        $passedResults = @($results | Where-Object { $_.Status -eq "PASS" })
        $failedResults = @($results | Where-Object { $_.Status -eq "FAIL" })
        $warningResults = @($results | Where-Object { $_.Status -eq "WARN" })
        $passCount = $passedResults.Count
        $failCount = $failedResults.Count
        $warnCount = $warningResults.Count
        
        $lblStatus.Content = "Integration tests completed: $passCount passed, $failCount failed, $warnCount warnings"
        
        # Update TEST_RESULTS.md file
        try {
            Update-MainTestResultsFile
        } catch {
            Write-DebugLog "Failed to update TEST_RESULTS.md: $($_.Exception.Message)" "WARN" "TestRunner"
        }
        
        # Show detailed results with option to view JSON details if there are failures/warnings
        $detailsText = "Integration Test Results:`n`n"
        foreach ($result in $results) {
            $statusIcon = switch ($result.Status) {
                "PASS" { "✅" }
                "FAIL" { "❌" }
                "WARN" { "⚠️" }
                default { "❔" }
            }
            $detailsText += "$statusIcon $($result.TestName): $($result.Details)`n"
        }
        
        $detailsText += "`n📝 Results automatically saved to docs/TEST_RESULTS.md"
        
        # Show different dialog based on whether there are failures/warnings
        if ($failCount -gt 0 -or $warnCount -gt 0) {
            $detailsText += "`n`n💡 Click 'Yes' to view detailed JSON results for troubleshooting"
            $dialogResult = [System.Windows.MessageBox]::Show($detailsText, "Integration Test Results", [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Information)
            
            if ($dialogResult -eq [System.Windows.MessageBoxResult]::Yes) {
                # Export and open JSON results
                try {
                    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
                    $jsonPath = Join-Path $env:TEMP "AWS-Management-Studio-IntegrationTest-$timestamp.json"
                    
                    # Create simple JSON export for integration test results
                    $exportData = @{
                        TestSuite = "Integration Test"
                        Version = if ($global:AppVersion) { $global:AppVersion } else { "6.2.2" }
                        StartTime = Get-Date
                        EndTime = Get-Date
                        Results = $results
                        Summary = @{
                            TotalTests = $results.Count
                            PassedTests = $passCount
                            FailedTests = $failCount
                            WarningTests = $warnCount
                        }
                    }
                    
                    $exportData | ConvertTo-Json -Depth 10 | Out-File -FilePath $jsonPath -Encoding UTF8
                    Start-Process "notepad.exe" -ArgumentList $jsonPath
                } catch {
                    [System.Windows.MessageBox]::Show("Failed to open detailed results: $($_.Exception.Message)", "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
                }
            }
        } else {
            [System.Windows.MessageBox]::Show($detailsText, "Integration Test Results", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
        }
    } catch {
        Write-DebugLog "Integration test failed: $($_.Exception.Message)" "ERROR" "TestRunner"
        [System.Windows.MessageBox]::Show("Integration test failed: $($_.Exception.Message)", "Test Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
    }
})

# Debug log menu handlers
$script:miViewLogsWindow.Add_Click({
    try {
        $logs = Get-DebugLogs
        if ($logs.Count -eq 0) {
            [System.Windows.MessageBox]::Show("No debug logs available.", "Debug Logs", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
            return
        }
        
        # Create log viewer window
        $logWindow = New-Object System.Windows.Window
        $logWindow.Title = "Debug Logs - AWS Management Studio"
        $logWindow.Width = 800
        $logWindow.Height = 600
        $logWindow.WindowStartupLocation = [System.Windows.WindowStartupLocation]::CenterOwner
        $logWindow.Owner = $window
        
        $scrollViewer = New-Object System.Windows.Controls.ScrollViewer
        $scrollViewer.VerticalScrollBarVisibility = [System.Windows.Controls.ScrollBarVisibility]::Auto
        $scrollViewer.HorizontalScrollBarVisibility = [System.Windows.Controls.ScrollBarVisibility]::Auto
        
        $textBlock = New-Object System.Windows.Controls.TextBlock
        $textBlock.FontFamily = New-Object System.Windows.Media.FontFamily("Consolas")
        $textBlock.FontSize = 12
        $textBlock.Margin = New-Object System.Windows.Thickness(10)
        
        $logText = ""
        foreach ($log in $logs) {
            $logText += "[$($log.Timestamp)] [$($log.Level)] [$($log.Source)] $($log.Message)`n"
        }
        $textBlock.Text = $logText
        
        $scrollViewer.Content = $textBlock
        $logWindow.Content = $scrollViewer
        
        $logWindow.ShowDialog() | Out-Null
    } catch {
        [System.Windows.MessageBox]::Show("Failed to show debug logs: $($_.Exception.Message)", "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
    }
})

$script:miExportLogsJson.Add_Click({
    try {
        $saveDialog = New-Object Microsoft.Win32.SaveFileDialog
        $saveDialog.Filter = "JSON files (*.json)|*.json|All files (*.*)|*.*"
        $saveDialog.DefaultExt = "json"
        $saveDialog.FileName = "AWS-Management-Studio-DebugLogs-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
        
        if ($saveDialog.ShowDialog() -eq $true) {
            if (Export-DebugLogsToJson -FilePath $saveDialog.FileName) {
                [System.Windows.MessageBox]::Show("Debug logs exported to:`n$($saveDialog.FileName)", "Export Complete", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
            } else {
                [System.Windows.MessageBox]::Show("Failed to export debug logs.", "Export Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
            }
        }
    } catch {
        [System.Windows.MessageBox]::Show("Export failed: $($_.Exception.Message)", "Export Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
    }
})

$script:miExportLogsHtml.Add_Click({
    try {
        $saveDialog = New-Object Microsoft.Win32.SaveFileDialog
        $saveDialog.Filter = "HTML files (*.html)|*.html|All files (*.*)|*.*"
        $saveDialog.DefaultExt = "html"
        $saveDialog.FileName = "AWS-Management-Studio-DebugLogs-$(Get-Date -Format 'yyyyMMdd-HHmmss').html"
        
        if ($saveDialog.ShowDialog() -eq $true) {
            if (Export-DebugLogsToHtml -FilePath $saveDialog.FileName) {
                $result = [System.Windows.MessageBox]::Show("Debug logs exported to:`n$($saveDialog.FileName)`n`nWould you like to open the file?", "Export Complete", [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Information)
                if ($result -eq [System.Windows.MessageBoxResult]::Yes) {
                    try {
                        Start-Process $saveDialog.FileName
                    } catch {
                        [System.Windows.MessageBox]::Show("Could not open file: $($_.Exception.Message)", "Open Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
                    }
                }
            } else {
                [System.Windows.MessageBox]::Show("Failed to export debug logs.", "Export Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
            }
        }
    } catch {
        [System.Windows.MessageBox]::Show("Export failed: $($_.Exception.Message)", "Export Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
    }
})

$script:miClearLogs.Add_Click({
    $result = [System.Windows.MessageBox]::Show("Clear all debug logs?", "Clear Debug Logs", [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
    if ($result -eq [System.Windows.MessageBoxResult]::Yes) {
        Clear-DebugLogs
        $lblStatus.Content = "Debug logs cleared"
    }
})

# Bug tracker menu handlers
$script:miReportBug.Add_Click({
    try {
        Write-DebugLog "Opening bug report panel" "INFO" "BugTracker"
        
        # Use new configurable panel framework
        $configPath = "$PSScriptRoot\..\src\Config\panels\bug-report.json"
        $eventHandlers = @{
            'submitBug' = {
                param($controls, $dataContext)
                try {
                    $title = $controls['txtTitle'].Text
                    $description = $controls['txtDescription'].Text
                    $steps = $controls['txtSteps'].Text
                    # Handle ComboBox SelectedItem properly
                    $severity = if ($controls['cmbSeverity'].SelectedItem) { 
                        $controls['cmbSeverity'].SelectedItem.ToString() 
                    } else { 
                        "Medium" 
                    }
                    
                    if (-not $title -or -not $description) {
                        [System.Windows.MessageBox]::Show("Please fill in Title and Description fields.", "Bug Report", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
                        return
                    }
                    
                    $bugReport = New-BugReport -Title $title -Description $description -StepsToReproduce $steps -Severity $severity
                    if ($bugReport) {
                        [System.Windows.MessageBox]::Show("Bug report submitted successfully!\nReport ID: $($bugReport.Id)", "Bug Report Submitted", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
                        
                        # Clear form
                        $controls['txtTitle'].Text = ""
                        $controls['txtDescription'].Text = ""
                        $controls['txtSteps'].Text = ""
                        $controls['cmbSeverity'].SelectedIndex = 1
                    }
                } catch {
                    [System.Windows.MessageBox]::Show("Failed to submit bug report: $($_.Exception.Message)", "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
                }
            }
            'btnTakeScreenshot' = {
                param($controls, $dataContext)
                try {
                    # Change button text to show it's working
                    $originalText = $controls['btnTakeScreenshot'].Content
                    $controls['btnTakeScreenshot'].Content = "📸 Taking..."
                    $controls['btnTakeScreenshot'].IsEnabled = $false
                    
                    # Take screenshot using Windows Forms
                    Add-Type -AssemblyName System.Drawing
                    Add-Type -AssemblyName System.Windows.Forms
                    
                    $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
                    $bitmap = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
                    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
                    $graphics.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
                    
                    # Save to temp file
                    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
                    $screenshotPath = Join-Path $env:TEMP "BugReport-Screenshot-$timestamp.png"
                    $bitmap.Save($screenshotPath, [System.Drawing.Imaging.ImageFormat]::Png)
                    
                    # Cleanup
                    $graphics.Dispose()
                    $bitmap.Dispose()
                    
                    # Show success message
                    [System.Windows.MessageBox]::Show("Screenshot saved to:\n$screenshotPath", "Screenshot Taken", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
                    
                    # Restore button
                    $controls['btnTakeScreenshot'].Content = "✅ Screenshot Saved"
                    
                    # Reset button after 3 seconds
                    $timer = New-Object System.Windows.Threading.DispatcherTimer
                    $timer.Interval = [TimeSpan]::FromSeconds(3)
                    $timer.Add_Tick({
                        $controls['btnTakeScreenshot'].Content = $originalText
                        $controls['btnTakeScreenshot'].IsEnabled = $true
                        $timer.Stop()
                    })
                    $timer.Start()
                    
                } catch {
                    [System.Windows.MessageBox]::Show("Failed to take screenshot: $($_.Exception.Message)", "Screenshot Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
                    # Restore button on error
                    $controls['btnTakeScreenshot'].Content = $originalText
                    $controls['btnTakeScreenshot'].IsEnabled = $true
                }
            }
        }
        
        New-ConfigurablePanel -ConfigPath $configPath -EventHandlers $eventHandlers
        
    } catch {
        Write-DebugLog "Failed to open bug report panel: $($_.Exception.Message)" "ERROR" "BugTracker"
        [System.Windows.MessageBox]::Show("Failed to open bug report panel: $($_.Exception.Message)", "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
    }
})

$script:miViewBugsWindow.Add_Click({
    try {
        Write-DebugLog "Opening bug report viewer window" "INFO" "BugTracker"
        Show-BugReportViewer
    } catch {
        Write-DebugLog "Failed to open bug report viewer: $($_.Exception.Message)" "ERROR" "BugTracker"
        [System.Windows.MessageBox]::Show("Failed to load bug reports: $($_.Exception.Message)", "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
    }
})

$script:miExportBugsHtml.Add_Click({
    try {
        Write-DebugLog "Exporting bug reports to HTML" "INFO" "BugTracker"
        $saveDialog = New-Object Microsoft.Win32.SaveFileDialog
        $saveDialog.Filter = "HTML files (*.html)|*.html|All files (*.*)|*.*"
        $saveDialog.DefaultExt = "html"
        $saveDialog.FileName = "AWS-Management-Studio-BugReports-$(Get-Date -Format 'yyyyMMdd-HHmmss').html"
        
        if ($saveDialog.ShowDialog() -eq $true) {
            $exportPath = Export-BugReports -OutputPath $saveDialog.FileName
            if ($exportPath) {
                $result = [System.Windows.MessageBox]::Show("Bug reports exported to:`n$exportPath`n`nWould you like to open the file?", "Export Complete", [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Information)
                if ($result -eq [System.Windows.MessageBoxResult]::Yes) {
                    try {
                        Start-Process $exportPath
                    } catch {
                        [System.Windows.MessageBox]::Show("Could not open file: $($_.Exception.Message)", "Open Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
                    }
                }
            } else {
                [System.Windows.MessageBox]::Show("Failed to export bug reports.", "Export Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
            }
        }
    } catch {
        Write-DebugLog "Failed to export bug reports: $($_.Exception.Message)" "ERROR" "BugTracker"
        [System.Windows.MessageBox]::Show("Export failed: $($_.Exception.Message)", "Export Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
    }
})

$script:miAbout.Add_Click({
    $aboutText = @"
AWS Management Studio v$script:AppVersion
Phase 3 Complete: Manual Connection Management

A PowerShell-based WPF application for AWS resource management.

Features:
• Multi-region EC2 instance search
• AWS SSO integration
• Connection management (RDP, SSH, Port Forward)
• Search history and favorites
• Real-time filtering
• Automated testing and debug logging
• Integrated bug reporting

Developed for Site Reliability Engineers
"@
    [System.Windows.MessageBox]::Show($aboutText, "About AWS Management Studio", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
})


# Defer ALL event handler registration until window is fully loaded
# This prevents any events from firing during initialization

# NO initialization before ShowDialog() - everything happens in window loaded event
# This prevents any operations that could corrupt the window object

# Helper function for service display names
function Get-ServiceDisplayName {
    param([string]$ServiceKey)
    
    if ($ServiceKey -eq 'EC2') {
        return '🖥️ EC2 Instances'
    }
    
    try {
        $configPath = "$PSScriptRoot\..\src\Config\aws-services.json"
        $serviceConfigs = Get-Content $configPath | ConvertFrom-Json
        $config = $serviceConfigs.services.$ServiceKey
        if ($config) {
            return "$($config.icon) $($config.name)"
        }
    } catch {
        # Fallback to service key if config fails
    }
    
    return $ServiceKey
}

# Global variables for service discovery (consolidated)
$global:ServiceDiscoveryRunspace = $null
$global:ServiceDiscoveryPowerShell = $null
$global:ServiceDiscoveryTimer = $null
$global:ServiceDiscoveryCancelled = $false

function Stop-ServiceDiscoveryTimer {
    if ($global:ServiceDiscoveryTimer) {
        $global:ServiceDiscoveryTimer.Stop()
        $global:ServiceDiscoveryTimer = $null
    }
    
    if ($global:ServiceDiscoveryPowerShell) {
        try {
            $global:ServiceDiscoveryPowerShell.Dispose()
        } catch { }
        $global:ServiceDiscoveryPowerShell = $null
    }
    
    if ($global:ServiceDiscoveryRunspace) {
        try {
            $global:ServiceDiscoveryRunspace.Close()
            $global:ServiceDiscoveryRunspace.Dispose()
        } catch { }
        $global:ServiceDiscoveryRunspace = $null
    }
}

# Remove the Update-ServiceConfiguration function as it's no longer needed
# The service discovery now tests existing configuration rather than updating it

# Initialize service tabs with simplified approach - moved after window is ready
# This will be done in the window loaded event



# Start elapsed time timer for last refresh display
$global:ElapsedTimer = New-Object System.Windows.Threading.DispatcherTimer
$global:ElapsedTimer.Interval = [TimeSpan]::FromSeconds(10)
$global:ElapsedTimer.Add_Tick({
    if ($global:LastRefreshTime -ne $null) {
        $elapsed = (Get-Date) - $global:LastRefreshTime
        if ($elapsed.TotalMinutes -lt 1) {
            $lblLastRefresh.Content = "(Last: $([math]::Floor($elapsed.TotalSeconds))s ago)"
        } elseif ($elapsed.TotalHours -lt 1) {
            $lblLastRefresh.Content = "(Last: $([math]::Floor($elapsed.TotalMinutes))m ago)"
        } else {
            $lblLastRefresh.Content = "(Last: $([math]::Floor($elapsed.TotalHours))h ago)"
        }
    }
})
$global:ElapsedTimer.Start()

# Profile selection variables - handlers will be registered after window loads
# (PendingProfile now initialized globally above)

function Show-ProfileConfirmation {
    param([string]$ProfileName)
    
    $global:PendingProfile = $ProfileName
    
    $txtConfirmationMessage.Text = "Use profile?"
    
    # Ensure window is wide enough
    if ($window.Width -lt 1000) {
        $window.Width = 1000
    }
    if ($global:DebugMode) { 
        $panelWidth = if ($pnlProfileConfirmation -and $pnlProfileConfirmation.Width) { $pnlProfileConfirmation.Width } else { "null" }
        Write-Host "[DEBUG] Panel width set to: $panelWidth" -ForegroundColor Cyan 
    }
    
    $pnlProfileConfirmation.Visibility = [System.Windows.Visibility]::Visible
    $lblProfileStatus.Content = "Profile selection pending..."
    $lblProfileStatus.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Colors]::Orange)
}

function Hide-ProfileConfirmation {
    $pnlProfileConfirmation.Visibility = [System.Windows.Visibility]::Collapsed
    $window.Width = 800
}

# Multi-service search is now handled by the dedicated MultiServiceSearch module

# Service configuration is now handled by UniversalAWSDiscovery module

# Service configuration functions removed - use UniversalAWSDiscovery module instead

# Service discovery functions moved to UniversalAWSDiscovery module

# Position PowerShell console relative to main window
function Set-ConsolePosition {
    try {
        $consoleWindow = [Win32]::GetConsoleWindow()
        if ($consoleWindow -ne [IntPtr]::Zero) {
            # Get main window position
            $mainWindowHandle = (New-Object System.Windows.Interop.WindowInteropHelper($window)).Handle
            $mainRect = New-Object 'Win32+RECT'
            [Win32]::GetWindowRect($mainWindowHandle, [ref]$mainRect) | Out-Null
            
            # Calculate console position (bottom-right of main window)
            $consoleWidth = 600
            $consoleHeight = 300
            $consoleX = $mainRect.Right - $consoleWidth
            $consoleY = $mainRect.Bottom
            
            # Position console
            [Win32]::SetWindowPos($consoleWindow, [IntPtr]::Zero, $consoleX, $consoleY, $consoleWidth, $consoleHeight, 0x0014) | Out-Null
        }
    } catch {
        # Console positioning is non-critical
    }
}

# Add window loaded event to position console
$window.Add_Loaded({ 
    try {
        Set-ConsolePosition
        
        # Add F5 key binding for refresh
        try {
            $refreshCommand = New-Object System.Windows.Input.RoutedCommand
            $window.CommandBindings.Add([System.Windows.Input.CommandBinding]::new($refreshCommand, {
                $script:miRefresh.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.MenuItem]::ClickEvent))
            }))
            $window.InputBindings.Add([System.Windows.Input.KeyBinding]::new($refreshCommand, [System.Windows.Input.Key]::F5, [System.Windows.Input.ModifierKeys]::None))
        } catch {
            Write-Warning "Failed to register F5 hotkey: $($_.Exception.Message)"
        }
        
        # Add F12 key binding for debug mode toggle
        try {
            $debugCommand = New-Object System.Windows.Input.RoutedCommand
            $window.CommandBindings.Add([System.Windows.Input.CommandBinding]::new($debugCommand, {
                $script:miDebugMode.IsChecked = -not $script:miDebugMode.IsChecked
                $script:miDebugMode.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.MenuItem]::ClickEvent))
            }))
            $window.InputBindings.Add([System.Windows.Input.KeyBinding]::new($debugCommand, [System.Windows.Input.Key]::F12, [System.Windows.Input.ModifierKeys]::None))
        } catch {
            Write-Warning "Failed to register F12 hotkey: $($_.Exception.Message)"
        }
        
        # Add Ctrl+Shift+I key binding for debug mode toggle (alternative)
        try {
            $debugCommand2 = New-Object System.Windows.Input.RoutedCommand
            $window.CommandBindings.Add([System.Windows.Input.CommandBinding]::new($debugCommand2, {
                $script:miDebugMode.IsChecked = -not $script:miDebugMode.IsChecked
                $script:miDebugMode.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.MenuItem]::ClickEvent))
            }))
            $window.InputBindings.Add([System.Windows.Input.KeyBinding]::new($debugCommand2, [System.Windows.Input.Key]::I, [System.Windows.Input.ModifierKeys]::Control -bor [System.Windows.Input.ModifierKeys]::Shift))
        } catch {
            Write-Warning "Failed to register Ctrl+Shift+I hotkey: $($_.Exception.Message)"
        }
        
        # Initialize essential UI components first
        try {
            # Initialize EC2 DataGrid
            $dgEC2.ItemsSource = @()
            
            # Initialize AWS profiles and filter dropdowns
            Get-AwsProfiles
            Initialize-FilterDropdowns
            
        } catch {
            Write-Warning "Essential UI initialization failed: $($_.Exception.Message)"
        }
        
        # Initialize service tabs after window is loaded
        try {
            $userSettings = Get-UserSettings
            $enabledServices = if ($userSettings -and $userSettings.PSObject.Properties['Services']) { $userSettings.Services } else { @('RDS', 'S3', 'Lambda') }
            
            foreach ($serviceKey in $enabledServices) {
                if ($serviceKey -ne 'EC2') {
                    $tab = New-Object System.Windows.Controls.TabItem
                    
                    $displayName = Get-ServiceDisplayName $serviceKey
                    
                    $tab.Header = $displayName
                    $tab.Tag = $serviceKey
                    
                    $label = New-Object System.Windows.Controls.Label
                    $label.Content = "Select profile and click Search to find $serviceKey resources"
                    $label.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
                    $label.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
                    $tab.Content = $label
                    
                    if ($tcServices) {
                        $tcServices.Items.Add($tab) | Out-Null
                    }
                }
            }
        } catch {
            Write-Verbose "Service tabs initialization failed: $($_.Exception.Message)"
        }
        
        # NOW register all event handlers after window is fully loaded
        
        # Register essential button handlers
        $btnRefreshProfiles.Add_Click({ Get-AwsProfiles })
        $btnCheckStatus.Add_Click({ Test-ProfileSsoStatus })
        $btnSsoLogin.Add_Click({ Start-SsoLogin })
        $btnSsoLogout.Add_Click({ Start-SsoLogout })
        $btnConnectionManager.Add_Click({ Switch-ConnectionManagerPanel })
        $btnSettings.Add_Click({ Switch-SettingsPanel })
        
        # Register search button handler
        $btnSearch.Add_Click({
            if ($global:DebugMode) {
                Write-Host "[SEARCH] Search button clicked - checking profile" -ForegroundColor Magenta
            }
            
            $profileName = $cmbProfile.Text.Trim()
            if ($global:DebugMode) {
                Write-Host "[SEARCH] Profile name: '$profileName'" -ForegroundColor Magenta
            }
            if ($profileName) {
                $selectedTab = $tcServices.SelectedItem
                $serviceKey = if ($selectedTab -and $selectedTab.Tag) { $selectedTab.Tag } else { 'EC2' }
                
                if ($btnSearch.Content -like "*Cancel*") {
                    # Cancel current search
                    if ($serviceKey -eq 'EC2') {
                        Stop-SearchJob
                    } else {
                        try { Stop-AllServiceSearchJobs } catch { }
                    }
                    $btnSearch.Content = "🔍 Search"
                    $lblStatus.Content = "Search cancelled"
                    return
                }
                
                # Use generic search or fallback to specific functions
                if ($serviceKey -eq 'EC2') {
                    Write-DebugLog "Starting EC2 search for profile: $profileName" "INFO" "Search"
                    Search-EC2Instances -ProfileName $profileName
                } else {
                    # Use the dedicated multi-service search module
                    try {
                        Write-DebugLog "Starting multi-service search for: $serviceKey" "INFO" "Search"
                        Search-AWSService -ServiceKey $serviceKey -ProfileName $profileName
                    } catch {
                        $errorMsg = $_.Exception.Message
                        Write-DebugLog "Multi-service search failed for $serviceKey`: $errorMsg" "ERROR" "Search"
                        $global:lblStatus.Content = "❌ $serviceKey search failed: $errorMsg"
                        
                        # Show error in the service tab
                        $selectedTab = $tcServices.SelectedItem
                        if ($selectedTab) {
                            $errorLabel = New-Object System.Windows.Controls.Label
                            $errorLabel.Content = "Search failed: $errorMsg"
                            $errorLabel.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
                            $errorLabel.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
                            $errorLabel.Foreground = [System.Windows.Media.Brushes]::Red
                            $selectedTab.Content = $errorLabel
                        }
                    }
                }
            }
        })
        
        # Register profile selection handlers
        $cmbProfile.Add_SelectionChanged({ 
            if ($cmbProfile.SelectedItem -and $cmbProfile.SelectedItem -ne $global:PendingProfile) {
                Show-ProfileConfirmation $cmbProfile.SelectedItem
            }
        })
        
        $cmbProfile.Add_LostFocus({
            if ($cmbProfile.Text.Trim() -and $cmbProfile.Text.Trim() -ne $global:PendingProfile) {
                Show-ProfileConfirmation $cmbProfile.Text.Trim()
            }
        })
        
        # Register confirmation panel handlers
        $btnConfirmProfile.Add_Click({
            if ($global:PendingProfile) {
                Hide-ProfileConfirmation
                Test-ProfileSsoStatus
                Update-RecentProfiles $global:PendingProfile
                $global:PendingProfile = $null
            }
        })
        
        $btnCancelProfile.Add_Click({
            Hide-ProfileConfirmation
            $cmbProfile.SelectedItem = $null
            $cmbProfile.Text = ""
            $global:PendingProfile = $null
        })
        
        $btnCopySsoUrl.Add_Click({
            if ($txtSsoUrl.Text) {
                [System.Windows.Clipboard]::SetText($txtSsoUrl.Text)
                [System.Windows.MessageBox]::Show("SSO URL copied to clipboard", "Copy URL", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
            }
        })
        
        $btnCloseSsoUrl.Add_Click({
            $pnlSsoUrl.Visibility = [System.Windows.Visibility]::Collapsed
        })
        
        # Register filter event handlers for real-time filtering
        $txtNameFilter.Add_TextChanged({ Apply-InstanceFilters })
        $cmbStateFilter.Add_SelectionChanged({ Apply-InstanceFilters })
        $cmbTypeFilter.Add_SelectionChanged({ Apply-InstanceFilters })
        
        # Register search history and favorites handlers
        $cmbSearchHistory.Add_SelectionChanged({ Update-SearchHistoryDropdown })
        $cmbFavorites.Add_SelectionChanged({ Update-FavoritesDropdown })
        $btnAddFavorite.Add_Click({ Add-SearchFavorite })
        $btnRemoveFavorite.Add_Click({ Remove-SearchFavorite })
        
        # Mark initialization as complete
        $global:WindowInitializing = $false
    } catch {
        Write-Warning "Window loaded event failed: $($_.Exception.Message)"
        # Even if initialization fails, allow event handlers to work
        $global:WindowInitializing = $false
    }
})

# Add window location changed event to keep console positioned
$window.Add_LocationChanged({ 
    Set-ConsolePosition
})

# Add window size changed event
$window.Add_SizeChanged({ 
    # Window size changed - no panel management needed
})

# Initialize debug logging
try {
    Write-DebugLog "AWS Management Studio v$script:AppVersion starting" "INFO" "Application"
    Write-DebugLog "PowerShell version: $($PSVersionTable.PSVersion)" "INFO" "Environment"
    Write-DebugLog "Threading model: $([Threading.Thread]::CurrentThread.GetApartmentState())" "INFO" "Environment"
} catch {
    # Debug logging initialization is non-critical
}

# Show window
$lblStatus.Content = "AWS Management Studio v$script:AppVersion - Ready"
Write-DebugLog "Application UI initialized successfully" "INFO" "Application"

# Consolidated cleanup function
function Stop-AllTimersAndJobs {
    try {
        # Stop all background jobs
        Stop-SearchJob
        Stop-SsoCheckJob
        Stop-AllServiceSearchJobs
        Stop-ConnectionMonitoring
        Stop-StatusResetTimer
        Stop-ServiceDiscoveryTimer
        
        # Stop UI timers
        if ($global:ElapsedTimer) {
            $global:ElapsedTimer.Stop()
        }
        
        # Close all panel windows
        if ($script:ActivePanels) {
            foreach ($panel in $script:ActivePanels) {
                if ($panel -and -not $panel.IsClosed) {
                    $panel.Close()
                }
            }
        }
    } catch {
        # Cleanup errors are non-critical
    }
}

# Add cleanup on window closing
$window.Add_Closing({
    Stop-AllTimersAndJobs
    # Don't kill connections on exit to avoid interfering with SSH sessions
})

# Show window with minimal approach - no complex initialization before display
try {
    # Verify window object is valid
    if (-not $window -or $window.GetType().Name -ne "Window") {
        throw "Window object is invalid"
    }
    
    # Show window
    $result = $window.ShowDialog()
    
    if ($result) {
        $result | Out-Null
    }
} catch {
    Write-Error "Window display failed: $($_.Exception.Message)"
    throw
}