#requires -version 7.0

# Get application version
. "$PSScriptRoot\Get-AppVersion.ps1"

# Test New Service Discovery System
Write-Host "Testing New Service Discovery System (v$global:AppVersion)..." -ForegroundColor Green

try {
    # Import the new service manager module
    Import-Module "$PSScriptRoot\..\src\Modules\AWSServiceManager.psm1" -Force
    
    Write-Host "✓ AWSServiceManager module imported successfully" -ForegroundColor Green
    
    # Test 1: Verify new service management functions exist
    Write-Host "✓ Testing new service management functions..." -ForegroundColor Yellow
    
    $newFunctions = @(
        'Get-AvailableServices',
        'Get-ServiceConfig', 
        'Search-AWSService',
        'Initialize-ServiceTabs'
    )
    
    foreach ($func in $newFunctions) {
        if (Get-Command $func -ErrorAction SilentlyContinue) {
            Write-Host "✓ $func available" -ForegroundColor Green
        } else {
            Write-Host "✗ $func missing" -ForegroundColor Red
        }
    }
    
    # Test 2: Verify service configuration structure
    Write-Host "✓ Testing service configuration..." -ForegroundColor Yellow
    $availableServices = Get-AvailableServices
    Write-Host "  Available services: $($availableServices -join ', ')" -ForegroundColor Gray
    
    foreach ($service in $availableServices) {
        $config = Get-ServiceConfig -ServiceKey $service
        if ($config -and $config.Name -and $config.SearchCommand) {
            Write-Host "✓ $service configuration valid" -ForegroundColor Green
        } else {
            Write-Host "✗ $service configuration invalid" -ForegroundColor Red
        }
    }
    
    # Test 3: Verify service-specific search scripts exist
    Write-Host "✓ Testing service search scripts..." -ForegroundColor Yellow
    
    # Test that each service has a proper search script
    foreach ($service in @('EC2', 'RDS', 'S3', 'Lambda')) {
        try {
            $searchScript = Get-ServiceSearchScript -ServiceKey $service
            if ($searchScript) {
                Write-Host "✓ $service search script available" -ForegroundColor Green
            } else {
                Write-Host "✗ $service search script missing" -ForegroundColor Red
            }
        } catch {
            Write-Host "✗ $service search script error: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
    
    Write-Host "`n🎉 New Service Discovery System test completed!" -ForegroundColor Green
    Write-Host "📋 New System Benefits:" -ForegroundColor Cyan
    Write-Host "   • Service-specific searches (no mass discovery)" -ForegroundColor White
    Write-Host "   • Targeted AWS CLI calls only when needed" -ForegroundColor White
    Write-Host "   • Configurable service enablement" -ForegroundColor White
    Write-Host "   • Tabbed interface for multiple services" -ForegroundColor White
    Write-Host "   • No background permission testing" -ForegroundColor White
    
} catch {
    Write-Host "✗ Test failed: $($_.Exception.Message)" -ForegroundColor Red
}