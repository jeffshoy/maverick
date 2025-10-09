# Test compatibility fixes
function Test-ProfileNameSafety {
    param([string]$ProfileName)
    
    if (-not $ProfileName) { return $false }
    
    $dangerousChars = @('`', '$', '&', '|', ';', '<', '>', '"', "'", '\', '/', '(', ')')
    foreach ($char in $dangerousChars) {
        if ($ProfileName.IndexOf($char) -ge 0) {
            return $false
        }
    }
    return $true
}

Export-ModuleMember -Function Test-ProfileNameSafety