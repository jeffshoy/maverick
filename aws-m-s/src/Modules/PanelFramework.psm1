#requires -version 7.0
<#
.SYNOPSIS
    Panel Framework Module for AWS Management Studio

.DESCRIPTION
    Provides streamlined panel creation using JSON configuration
#>

Set-StrictMode -Version Latest

function New-ConfigurablePanel {
    <#
    .SYNOPSIS
        Create a new docked panel from JSON configuration
    #>
    param(
        [string]$ConfigPath,
        [hashtable]$EventHandlers = @{},
        [hashtable]$DataContext = @{}
    )
    
    try {
        # Load panel configuration
        $config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
        
        # Get window reference
        $window = [System.Windows.Window]::GetWindow($global:SidePanelContainer)
        
        # Check if panel already exists
        $existingPanel = $global:SidePanelContainer.Children | Where-Object { $_.Tag -eq $config.id }
        
        if ($existingPanel) {
            # Close existing panel
            $global:SidePanelContainer.Children.Remove($existingPanel)
            
            # Shrink window for each removed panel
            if ($window) { $window.Width = $window.Width - $config.width }
            
            if ($global:SidePanelContainer.Children.Count -eq 0) {
                $global:SidePanelContainer.Visibility = [System.Windows.Visibility]::Collapsed
            }
            return
        }
        
        # Create new panel
        $panel = New-Object System.Windows.Controls.GroupBox
        $panel.Header = $config.header
        $panel.Width = $config.width
        $panel.MaxWidth = $config.width
        $panel.Margin = New-Object System.Windows.Thickness(10, 0, 0, 0)
        $panel.Padding = New-Object System.Windows.Thickness(10)
        $panel.Tag = $config.id
        
        # Create main grid
        $grid = New-Object System.Windows.Controls.Grid
        
        # Add row definitions
        $headerRow = New-Object System.Windows.Controls.RowDefinition
        $headerRow.Height = [System.Windows.GridLength]::Auto
        $contentRow = New-Object System.Windows.Controls.RowDefinition
        $contentRow.Height = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
        $buttonRow = New-Object System.Windows.Controls.RowDefinition
        $buttonRow.Height = [System.Windows.GridLength]::Auto
        
        [void]$grid.RowDefinitions.Add($headerRow)
        [void]$grid.RowDefinitions.Add($contentRow)
        [void]$grid.RowDefinitions.Add($buttonRow)
        
        # Create header with close button
        $headerGrid = New-Object System.Windows.Controls.Grid
        $col1 = New-Object System.Windows.Controls.ColumnDefinition
        $col1.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
        $col2 = New-Object System.Windows.Controls.ColumnDefinition
        $col2.Width = [System.Windows.GridLength]::Auto
        [void]$headerGrid.ColumnDefinitions.Add($col1)
        [void]$headerGrid.ColumnDefinitions.Add($col2)
        
        $headerLabel = New-Object System.Windows.Controls.Label
        $headerLabel.Content = $config.title
        $headerLabel.FontWeight = [System.Windows.FontWeights]::Bold
        [System.Windows.Controls.Grid]::SetColumn($headerLabel, 0)
        
        $closeButton = New-Object System.Windows.Controls.Button
        $closeButton.Content = "✕"
        $closeButton.Width = 30
        $closeButton.Height = 25
        $closeButton.Margin = New-Object System.Windows.Thickness(5, 0, 0, 0)
        $closeButton.ToolTip = "Close panel"
        [System.Windows.Controls.Grid]::SetColumn($closeButton, 1)
        
        $closeButton.Add_Click({
            New-ConfigurablePanel -ConfigPath $ConfigPath
        }.GetNewClosure())
        
        [void]$headerGrid.Children.Add($headerLabel)
        [void]$headerGrid.Children.Add($closeButton)
        [System.Windows.Controls.Grid]::SetRow($headerGrid, 0)
        
        # Create content area
        $contentStack = New-Object System.Windows.Controls.StackPanel
        $contentStack.Margin = New-Object System.Windows.Thickness(0, 10, 0, 10)
        
        # Build content from configuration
        $controls = @{}
        foreach ($element in $config.content) {
            $control = New-PanelControl -ElementConfig $element -DataContext $DataContext -EventHandlers $EventHandlers -Controls ([ref]$controls)
            if ($control) {
                [void]$contentStack.Children.Add($control)
                if ($element.PSObject.Properties['name'] -and $element.name) {
                    $controls[$element.name] = $control
                }
            }
        }
        
        [System.Windows.Controls.Grid]::SetRow($contentStack, 1)
        
        # Create button panel if specified
        if ($config.buttons) {
            $buttonPanel = New-Object System.Windows.Controls.StackPanel
            $buttonPanel.Orientation = "Horizontal"
            $buttonPanel.HorizontalAlignment = "Center"
            $buttonPanel.Margin = New-Object System.Windows.Thickness(0, 10, 0, 0)
            
            foreach ($buttonConfig in $config.buttons) {
                $button = New-Object System.Windows.Controls.Button
                $button.Content = $buttonConfig.text
                $button.Width = $buttonConfig.width
                $button.Height = $buttonConfig.height
                $button.Margin = New-Object System.Windows.Thickness(5, 0, 5, 0)
                
                if ($buttonConfig.style) {
                    switch ($buttonConfig.style) {
                        "primary" { $button.Background = [System.Windows.Media.Brushes]::LightBlue }
                        "success" { $button.Background = [System.Windows.Media.Brushes]::LightGreen }
                        "warning" { $button.Background = [System.Windows.Media.Brushes]::Orange }
                        "danger" { $button.Background = [System.Windows.Media.Brushes]::LightCoral }
                    }
                }
                
                if ($EventHandlers.ContainsKey($buttonConfig.action)) {
                    $handler = $EventHandlers[$buttonConfig.action]
                    $button.Add_Click({
                        & $handler $controls $DataContext
                    }.GetNewClosure())
                }
                
                [void]$buttonPanel.Children.Add($button)
            }
            
            [System.Windows.Controls.Grid]::SetRow($buttonPanel, 2)
            [void]$grid.Children.Add($buttonPanel)
        }
        
        # Add all elements to grid
        [void]$grid.Children.Add($headerGrid)
        [void]$grid.Children.Add($contentStack)
        
        # Set grid as panel content
        $panel.Content = $grid
        
        # Add panel to container and expand window
        [void]$global:SidePanelContainer.Children.Add($panel)
        
        # Expand window width for each new panel
        if ($window) { 
            $window.Width = $window.Width + $config.width 
        }
        
        $global:SidePanelContainer.Visibility = [System.Windows.Visibility]::Visible
        
        # Store controls in panel for later access
        $panel | Add-Member -NotePropertyName 'PanelControls' -NotePropertyValue $controls -Force
        
        return @{
            Panel = $panel
            Controls = $controls
            Config = $config
        }
        
    } catch {
        Write-Warning "Failed to create configurable panel: $($_.Exception.Message)"
        return $null
    }
}

function New-PanelControl {
    <#
    .SYNOPSIS
        Create a WPF control from configuration
    #>
    param(
        [object]$ElementConfig,
        [hashtable]$DataContext,
        [hashtable]$EventHandlers = @{},
        [ref]$Controls
    )
    
    switch ($ElementConfig.type) {
        "label" {
            $control = New-Object System.Windows.Controls.Label
            $control.Content = $ElementConfig.text
            if ($ElementConfig.PSObject.Properties['bold'] -and $ElementConfig.bold) { $control.FontWeight = "Bold" }
            if ($ElementConfig.PSObject.Properties['margin'] -and $ElementConfig.margin) { 
                $margins = $ElementConfig.margin -split ','
                if ($margins.Count -eq 1) {
                    $control.Margin = New-Object System.Windows.Thickness([double]$margins[0])
                } elseif ($margins.Count -eq 4) {
                    $control.Margin = New-Object System.Windows.Thickness([double]$margins[0], [double]$margins[1], [double]$margins[2], [double]$margins[3])
                }
            }
            return $control
        }
        
        "textbox" {
            $control = New-Object System.Windows.Controls.TextBox
            if ($ElementConfig.height) { $control.Height = $ElementConfig.height }
            if ($ElementConfig.PSObject.Properties['multiline'] -and $ElementConfig.multiline) { 
                $control.TextWrapping = "Wrap"
                $control.AcceptsReturn = $true
                $control.VerticalScrollBarVisibility = "Auto"
            }
            if ($ElementConfig.PSObject.Properties['margin'] -and $ElementConfig.margin) { 
                $margins = $ElementConfig.margin -split ','
                if ($margins.Count -eq 1) {
                    $control.Margin = New-Object System.Windows.Thickness([double]$margins[0])
                } elseif ($margins.Count -eq 4) {
                    $control.Margin = New-Object System.Windows.Thickness([double]$margins[0], [double]$margins[1], [double]$margins[2], [double]$margins[3])
                }
            }
            if ($ElementConfig.PSObject.Properties['placeholder'] -and $ElementConfig.placeholder) { $control.Text = $ElementConfig.placeholder }
            return $control
        }
        
        "combobox" {
            $control = New-Object System.Windows.Controls.ComboBox
            if ($ElementConfig.PSObject.Properties['width'] -and $ElementConfig.width) { $control.Width = $ElementConfig.width }
            if ($ElementConfig.PSObject.Properties['items'] -and $ElementConfig.items) {
                foreach ($item in $ElementConfig.items) {
                    [void]$control.Items.Add($item)
                }
            }
            if ($ElementConfig.PSObject.Properties['selectedIndex'] -and $ElementConfig.selectedIndex -ne $null) { 
                try { $control.SelectedIndex = $ElementConfig.selectedIndex } catch { }
            }
            if ($ElementConfig.PSObject.Properties['margin'] -and $ElementConfig.margin) { 
                $margins = $ElementConfig.margin -split ','
                if ($margins.Count -eq 1) {
                    $control.Margin = New-Object System.Windows.Thickness([double]$margins[0])
                } elseif ($margins.Count -eq 4) {
                    $control.Margin = New-Object System.Windows.Thickness([double]$margins[0], [double]$margins[1], [double]$margins[2], [double]$margins[3])
                }
            }
            return $control
        }
        
        "button" {
            $control = New-Object System.Windows.Controls.Button
            $control.Content = $ElementConfig.text
            if ($ElementConfig.PSObject.Properties['width'] -and $ElementConfig.width) { $control.Width = $ElementConfig.width }
            if ($ElementConfig.PSObject.Properties['height'] -and $ElementConfig.height) { $control.Height = $ElementConfig.height }
            if ($ElementConfig.PSObject.Properties['margin'] -and $ElementConfig.margin) { 
                $margins = $ElementConfig.margin -split ','
                if ($margins.Count -eq 1) {
                    $control.Margin = New-Object System.Windows.Thickness([double]$margins[0])
                } elseif ($margins.Count -eq 4) {
                    $control.Margin = New-Object System.Windows.Thickness([double]$margins[0], [double]$margins[1], [double]$margins[2], [double]$margins[3])
                }
            }
            
            # Add event handler if specified
            if ($ElementConfig.PSObject.Properties['name'] -and $ElementConfig.name -and $EventHandlers.ContainsKey($ElementConfig.name)) {
                $handler = $EventHandlers[$ElementConfig.name]
                $control.Add_Click({
                    & $handler $Controls.Value $DataContext
                }.GetNewClosure())
            }
            
            return $control
        }
        
        "stackpanel" {
            $control = New-Object System.Windows.Controls.StackPanel
            if ($ElementConfig.PSObject.Properties['orientation'] -and $ElementConfig.orientation) { $control.Orientation = $ElementConfig.orientation }
            if ($ElementConfig.PSObject.Properties['margin'] -and $ElementConfig.margin) { 
                $margins = $ElementConfig.margin -split ','
                if ($margins.Count -eq 1) {
                    $control.Margin = New-Object System.Windows.Thickness([double]$margins[0])
                } elseif ($margins.Count -eq 4) {
                    $control.Margin = New-Object System.Windows.Thickness([double]$margins[0], [double]$margins[1], [double]$margins[2], [double]$margins[3])
                }
            }
            
            if ($ElementConfig.PSObject.Properties['children'] -and $ElementConfig.children) {
                foreach ($child in $ElementConfig.children) {
                    $childControl = New-PanelControl -ElementConfig $child -DataContext $DataContext -EventHandlers $EventHandlers -Controls $Controls
                    if ($childControl) {
                        [void]$control.Children.Add($childControl)
                    }
                }
            }
            return $control
        }
        
        default {
            Write-Warning "Unknown control type: $($ElementConfig.type)"
            return $null
        }
    }
}

Export-ModuleMember -Function New-ConfigurablePanel, New-PanelControl