# Panel Framework Guidelines - AWS Management Studio

## Overview

The AWS Management Studio uses a JSON-based panel framework for rapid UI development. This document outlines critical patterns, known issues, and best practices to prevent common pitfalls.

## Critical Event Handler Patterns

### ⚠️ CRITICAL: Orphaned Event Handler Prevention

**Issue**: Event handlers referencing non-existent UI elements cause null reference exceptions that silently fail and break panel functionality.

**Example of Problem Code**:
```powershell
# BAD - References non-existent $cancelButton
$cancelButton.Add_Click({
    # This will throw null reference exception
})
```

**Solution Pattern**:
```powershell
# GOOD - Always check for null before adding event handlers
if ($cancelButton) {
    $cancelButton.Add_Click({
        # Safe event handler
    })
}
```

### Event Handler Registration Checklist

Before adding ANY event handler, verify:
- [ ] UI element exists in XAML or is created programmatically
- [ ] Variable name matches exactly (case-sensitive)
- [ ] Element is accessible in current scope ($global: if needed)
- [ ] Null check wraps the Add_Click/Add_SelectionChanged call

### Common Event Handler Mistakes

1. **Copy-Paste Errors**: Copying event handlers without updating variable names
2. **Refactoring Orphans**: Removing UI elements but leaving event handlers
3. **Scope Issues**: Accessing UI elements without proper $global: prefix
4. **Timing Issues**: Registering handlers before UI elements are created

## JSON Panel Framework Patterns

### Panel Configuration Structure

```json
{
  "id": "MyPanel",
  "header": "🔧 My Panel Title",
  "width": 400,
  "height": 500,
  "content": [
    {
      "type": "textbox",
      "name": "txtInput",
      "label": "Input Label:",
      "tooltip": "Helpful tooltip text",
      "validation": "required"
    },
    {
      "type": "button",
      "name": "btnAction",
      "text": "Execute",
      "action": "executeAction"
    }
  ]
}
```

### Supported Control Types

- **textbox**: Single-line text input
- **textarea**: Multi-line text input
- **button**: Action button with click handler
- **checkbox**: Boolean toggle
- **combobox**: Dropdown selection
- **label**: Static text display
- **separator**: Visual divider

### Panel Lifecycle

1. **JSON Loading**: Panel configuration loaded from `src/Config/panels/`
2. **XAML Generation**: Framework converts JSON to WPF XAML
3. **Window Creation**: WPF window created with generated XAML
4. **Event Handler Registration**: Action handlers connected to PowerShell functions
5. **Display**: Panel shown using `.Show()` method (not `.ShowDialog()`)
6. **Cleanup**: Panel closed and resources disposed

## Known Issues & Solutions

### Issue 1: ShowDialog() vs Show()

**Problem**: `.ShowDialog()` causes null reference exceptions in some scenarios

**Solution**: Always use `.Show()` for panel windows
```powershell
# BAD
$window.ShowDialog()

# GOOD
$window.Show()
```

### Issue 2: DoEvents() Null Reference

**Problem**: `[System.Windows.Forms.Application]::DoEvents()` can fail with null reference

**Solution**: Use try-catch with WPF dispatcher fallback
```powershell
try {
    [System.Windows.Forms.Application]::DoEvents()
} catch {
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke(
        [Action]{}, 
        [System.Windows.Threading.DispatcherPriority]::Background
    )
}
```

### Issue 3: Global Variable Access

**Problem**: UI elements not accessible from event handlers or functions

**Solution**: Use `$global:` prefix for UI elements that need cross-scope access
```powershell
# In main script
$global:btnSettings = $window.FindName("btnSettings")

# In module function
if ($global:btnSettings) {
    $global:btnSettings.Add_Click({ ... })
}
```

### Issue 4: Panel Toggle State Management

**Problem**: Multiple panels opening or state getting out of sync

**Solution**: Use script-level state variables and proper cleanup
```powershell
$script:SettingsPanelOpen = $false

function Switch-SettingsPanel {
    if ($script:SettingsPanelOpen) {
        # Close existing panel
        if ($script:SettingsWindow) {
            $script:SettingsWindow.Close()
            $script:SettingsWindow = $null
        }
        $script:SettingsPanelOpen = $false
    } else {
        # Open new panel
        $script:SettingsWindow = Show-SettingsPanel
        $script:SettingsPanelOpen = $true
    }
}
```

## Best Practices

### 1. Defensive Programming

Always assume UI elements might not exist:
```powershell
# Check before access
if ($element -and $element.GetType().Name -ne "String") {
    $element.Add_Click({ ... })
}
```

### 2. Comprehensive Error Handling

Wrap event handler registration in try-catch:
```powershell
try {
    if ($btnAction) {
        $btnAction.Add_Click({
            try {
                # Action code
            } catch {
                Write-Warning "Action failed: $_"
            }
        })
    }
} catch {
    Write-Warning "Failed to register event handler: $_"
}
```

### 3. Debug Output for Troubleshooting

Add debug output to track panel lifecycle:
```powershell
Write-Host "[DEBUG] Opening panel: $panelId"
Write-Host "[DEBUG] Panel state: $script:PanelOpen"
Write-Host "[DEBUG] Panel window: $($script:PanelWindow -ne $null)"
```

### 4. Consistent Naming Conventions

- **Buttons**: `btn` prefix (e.g., `btnSave`, `btnCancel`)
- **TextBoxes**: `txt` prefix (e.g., `txtName`, `txtDescription`)
- **ComboBoxes**: `cmb` prefix (e.g., `cmbRegion`, `cmbType`)
- **CheckBoxes**: `chk` prefix (e.g., `chkAutoRefresh`)
- **Labels**: `lbl` prefix (e.g., `lblStatus`, `lblCount`)

### 5. Panel Configuration Validation

Validate JSON configuration before loading:
```powershell
function Test-PanelConfiguration {
    param([string]$ConfigPath)
    
    if (-not (Test-Path $ConfigPath)) {
        throw "Panel configuration not found: $ConfigPath"
    }
    
    $config = Get-Content $ConfigPath | ConvertFrom-Json
    
    if (-not $config.id) {
        throw "Panel configuration missing required 'id' field"
    }
    
    if (-not $config.content) {
        throw "Panel configuration missing required 'content' field"
    }
    
    return $config
}
```

## Testing Checklist

Before deploying panel changes:
- [ ] All event handlers have null checks
- [ ] No orphaned event handlers for removed UI elements
- [ ] Panel opens and closes without errors
- [ ] Panel state management works correctly
- [ ] All buttons and controls are functional
- [ ] Error handling catches and logs failures
- [ ] Debug output confirms expected behavior
- [ ] Memory cleanup occurs on panel close

## Debugging Techniques

### 1. Enable Debug Output

```powershell
$DebugPreference = "Continue"
Write-Debug "Panel state: $script:PanelOpen"
```

### 2. Trace Event Handler Registration

```powershell
Write-Host "[TRACE] Registering event handler for: $elementName"
if ($element) {
    Write-Host "[TRACE] Element found: $($element.GetType().Name)"
} else {
    Write-Host "[TRACE] Element is NULL"
}
```

### 3. Validate UI Element Existence

```powershell
function Test-UIElement {
    param([string]$ElementName)
    
    $element = Get-Variable -Name $ElementName -Scope Global -ErrorAction SilentlyContinue
    
    if ($element) {
        Write-Host "✓ $ElementName exists: $($element.Value.GetType().Name)"
    } else {
        Write-Warning "✗ $ElementName does not exist"
    }
}
```

## Future Enhancements

### Planned Improvements

1. **Automatic Validation**: Framework validates event handlers against XAML
2. **Type Safety**: Compile-time checking for UI element references
3. **Hot Reload**: Update panels without application restart
4. **Visual Designer**: GUI tool for panel configuration
5. **Template Library**: Reusable panel templates for common patterns

### Framework Evolution

The panel framework is designed to evolve toward:
- **Declarative Event Binding**: JSON-defined event handlers
- **Data Binding**: Automatic synchronization between UI and data
- **Validation Rules**: Built-in input validation from JSON config
- **Theming Support**: Consistent styling across all panels
- **Accessibility**: ARIA labels and keyboard navigation

## Related Documentation

- **[DEVELOPMENT_GUIDE.md](DEVELOPMENT_GUIDE.md)**: Overall development patterns
- **[CONTRIBUTING.md](CONTRIBUTING.md)**: Code standards and procedures
- **[UI.psm1](../../src/Modules/UI.psm1)**: Event handler implementation
- **[PanelFramework.psm1](../../src/Modules/PanelFramework.psm1)**: Panel framework code

## Version History

- **v6.3.1**: Initial documentation based on settings panel bug fix
- **Future**: Will be updated as framework evolves

---

**Remember**: The most common panel bugs come from orphaned event handlers and missing null checks. Always validate UI element existence before registration!
