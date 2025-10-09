# AWS Management Studio

**Current Version:** 6.3.0 (Hybrid Distribution Model) - ✅ **PRODUCTION READY**  
**Platform:** PowerShell 7.0+ with WPF UI Framework  
**Target Users:** Site Reliability Engineers, CloudOps Teams, Technical Operations

## 🚀 Overview

AWS Management Studio is a comprehensive PowerShell-based WPF application designed specifically for Site Reliability Engineers and technical operations teams. It provides unified resource discovery and management across multiple AWS services (EC2, RDS, S3, Lambda) with advanced automation capabilities, CLI integration, and enterprise-grade operational features. The application combines powerful multi-service AWS management with SRE-focused workflows for incident response, bulk operations, and infrastructure automation.

## ✨ Key Features

### 🔗 Connection Management (Phase 2)
- **RDP Connections**: Direct Windows instance access via AWS Systems Manager
- **SSH Connections**: Linux instance access with Windows Terminal integration  
- **Port Forwarding**: Secure database/service tunneling with dynamic port allocation
- **Connection Manager**: Real-time monitoring and termination of active connections
- **Docked Window System**: Separate panel windows for clean workflow management

### 🛡️ AWS Service-Specific Validation System (v5.2.2)
- **25+ AWS Services**: Comprehensive validation rules for EC2, S3, RDS, Lambda, IAM, VPC, CloudFormation, ECS, EKS, SNS, SQS, CloudWatch, and more
- **Real-Time Validation**: Visual feedback with TextBox color changes and contextual tooltips
- **Command Injection Prevention**: Protection against shell escapes, control characters, and malicious input
- **Service Toggle System**: Enable/disable AWS services based on user needs and permissions
- **Validation-Only Approach**: Clear rejection of dangerous input with actionable error messages (no silent "fixing")
- **Future-Ready Architecture**: Framework designed for multi-service expansion and SSO integration

### 🌐 Multi-Service AWS Management (v6.0.3)
- **EC2 Instances**: Complete instance management with connection capabilities, filtering, and monitoring
- **RDS Databases**: Multi-region RDS instance discovery with engine, status, and class information
- **S3 Buckets**: Account-wide S3 bucket listing with creation dates and metadata
- **Lambda Functions**: Multi-region Lambda function discovery with runtime and modification details
- **Async Search Operations**: Non-blocking searches with real-time cancellation support
- **Service Discovery**: Automated validation of AWS service accessibility with detailed reporting
- **Unified Interface**: Consistent tabbed interface with service-specific search and display
- **Service Configuration**: User-configurable service enablement for customized workflows

### 🔍 Resource Discovery & Management
- **Multi-Region Search**: Parallel resource discovery across us-east-1, us-west-2, ca-central-1 for supported services
- **Service-Aware Search**: Dynamic search button that adapts to selected service tab with cancellation support
- **Async Operations**: All searches run in background with progress tracking and immediate cancellation
- **Service Discovery**: One-click discovery and validation of available AWS services (89% success rate)
- **Real-Time Filtering**: Live filtering by resource attributes with validated input (EC2 focus, expanding to all services)
- **Search History**: Automatic capture with 3-second debounce (7 items max)
- **Favorites System**: Named search combinations with complete filter state
- **Auto-Refresh**: Configurable automatic resource list updates
- **Column Spacing**: Three spacing options (Compact, Balanced, Comfortable) for improved readability

### 🐛 **NEW: Enhanced Bug Report System (v6.2.1)**
- **File Attachment Support**: Attach existing image files with comprehensive validation
- **Secure Application Screenshots**: Capture only the application window (no desktop content)
- **Professional Validation**: 10MB size limits, format checking, and integrity validation
- **Security-First Design**: User consent for screenshots with clear privacy protection
- **Multiple Attachment Methods**: Both file selection and secure screenshot capture
- **User-Friendly Interface**: Clear tooltips, validation messages, and progress indicators

### 🚀 **Automatic Version-Based Testing (v6.1.0)**
- **Zero-Effort Quality Assurance**: Tests run automatically when version changes are detected
- **Smart Test Selection**: Major versions → comprehensive tests, bug fixes → quick tests
- **Automatic Documentation**: Every test run updates TEST_RESULTS.md automatically
- **Complete Audit Trail**: Full history of version changes and test results
- **Enterprise Quality Gates**: Ensures every version change is validated

### 🔐 Enterprise Security & Authentication
- **AWS SSO Integration**: Complete SSO profile lifecycle management
- **Multi-Account Support**: Support for multiple AWS accounts and profiles
- **Credential Security**: Windows Credential Manager integration
- **Input Sanitization**: Enterprise-grade validation preventing command injection
- **Audit Trail**: All operations logged via AWS CloudTrail

## 🏗️ Architecture

### Modular Design (v5.0.0+)
```
Main Application (aws-ec2-management-studio-modular.ps1)
├── Core.psm1 (Settings & Configuration)
├── AWS.psm1 (AWS Operations & Connections)
├── UI.psm1 (User Interface & Event Handling)
├── Validation.psm1 (AWS Service-Specific Input Validation)
├── AWSServiceConfig.psm1 (Multi-Service Configuration)
├── BugTracker.psm1 (Bug Reporting with File Attachments)
├── PanelFramework.psm1 (Configurable Panel System)
└── TestRunner.psm1 (Automated Testing Framework)
```

### 🎆 **NEW: Configurable Panel Framework (v6.2.1)**
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

See [FRAMEWORK_METHODOLOGY.md](docs/FRAMEWORK_METHODOLOGY.md) for complete development guide.

### AWS Service Coverage
- **Currently Implemented**: EC2 (full management), RDS (discovery), S3 (discovery), Lambda (discovery)
- **Validated Services**: 9 services with 89% accessibility success rate (RDS, S3, Lambda, CloudFormation, IAM, VPC, EKS, Route53)
- **Framework Ready**: Additional services easily configurable via JSON configuration
- **Service Discovery**: Automated testing and validation of service accessibility
- **Expansion Pattern**: Consistent AWS CLI integration with service-specific result processing
- **User Configuration**: Enable/disable services based on needs and permissions

## 🚀 Quick Start

### Prerequisites
- **PowerShell 7.0+** (Required for WPF support)
- **AWS CLI v2.0+** (Required for AWS operations)
- **.NET Framework 4.7.2+** (Required for WPF assemblies)
- **Windows 10/11** (Required for optimal WPF and dark mode support)

### 🏢 **Hybrid Distribution Model (v6.3.0)**

**Primary Distribution**: Azure DevOps Repository
- **Corporate Repository**: `https://dev.azure.com/psgov/Cloud-PA/_git/cloudops`
- **Git-Based Updates**: Automatic update detection via VS Code integration
- **Team Distribution**: Clone repository with VS Code for seamless updates
- **Professional Workflow**: Standard Git workflow for version control
- **VS Code Authentication**: Leverages existing corporate authentication

**Bug Tracking**: Secure Network Share
- **Private Bug Tracking**: `\\fileshare.cloud.lcl\Users\derek.johnson\Scripts\aws-management-studio\bugs`
- **VPN + Domain Authentication**: Enterprise security model (VPN required)
- **Personal Project Isolation**: Separate from work items and customer requests
- **Secure Environment**: Corporate infrastructure with access controls
- **JSON-Based Tracking**: Lightweight, file-based issue management

**Security Benefits**:
- ✅ **Network-Level Protection**: VPN required for bug tracking access
- ✅ **Domain Authentication**: Corporate user validation
- ✅ **Isolated Environment**: Personal directory prevents interference
- ✅ **Professional Distribution**: Corporate AzDo repository for team access

### Installation

#### Option 1: Git Clone (Recommended for Team)
1. **Clone from AzDo**: `git clone https://dev.azure.com/psgov/Cloud-PA/_git/cloudops`
2. **Open in VS Code**: Automatic authentication and update integration
3. **Run Application**: Launch via any of the available launchers

#### Option 2: Direct Download
1. Download the repository from AzDo releases
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
   ```

### Launcher Options
- **AWSStudio.exe**: ⭐ **RECOMMENDED** - Silent executable for enterprise deployment (security-tool friendly, no console windows)
- **Launch-AWSStudio.ps1**: Full-featured PowerShell launcher with enhanced error handling and shortcut creation
- **Launch-AWSStudio.cmd**: Batch file launcher for environments requiring .cmd files
- **Launch-AWSStudio-Simple.ps1**: Source script for executable creation with security optimizations

### 🏢 Enterprise Deployment
- **✅ Security Tool Safe**: AWSStudio.exe passes corporate security scanning without false positives
- **✅ Desktop Shortcut Ready**: Works from any location including desktop shortcuts and network shares
- **✅ Silent Operation**: No console windows, professional user experience
- **✅ Error Guidance**: Clear VBScript dialogs when run from incorrect locations

### First Run
1. Select an AWS profile from the dropdown
2. Click "Check Status" to validate SSO authentication
3. Click "🔍 Search Instances" to discover EC2 resources
4. Right-click instances for connection options (RDP, SSH, Port Forward)

## 🔧 Configuration

### Service Configuration
Enable/disable AWS services based on your needs:
```powershell
# Enable S3 service
Set-AWSServiceEnabled -ServiceName 'S3' -Enabled $true

# Save configuration
Save-ServiceConfiguration
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

### Automated Test Framework (v6.0.3)
- **Comprehensive Test Suite**: 10 test groups covering all functionality
- **Quick Validation**: 5-second daily development checks
- **Integration Testing**: End-to-end AWS service validation
- **Multiple Output Formats**: Console, JSON, HTML reporting
- **CI/CD Ready**: Automated testing with exit codes

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
- **Module Loading**: All 5 modules with function validation
- **Settings Management**: Configuration and persistence
- **AWS Integration**: Profile management and service discovery
- **UI Components**: XAML parsing and DataGrid operations
- **Async Operations**: Background processing and cancellation
- **Error Handling**: Exception handling and recovery

### Legacy Test Scripts
```powershell
# Individual component testing
.\tests\test-modular-basic.ps1
.\tests\test-service-discovery.ps1
.\tests\test-multi-service.ps1
```

## 🔮 Future Development

### SRE-Focused Development Roadmap
- **AWS CLI Command Builder Framework**: GUI-based AWS CLI command construction and execution
- **Advanced Multi-Service Operations**: Cross-service workflows spanning EC2, RDS, S3, Lambda
- **SRE Automation & Scripting**: PowerShell script integration and incident response playbooks
- **Enterprise Operations & Compliance**: Multi-account management and audit logging
- **Infrastructure Dependency Mapping**: Visualize resource relationships across services
- **Bulk Resource Management**: Mass operations and compliance enforcement

### SRE Extensibility Framework
The architecture is designed for Site Reliability Engineering teams:
- **CLI Integration**: Seamless AWS CLI and PowerShell scripting capabilities
- **Automation Templates**: Reusable incident response and operational playbooks
- **Multi-Account Operations**: Centralized management across AWS environments
- **Compliance & Auditing**: Enterprise-grade logging and change management
- **Performance at Scale**: Handle large-scale AWS environments efficiently

## 📊 Performance

- **Memory Usage**: 266-279MB stable (no memory leaks detected)
- **Module Load Time**: 59ms for all 3 modules
- **Application Startup**: 2-3 seconds for full WPF initialization
- **Network Operations**: Non-blocking with 100ms progress timers
- **Validation Performance**: Real-time input validation without UI blocking

## 🤝 Contributing

See [CONTRIBUTING.md](docs/dev/CONTRIBUTING.md) for development standards, git rollback procedures, and testing requirements.

## 📝 Documentation

### User Documentation
- **[TESTING_GUIDE.md](docs/user/TESTING_GUIDE.md)**: How to run tests and validate functionality
- **[TESTING_AUTOMATION.md](docs/user/TESTING_AUTOMATION.md)**: Enhanced testing framework

### Developer Documentation
- **[CONTRIBUTING.md](docs/dev/CONTRIBUTING.md)**: Development standards and git procedures
- **[ROADMAP.md](docs/dev/ROADMAP.md)**: Development roadmap and optimization phases

### Universal Documentation
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