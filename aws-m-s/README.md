# AWS Management Studio

**Current Version:** 6.4.0 (SMB Share Bug Tracking - Implementation) - ✅ **PRODUCTION READY**  
**Platform:** PowerShell 7.0+ with WPF UI Framework  
**Target Users:** Site Reliability Engineers, CloudOps Teams, Technical Operations

## 🚀 Overview

AWS Management Studio is a comprehensive PowerShell-based WPF application designed specifically for Site Reliability Engineers and technical operations teams. It provides unified EC2 instance management with AWS SSO integration, connection management (RDP, SSH, Port Forwarding), and enterprise-grade operational features. The application focuses on efficient EC2 resource management with SRE-focused workflows for incident response and infrastructure operations.

## ✨ Key Features

### 🔗 Connection Management
- **RDP Connections**: Direct Windows instance access via AWS Systems Manager
- **SSH Connections**: Linux instance access with Windows Terminal integration  
- **Port Forwarding**: Secure database/service tunneling with dynamic port allocation
- **Connection Manager**: Real-time monitoring and termination of active connections
- **Panel System**: Configurable side panels for clean workflow management

### 🌐 EC2 Instance Management
- **Multi-Region Search**: Parallel EC2 instance discovery across us-east-1, us-west-2, ca-central-1
- **Real-Time Filtering**: Live filtering by instance name, state, and type
- **Async Operations**: Non-blocking searches with real-time cancellation support
- **Health Status**: Instance health monitoring with visual indicators
- **Connection Context Menu**: Right-click access to RDP, SSH, and Port Forward options
- **Service Discovery**: Background validation of AWS service accessibility

### 🔍 Search & Discovery Features
- **Search History**: Automatic capture with 3-second debounce (7 items max)
- **Favorites System**: Named search combinations with complete filter state
- **Auto-Refresh**: Configurable automatic instance list updates
- **Real-Time Filtering**: Live filtering by instance name, state, and type
- **Background Service Discovery**: Automated validation of AWS service accessibility
- **Column Spacing**: Configurable DataGrid spacing options for improved readability

### 🐛 Bug Reporting System
- **Integrated Bug Tracker**: Built-in bug reporting with structured forms
- **Screenshot Capture**: Secure application window screenshots
- **File Attachment Support**: Attach existing image files with validation
- **SMB Share Integration**: Automatic bug sharing via network share for team visibility
- **Local Fallback**: Works without network share, saves locally only
- **Export Capabilities**: HTML export of bug reports for sharing
- **Panel Framework**: JSON-configurable UI panels for rapid development

### 🚀 Automated Testing Framework
- **Multiple Test Suites**: Quick, Comprehensive, Basic, Simple, Discovery, and Validation tests
- **Centralized Test Runner**: Single entry point for all testing operations
- **Multiple Output Formats**: Console, JSON, and HTML reporting
- **Version Tracking**: Automatic testing when version changes are detected
- **Debug Logging**: Comprehensive logging system with export capabilities

### 🔐 Enterprise Security & Authentication
- **AWS SSO Integration**: Complete SSO profile lifecycle management
- **Multi-Account Support**: Support for multiple AWS accounts and profiles
- **Credential Security**: Windows Credential Manager integration
- **Input Sanitization**: Enterprise-grade validation preventing command injection
- **Audit Trail**: All operations logged via AWS CloudTrail

## 🏗️ Architecture

### Modular Design (v6.0.0+)
```
Main Application (aws-management-studio.ps1)
├── Core.psm1 (Settings & Configuration)
├── AWS.psm1 (AWS Operations & Connections)
├── UI.psm1 (User Interface & Event Handling)
├── AWSServiceManager.psm1 (Service Management)
├── BackgroundServiceDiscovery.psm1 (Service Discovery)
├── BugTracker.psm1 (Bug Reporting System)
├── DebugLogger.psm1 (Debug Logging)
├── MultiServiceSearch.psm1 (Multi-Service Search)
├── PanelFramework.psm1 (Configurable Panel System)
├── TestFix.psm1 (Test Fixes)
├── TestRunner.psm1 (Automated Testing Framework)
├── UniversalAWSDiscovery.psm1 (AWS Discovery)
└── VersionTracker.psm1 (Version Management)
```

### 🎆 Configurable Panel Framework
Rapid development of new UI screens through JSON configuration:

```json
{
  "id": "MyPanel",
  "header": "🔧 My Panel",
  "content": [
    {
      "type": "textbox",
      "name": "txtInput",
      "tooltip": "Enter value here"
    },
    {
      "type": "button",
      "text": "Execute",
      "action": "executeAction"
    }
  ]
}
```

**Framework Benefits:**
- **JSON-Driven UI**: Define panels without writing XAML
- **Event Handler Integration**: Connect UI events to PowerShell functions
- **Consistent Styling**: Automatic theming and layout management
- **Rapid Prototyping**: New panels in minutes, not hours
- **Reusable Components**: Standard controls with validation

### AWS Service Coverage
- **Primary Focus**: EC2 instance management with full connection capabilities
- **Service Discovery**: Background validation of AWS service accessibility
- **Framework Ready**: Modular architecture supports additional AWS services
- **Multi-Service Search**: Framework for expanding to RDS, S3, Lambda, and other services
- **AWS CLI Integration**: Consistent AWS CLI integration pattern for service expansion

## 🚀 Quick Start

### Prerequisites
- **PowerShell 7.0+** (Required for WPF support)
- **AWS CLI v2.0+** (Required for AWS operations)
- **.NET Framework 4.7.2+** (Required for WPF assemblies)
- **Windows 10/11** (Required for optimal WPF and dark mode support)

### Installation
1. Clone or download the repository
2. Ensure PowerShell execution policy allows script execution:
   ```powershell
   Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
   ```
3. Launch the application using one of the available launchers:
   ```powershell
   # Recommended: PowerShell launcher with enhanced features
   .\Launch-AWSStudio.ps1
   
   # Alternative: Batch file launcher
   .\Launch-AWSStudio.cmd
   
   # Enterprise: Silent executable (no console window)
   .\AWSStudio.exe
   
   # Direct execution
   pwsh -STA -File .\scripts\aws-management-studio.ps1
   ```

### Launcher Options
- **AWSStudio.exe**: ⭐ **RECOMMENDED** - Silent executable for enterprise deployment
- **Launch-AWSStudio.ps1**: Full-featured PowerShell launcher with error handling
- **Launch-AWSStudio.cmd**: Batch file launcher for environments requiring .cmd files
- **Direct Script**: Run the main application script directly with PowerShell STA mode

### First Run
1. Select an AWS profile from the dropdown
2. Click "Check Status" to validate SSO authentication
3. Click "🔍 Search" to discover EC2 instances
4. Right-click instances for connection options (RDP, SSH, Port Forward)
5. Use the Connection Manager panel to monitor active connections

## 🔧 Configuration

### Application Configuration
Configure application settings and preferences:
```powershell
# Access settings through the UI
# Click the ⚙️ Settings button or use Edit > Preferences menu

# Settings are automatically saved to:
# %APPDATA%/AWS-Management-Studio/
```

### Settings Location
```
%APPDATA%/AWS-Management-Studio/
├── settings.json              # Application settings
├── user-settings.json         # User preferences
├── search-history.json        # Search history (7 items)
├── favorites.json             # Named search combinations
└── service-config.json        # AWS service enablement
```

## 🧪 Testing & Validation

### Automated Test Framework
- **Multiple Test Suites**: Quick, Comprehensive, Basic, Simple, Discovery, and Validation tests
- **Centralized Test Runner**: Single entry point with Run-Tests.ps1
- **Quick Validation**: 5-second daily development checks
- **Multiple Output Formats**: Console, JSON, HTML reporting
- **CI/CD Ready**: Automated testing with exit codes and TEST_RESULTS.md updates

### Test Suites
```powershell
# Quick daily validation (5 seconds)
.\tests\Run-Tests.ps1 -TestSuite Quick

# Comprehensive testing (30-60 seconds)
.\tests\Run-Tests.ps1 -TestSuite Comprehensive

# Integration testing with AWS (2-5 minutes)
.\tests\Run-Tests.ps1 -TestSuite Integration

# Run all test suites
.\tests\Run-Tests.ps1 -TestSuite All -OutputFormat HTML
```

### Test Coverage
- **Environment Prerequisites**: PowerShell, threading, AWS CLI
- **Module Loading**: All 13 modules with function validation
- **Settings Management**: Configuration and persistence
- **AWS Integration**: Profile management and EC2 operations
- **UI Components**: XAML parsing and DataGrid operations
- **Async Operations**: Background processing and cancellation
- **Error Handling**: Exception handling and recovery
- **Service Discovery**: Background AWS service validation

### Individual Test Scripts
```powershell
# Individual component testing
.\tests\test-basic.ps1
.\tests\test-service-discovery.ps1
.\tests\test-validation.ps1
.\tests\test-simple.ps1
```

## 🔮 Future Development

### SRE-Focused Development Roadmap
- **Multi-Service Expansion**: Extend beyond EC2 to RDS, S3, Lambda, and other AWS services
- **AWS CLI Command Builder**: GUI-based AWS CLI command construction and execution
- **SRE Automation & Scripting**: PowerShell script integration and incident response playbooks
- **Enhanced Connection Management**: Advanced SSH/RDP session management and monitoring
- **Infrastructure Dependency Mapping**: Visualize resource relationships across services
- **Bulk Operations Framework**: Mass operations and compliance enforcement tools

### SRE Extensibility Framework
The architecture is designed for Site Reliability Engineering teams:
- **CLI Integration**: Seamless AWS CLI and PowerShell scripting capabilities
- **Automation Templates**: Reusable incident response and operational playbooks
- **Multi-Account Operations**: Centralized management across AWS environments
- **Compliance & Auditing**: Enterprise-grade logging and change management
- **Performance at Scale**: Handle large-scale AWS environments efficiently

## 📊 Performance

- **Memory Usage**: 266-279MB stable (no memory leaks detected)
- **Module Load Time**: Fast loading for all 13 modules
- **Application Startup**: 2-3 seconds for full WPF initialization
- **Network Operations**: Non-blocking with 100ms progress timers
- **Background Operations**: Efficient service discovery and connection monitoring

## 🤝 Contributing

See [CONTRIBUTING.md](docs/dev/CONTRIBUTING.md) for development standards, git rollback procedures, and testing requirements.

## 📝 Documentation

### User Documentation
- **[TESTING_GUIDE.md](docs/user/TESTING_GUIDE.md)**: How to run tests and validate functionality
- **[TESTING_AUTOMATION.md](docs/user/TESTING_AUTOMATION.md)**: Enhanced testing framework

### Developer Documentation
- **[CONTRIBUTING.md](docs/dev/CONTRIBUTING.md)**: Development standards and git procedures
- **[ROADMAP.md](docs/dev/ROADMAP.md)**: Development roadmap and optimization phases
- **[DEVELOPMENT_GUIDE.md](docs/DEVELOPMENT_GUIDE.md)**: Comprehensive development guide

### Project Documentation
- **[CHANGELOG.md](docs/CHANGELOG.md)**: Complete version history with file-level change tracking
- **[TEST_RESULTS.md](docs/TEST_RESULTS.md)**: Latest test results and validation reports

## 🏆 Production Status

**✅ APPROVED FOR SRE USE**

The application has passed comprehensive testing and is approved for production Site Reliability Engineering use with:
- Zero critical issues
- Complete functionality validation
- Professional UI/UX
- Enterprise-grade security
- Comprehensive documentation

---

**AWS Management Studio** - Empowering Site Reliability Engineers with secure, efficient multi-service AWS resource management.