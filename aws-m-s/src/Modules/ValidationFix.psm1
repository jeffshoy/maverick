# Validation Fix Module - Inline validation for UI components
# Version: 1.0.0

# Validation constants - exported as script variables
$script:DangerousChars = @('`', '$', '&', '|', ';', '<', '>', '"', "'", '\', '/', '(', ')')

# Simple validation check - returns hashtable with results
function Get-ValidationResult {
    param([string]$InputText, [string]$ServiceType = "EC2")
    
    $result = @{
        IsValid = $true
        Issues = @()
        Message = ""
    }
    
    # Check for dangerous characters inline
    foreach ($char in $script:DangerousChars) {
        if ($InputText.IndexOf($char) -ge 0) {
            $result.IsValid = $false
            $result.Issues += "Contains dangerous character: $char"
        }
    }
    
    # Length check
    if ($InputText.Length -gt 255) {
        $result.IsValid = $false
        $result.Issues += "Input too long (max 255 characters)"
    }
    
    # Set message
    if (-not $result.IsValid) {
        $result.Message = "Invalid input: " + ($result.Issues -join ", ")
    }
    
    return $result
}

# Add missing functions for test compatibility
function Test-ProfileNameSafety {
    param([string]$ProfileName)
    $validation = Get-ValidationResult -InputText $ProfileName -ServiceType "Profile"
    return $validation.IsValid
}

function Get-SafeProfileName {
    param([string]$ProfileName)
    # Remove dangerous characters and return safe version
    $safeName = $ProfileName
    foreach ($char in $script:DangerousChars) {
        $safeName = $safeName.Replace($char, '')
    }
    return $safeName
}

Export-ModuleMember -Function Get-ValidationResult, Test-ProfileNameSafety, Get-SafeProfileName