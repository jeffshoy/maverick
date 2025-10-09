# Core module - Settings and basic functions
function Get-DefaultSettings {
    [pscustomobject]@{
        SchemaVersion = 4
        Defaults = [pscustomobject]@{
            SecureRdpEnabled = $true
            OnlyRunning = $true
            DefaultConnectionType = "RDP"
            DarkMode = "Auto"
        }
        PreferredRegions = @('us-east-1','us-west-2','ca-central-1')
        RecentProfiles = @()
    }
}

function Get-Settings {
    $settingsDir = Join-Path $env:APPDATA 'AWS-EC2-Management-Studio-WPF'
    $settingsFile = Join-Path $settingsDir 'settings.json'
    
    try {
        if (Test-Path -LiteralPath $settingsFile) {
            $rawContent = Get-Content -LiteralPath $settingsFile -Raw -ErrorAction Stop
            $settingsObject = $rawContent | ConvertFrom-Json -Depth 32
            if ($null -ne $settingsObject -and $settingsObject.SchemaVersion -ge 1) {
                return $settingsObject 
            }
        }
    } catch { 
        Write-Warning "Failed to load settings: $($_.Exception.Message)"
    }
    return Get-DefaultSettings
}

function Set-Settings {
    param([Parameter(Mandatory)] $Settings)
    $settingsDir = Join-Path $env:APPDATA 'AWS-EC2-Management-Studio-WPF'
    $settingsFile = Join-Path $settingsDir 'settings.json'
    
    try {
        if (-not (Test-Path -LiteralPath $settingsDir)) {
            New-Item -ItemType Directory -Path $settingsDir -Force | Out-Null
        }
        $Settings | ConvertTo-Json -Depth 32 | Set-Content -LiteralPath $settingsFile -Encoding UTF8
    } catch {
        Write-Error "Failed to save settings: $($_.Exception.Message)"
    }
}

function Get-DefaultUserSettings {
    [pscustomobject]@{
        SchemaVersion = 1
        General = [pscustomobject]@{
            AutoRefreshEnabled = $true
            RefreshInterval = 120
            AutoOpenConnectionManager = $false
        }
        Services = @('EC2', 'RDS', 'S3', 'Lambda')
        SpacingType = 'Balanced'
    }
}

function Get-UserSettings {
    $settingsDir = Join-Path $env:APPDATA 'AWS-EC2-Management-Studio-WPF'
    $userSettingsFile = Join-Path $settingsDir 'user-settings.json'
    
    try {
        if (Test-Path -LiteralPath $userSettingsFile) {
            $rawContent = Get-Content -LiteralPath $userSettingsFile -Raw -ErrorAction Stop
            $userSettings = $rawContent | ConvertFrom-Json -Depth 32
            if ($null -ne $userSettings -and $userSettings.SchemaVersion -ge 1) {
                return $userSettings
            }
        }
    } catch {
        Write-Warning "Failed to load user settings: $($_.Exception.Message)"
    }
    return Get-DefaultUserSettings
}

function Set-UserSettings {
    param([Parameter(Mandatory)] $UserSettings)
    $settingsDir = Join-Path $env:APPDATA 'AWS-EC2-Management-Studio-WPF'
    $userSettingsFile = Join-Path $settingsDir 'user-settings.json'
    
    try {
        if (-not (Test-Path -LiteralPath $settingsDir)) {
            New-Item -ItemType Directory -Path $settingsDir -Force | Out-Null
        }
        $UserSettings | ConvertTo-Json -Depth 32 | Set-Content -LiteralPath $userSettingsFile -Encoding UTF8
    } catch {
        Write-Error "Failed to save user settings: $($_.Exception.Message)"
    }
}

# Search History Management
function Get-SearchHistory {
    $settingsDir = Join-Path $env:APPDATA 'AWS-EC2-Management-Studio-WPF'
    $searchHistoryFile = Join-Path $settingsDir 'search-history.json'
    
    try {
        if (Test-Path -LiteralPath $searchHistoryFile) {
            $history = Get-Content -LiteralPath $searchHistoryFile -Raw | ConvertFrom-Json
            return $history.History
        }
        return @()
    } catch {
        return @()
    }
}

function Add-SearchHistory {
    param([string]$SearchTerm)
    
    if (-not $SearchTerm.Trim()) { return }
    
    $settingsDir = Join-Path $env:APPDATA 'AWS-EC2-Management-Studio-WPF'
    $searchHistoryFile = Join-Path $settingsDir 'search-history.json'
    
    try {
        $history = @(Get-SearchHistory)
        $history = @($SearchTerm) + @($history | Where-Object { $_ -ne $SearchTerm } | Select-Object -First 6)
        
        $historyData = @{ History = $history }
        $historyData | ConvertTo-Json | Set-Content -LiteralPath $searchHistoryFile -Force
    } catch {
        Write-Warning "Failed to save search history: $($_.Exception.Message)"
    }
}

# Favorites Management
function Get-Favorites {
    $settingsDir = Join-Path $env:APPDATA 'AWS-EC2-Management-Studio-WPF'
    $favoritesFile = Join-Path $settingsDir 'favorites.json'
    
    try {
        if (Test-Path -LiteralPath $favoritesFile) {
            $favorites = Get-Content -LiteralPath $favoritesFile -Raw | ConvertFrom-Json
            return $favorites.Favorites
        }
        return @()
    } catch {
        return @()
    }
}

function Add-Favorite {
    param([string]$Name, [string]$SearchTerm, [string]$StateFilter, [string]$TypeFilter)
    
    if (-not $Name.Trim()) { return }
    
    $settingsDir = Join-Path $env:APPDATA 'AWS-EC2-Management-Studio-WPF'
    $favoritesFile = Join-Path $settingsDir 'favorites.json'
    
    try {
        $favorites = @(Get-Favorites)
        $newFavorite = @{
            Name = $Name.Trim()
            SearchTerm = $SearchTerm
            StateFilter = $StateFilter
            TypeFilter = $TypeFilter
            Created = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        }
        
        $favorites = @($newFavorite) + @($favorites | Where-Object { $_.Name -ne $Name.Trim() })
        $favoritesData = @{ Favorites = $favorites }
        $favoritesData | ConvertTo-Json | Set-Content -LiteralPath $favoritesFile -Force
    } catch {
        Write-Warning "Failed to save favorite: $($_.Exception.Message)"
    }
}

function Remove-Favorite {
    param([string]$Name)
    
    $settingsDir = Join-Path $env:APPDATA 'AWS-EC2-Management-Studio-WPF'
    $favoritesFile = Join-Path $settingsDir 'favorites.json'
    
    try {
        $favorites = @(Get-Favorites | Where-Object { $_.Name -ne $Name })
        $favoritesData = @{ Favorites = $favorites }
        $favoritesData | ConvertTo-Json | Set-Content -LiteralPath $favoritesFile -Force
    } catch {
        Write-Warning "Failed to remove favorite: $($_.Exception.Message)"
    }
}

function Clear-SearchHistory {
    $settingsDir = Join-Path $env:APPDATA 'AWS-EC2-Management-Studio-WPF'
    $searchHistoryFile = Join-Path $settingsDir 'search-history.json'
    
    try {
        $historyData = @{ History = @() }
        $historyData | ConvertTo-Json | Set-Content -LiteralPath $searchHistoryFile -Force
    } catch {
        Write-Warning "Failed to clear search history: $($_.Exception.Message)"
    }
}

function Clear-Favorites {
    $settingsDir = Join-Path $env:APPDATA 'AWS-EC2-Management-Studio-WPF'
    $favoritesFile = Join-Path $settingsDir 'favorites.json'
    
    try {
        $favoritesData = @{ Favorites = @() }
        $favoritesData | ConvertTo-Json | Set-Content -LiteralPath $favoritesFile -Force
    } catch {
        Write-Warning "Failed to clear favorites: $($_.Exception.Message)"
    }
}

# Add missing Save-Settings function for test compatibility
function Save-Settings {
    param([Parameter(Mandatory)] $Settings)
    Set-Settings $Settings
}

Export-ModuleMember -Function *