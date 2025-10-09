# AWS Management Studio v6.0.3 - Testing Guide

## Current Testing Framework

### Available Test Files
- **test-post-cleanup-validation.ps1** - Comprehensive validation suite (7 categories)
- **test-modular-basic.ps1** - Basic functionality validation
- **test-profile-debug.ps1** - Profile management debugging
- **test-search-debug.ps1** - Search functionality testing
- **test-ui-quick.ps1** - UI component validation

### Enhanced Test Runner
The TestRunner module provides automated test execution with multiple export formats:

```powershell
# Import test runner
Import-Module ..\..\src\Modules\TestRunner.psm1 -Force

# Run automated test suite
Start-AutomatedTestSuite -TestDirectory "..\..\tests" -OutputDirectory "..\..\test-results"
```

## Quick Testing Commands

### Daily Development Testing
```powershell
# Quick validation (5-10 seconds)
..\..\tests\test-modular-basic.ps1

# UI component check
..\..\tests\test-ui-quick.ps1
```

### Pre-Commit Testing
```powershell
# Comprehensive validation
..\..\tests\test-post-cleanup-validation.ps1

# Profile and search testing
..\..\tests\test-profile-debug.ps1
..\..\tests\test-search-debug.ps1
```

### Built-in Menu Testing
The application includes integrated testing via Help menu:
- **Quick Test** - Service discovery and basic validation
- **Comprehensive Test** - Full feature testing with export
- **Integration Test** - Real AWS API testing

## Test Categories

### 1. Architecture Tests
- Module loading and function availability
- PowerShell version and threading requirements
- Assembly loading validation

### 2. Core Functionality Tests
- Settings management and persistence
- Search history and favorites system
- User preferences and configuration

### 3. Security Tests
- Input validation and sanitization
- Command injection prevention
- Profile name validation

### 4. AWS Integration Tests
- Profile management and SSO validation
- Multi-region search capabilities
- Service discovery and validation

### 5. Service Discovery Tests
- Multi-service search functionality
- Service configuration validation
- Error handling and recovery

### 6. Logging Tests
- Debug logging functionality
- Log export capabilities
- Performance tracking

### 7. Performance Tests
- Memory usage validation
- Module load time testing
- UI responsiveness verification

## Test Results Interpretation

### Pass Rates
- **95-100%**: Excellent - Production ready
- **85-94%**: Good - Minor issues to address
- **70-84%**: Fair - Some issues present
- **<70%**: Poor - Significant problems

### Critical Tests (Must Pass)
- PowerShell 7+ requirement
- STA threading mode
- Module loading (all 10 modules)
- Settings management
- WPF assemblies

## Automated Test Export

### Export Formats
```powershell
# JSON export
Export-EnhancedTestResults -Results $results -Format "JSON" -OutputPath "..\..\test-results"

# HTML export
Export-EnhancedTestResults -Results $results -Format "HTML" -OutputPath "..\..\test-results"

# Markdown export
Export-EnhancedTestResults -Results $results -Format "Markdown" -OutputPath "..\..\test-results"
```

### Test Documentation
All test results are automatically documented with:
- Timestamp and version information
- Pass/fail status with details
- Performance metrics
- Error messages and stack traces

## Troubleshooting

### Common Issues
1. **PowerShell Threading**: Run with `pwsh -STA`
2. **Module Loading**: Check file permissions and paths
3. **AWS CLI**: Ensure v2.0+ installed and configured
4. **WPF Assemblies**: Requires .NET Framework 4.7.2+

### Debug Mode
Enable debug mode for detailed logging:
- Press F12 or Ctrl+Shift+I
- Use Help > Enable Debug Mode menu
- Check debug logs via Help > View Debug Logs

## Current Status

**Application Version**: 6.0.3 (Multi-Service Enhanced)  
**Test Framework**: Enhanced with automated documentation  
**Coverage**: 7 test categories with comprehensive validation  
**Export Formats**: JSON, HTML, Markdown  
**Integration**: Built-in menu testing with real-time results  

## Next Steps for Testing

1. **Run comprehensive validation**: `..\..\tests\test-post-cleanup-validation.ps1`
2. **Execute automated suite**: Use TestRunner module
3. **Verify all features**: Manual testing checklist
4. **Capture performance baseline**: Before optimization phases
5. **Document results**: Export in preferred format

This testing framework ensures reliable validation before proceeding with optimization phases.