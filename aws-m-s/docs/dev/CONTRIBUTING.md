# Contributing to AWS Management Studio

**Current Version:** 6.0.3 (Multi-Service AWS Management Platform)  
**Last Updated:** January 2025

## 📋 Documentation Standards

### Changelog Format Requirements

All changes must be documented in `CHANGELOG.md` using the detailed format established in v4.7.1. This format enables precise git rollbacks and development tracking.

#### Required Format for Each Change Entry:

```markdown
### 🐛 **[Bug Category]**
**Issue**: [Brief description of the problem]
**Impact**: [What was affected - user experience, functionality, etc.]
**Files Modified**:
- `[FilePath]`: [Function/Section] - [What was changed and why]
- `[FilePath]`: [Function/Section] - [What was changed and why]
**Resolution**: [How the issue was resolved]
```

#### Example (from v4.7.1):

```markdown
### 🐛 **Critical Bug Fixes**
**Issue**: Settings warnings and search functionality failures
**Impact**: Application startup warnings and broken core search features
**Files Modified**:
- `Core.psm1`: Updated Get-Settings() - Made paths self-contained within functions
- `Core.psm1`: Updated Set-Settings() - Removed dependency on external variables
- `AWS.psm1`: Updated Search-EC2Instances() - Changed JMESPath query syntax from 'Instances[*].[...]' to 'Instances[].[...]'
**Resolution**: Eliminated module loading warnings and restored proper instance search functionality
```

### File-Level Documentation Requirements

#### For Bug Fixes:
- **File Path**: Full relative path from project root
- **Function Name**: Exact function name that was modified
- **Change Description**: What was changed and why
- **Impact**: How this change affects functionality

#### For New Features:
- **File Path**: Full relative path for new/modified files
- **Function Names**: All new functions added
- **Integration Points**: How new code integrates with existing modules
- **Dependencies**: Any new dependencies or requirements

#### For Refactoring:
- **Files Affected**: All files touched during refactoring
- **Functions Modified**: List of functions changed
- **Architecture Changes**: Any structural changes to code organization
- **Backward Compatibility**: Impact on existing functionality

## 🔄 Git Version Control & Rollback Strategy

**Repository Status**: ✅ Git repository initialized (v5.2.7)  
**Initial Commit**: `02dbaac` - "v5.2.7-Phase3-Complete"  
**Backup System**: Complete backups in `backups/` directory

### Standard Git Commands for Development

#### Daily Development Workflow:
```bash
# Check current status
git status

# Stage changes for commit
git add .
# Or stage specific files
git add scripts/aws-ec2-management-studio-modular.ps1 src/Modules/UI.psm1

# Commit changes with descriptive message
git commit -m "v5.2.8 Feature: Description of changes"

# View commit history
git log --oneline

# View changes in last commit
git show HEAD
```

#### Branch Management:
```bash
# Create new feature branch
git checkout -b feature/phase4-background-monitoring

# Switch between branches
git checkout main
git checkout feature/phase4-background-monitoring

# Merge feature branch back to main
git checkout main
git merge feature/phase4-background-monitoring

# Delete feature branch after merge
git branch -d feature/phase4-background-monitoring
```

#### Rollback Strategies:

**1. Rollback Last Commit (Soft - Keep Changes):**
```bash
git reset --soft HEAD~1
```

**2. Rollback Last Commit (Hard - Discard Changes):**
```bash
git reset --hard HEAD~1
```

**3. Rollback to Specific Commit:**
```bash
# Find commit hash
git log --oneline
# Rollback to specific commit (replace abc1234 with actual hash)
git reset --hard abc1234
```

**4. Rollback Specific Files:**
```bash
# Revert specific file to last commit
git checkout HEAD -- src/Modules/UI.psm1

# Revert specific file to specific commit
git checkout abc1234 -- src/Modules/UI.psm1
```

**5. Create Revert Commit (Recommended for Shared Repos):**
```bash
# Revert specific commit (creates new commit)
git revert abc1234
```

### Emergency Rollback to Phase Backups:

**Phase 3 Complete Backup Restoration:**
```bash
# If git rollback isn't sufficient, restore from backup
cp backups/phase3-complete-2025-10-03/*.ps1 scripts/
cp backups/phase3-complete-2025-10-03/*.psm1 src/Modules/
cp backups/phase3-complete-2025-10-03/Launch-EC2Studio.* .

# Commit the restoration
git add .
git commit -m "Emergency rollback to Phase 3 complete state"
```

### Git Best Practices for This Project:

**1. Commit Frequency:**
- Commit after each working feature
- Commit before starting risky changes
- Commit at end of each development session

**2. Commit Message Format:**
```
v5.2.X Feature/Fix: Brief description

Detailed description of changes:
- File1: Function1() - What changed
- File2: Function2() - What changed

Testing: All tests passed
Backup: Created if major changes
```

**3. Branching Strategy:**
- `main`: Stable, production-ready code
- `feature/phase4-*`: Phase 4 development branches
- `hotfix/*`: Critical bug fixes
- `backup/*`: Backup restoration branches

### Example Rollback Documentation:

```markdown
### 🔄 **Git Rollback: Phase 4 Background Monitoring**
**Reason**: Background monitoring interfering with SSH connections
**Git Command**: `git reset --hard 02dbaac`
**Alternative**: Restore from `backups/phase3-complete-2025-10-03/`
**Files Reverted**:
- `src/Modules/UI.psm1`: Removed background monitoring functions
- `src/Modules/AWS.psm1`: Reverted to simple connection methods
**Impact**: Returns to stable Phase 3 connection management
**Commit**: `02dbaac` (Phase 3 Complete)
```

## 📝 Development Workflow with Git

### 1. Before Making Changes
- Review existing code structure
- Create feature branch: `git checkout -b feature/description`
- Check current status: `git status`
- Identify all files that will be modified
- Plan the specific functions that need changes

### 2. During Development
- Keep detailed notes of every file and function modified
- Document the reason for each change
- Test each change incrementally
- Commit frequently: `git add . && git commit -m "Progress: description"`

### 3. After Development
- Final testing of all changes
- Update CHANGELOG.md with detailed file/function information
- Stage all changes: `git add .`
- Create final commit: `git commit -m "v5.2.X Feature: description"`
- Merge to main: `git checkout main && git merge feature/description`
- Create backup if major changes: `cp -r scripts/ src/ backups/feature-backup-$(date +%Y%m%d)/`

### 4. Testing Documentation
- Verify that someone else could rollback your changes using git commands
- Ensure all file paths are accurate in changelog
- Confirm function names are spelled correctly
- Test rollback procedure: `git log --oneline` to find commit hash

## 📁 Project Organization

### Folder Structure
- **`docs/`**: Documentation organized by audience
  - **`docs/user/`**: End-user documentation (testing guides, automation)
  - **`docs/dev/`**: Developer documentation (contributing, roadmap, plans)
  - **`docs/archive/`**: Historical documents
  - **`docs/memory-bank/`**: Amazon Q context files
- **`scripts/`**: Main application scripts and executables
- **`src/`**: Source code including modules and components
- **`tests/`**: Test scripts, debugging tools, and validation scripts
- **`assets/`**: Images, screenshots, and media files
- **`archive/`**: Historical versions and backup files

### File Naming Conventions
- **Documentation**: Use descriptive names with extensions (.md for markdown)
- **Scripts**: Prefix with purpose (test-, aws-ec2-management-studio-)
- **Modules**: Use descriptive names with .psm1 extension
- **Assets**: Organize by type (Screenshots/, Icons/, etc.)

## 🏗️ Module Architecture Guidelines

### src/Modules/Core.psm1 - Settings Management
- **Purpose**: Handle all application settings and configuration
- **Key Functions**: Get-Settings, Set-Settings, Get-UserSettings, Set-UserSettings
- **Dependencies**: Should be self-contained with minimal external dependencies

### src/Modules/AWS.psm1 - AWS Operations
- **Purpose**: All AWS API interactions and data processing
- **Key Functions**: Search-EC2Instances, Get-AwsProfiles, Update-RecentProfiles
- **Dependencies**: AWS CLI, proper error handling for API failures

### src/Modules/UI.psm1 - User Interface Logic
- **Purpose**: Event handlers and UI state management
- **Key Functions**: Initialize-EventHandlers, Apply-InstanceFilters, Initialize-InputValidation
- **Dependencies**: WPF controls, Core and AWS modules, Validation module

### src/Modules/Validation.psm1 - AWS Service-Specific Input Validation
- **Purpose**: Comprehensive input validation and sanitization for all AWS services
- **Key Functions**: Test-InputValidation, Get-SafeInput, Add-ValidationToTextBox
- **Dependencies**: Self-contained with AWS service-specific validation rules
- **Coverage**: 25+ AWS services with enterprise-grade security validation

### src/Modules/AWSServiceConfig.psm1 - Multi-Service Configuration
- **Purpose**: AWS service enablement and configuration management
- **Key Functions**: Get-EnabledAWSServices, Set-AWSServiceEnabled, Get-ValidationRuleForService
- **Dependencies**: Validation module, persistent configuration storage
- **Features**: Service toggle system, category organization, validation rule mapping

## 🧪 Testing Requirements

### Before Committing Changes:
1. **Functional Testing**: Verify all modified functions work correctly
2. **Integration Testing**: Ensure modules still work together
3. **Regression Testing**: Confirm existing functionality isn't broken
4. **Documentation Testing**: Verify changelog entries are complete and accurate

### Testing Checklist:
- [ ] All modified functions tested individually
- [ ] Module loading works without errors
- [ ] Integration between modules functions correctly
- [ ] No new warnings or errors introduced
- [ ] Changelog entries are complete and accurate
- [ ] File paths in changelog are correct
- [ ] Function names in changelog are spelled correctly

## 📋 Version Management with Git

### Version Numbering:
- **Major.Minor.Patch** (e.g., 5.2.7)
- **Major**: Significant architecture changes or new major features
- **Minor**: New features, enhancements, or significant bug fixes
- **Patch**: Bug fixes, small improvements, documentation updates

### Git Tagging for Releases:
```bash
# Create annotated tag for release
git tag -a v5.2.7 -m "Phase 3 Complete: Manual Connection Management"

# List all tags
git tag -l

# Checkout specific version
git checkout v5.2.7

# Return to latest
git checkout main
```

### Release Documentation:
Each version must include:
- Git commit with version tag
- Complete changelog with file-level details
- Updated README.md with new features
- Testing checklist updates if needed
- Migration notes if applicable
- Backup created in `backups/` directory

### Git Repository Milestones:
- **v5.2.7** (`02dbaac`): Phase 3 Complete - Manual Connection Management
- **Future**: v5.3.0 - Phase 4 Background Monitoring
- **Future**: v6.0.0 - Major architecture updates

## 🎯 Quality Standards

### Code Quality:
- Follow PowerShell best practices
- Use proper error handling
- Include inline comments for complex logic
- Maintain consistent coding style

### Documentation Quality:
- Changelog entries must be complete and accurate
- File paths must be relative to project root
- Function names must be exact matches
- Change descriptions must be clear and specific

### Testing Quality:
- All changes must be tested before commit
- Regression testing required for bug fixes
- Integration testing required for new features
- Documentation accuracy must be verified

## 🔧 Git Repository Maintenance

### Regular Maintenance Tasks:
```bash
# Check repository status
git status
git log --oneline -10

# Clean up merged branches
git branch --merged | grep -v main | xargs git branch -d

# Verify repository integrity
git fsck

# View repository size
du -sh .git/
```

### Backup Integration with Git:
- **Git Repository**: Primary version control
- **Backup Directory**: `backups/` for major milestones
- **Emergency Restoration**: Use backups if git history is corrupted
- **Double Safety**: Both git history and file backups available

---

**This contributing guide ensures that all future development maintains high documentation standards with proper git version control, enabling reliable rollbacks and clear development tracking.**