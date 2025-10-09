# Documentation Cleanup Plan - AWS Management Studio

## Current Issues Identified

### 🚨 **Critical Problems**
1. **Version Confusion**: Multiple documents claiming different versions (v5.2.0, v6.0.3, v6.0.5)
2. **Outdated Testing Guides**: References to non-existent test files
3. **Document Duplication**: 3 different testing guides with conflicting information
4. **Session Sprawl**: Detailed session logs in main docs directory

### 📊 **Document Audit Results**

#### **KEEP (Essential Documents)**
- ✅ **README.md** - Project overview (needs version update)
- ✅ **CHANGELOG.md** - Version history (current)
- ✅ **CONTRIBUTING.md** - Development standards
- ✅ **ROADMAP.md** - Development roadmap (current)
- ✅ **TESTING_AUTOMATION.md** - Enhanced testing framework (current)

#### **CONSOLIDATE (Merge Similar Documents)**
- 🔄 **CURRENT_STATUS.md** + **CURRENT_TESTING_GUIDE.md** + **TESTING_GUIDE.md** → **TESTING_GUIDE.md**
- 🔄 **LESSONS_LEARNED_v6.0.0.md** → Merge key insights into **CONTRIBUTING.md**

#### **ARCHIVE (Move to archive/)**
- 📦 **Q-SESSION-CHANGES-2025-01-02.md** - Session-specific details
- 📦 **LESSONS_LEARNED_v6.0.0.md** - Version-specific lessons
- 📦 **CURRENT_TESTING_GUIDE.md** - Outdated testing guide
- 📦 **CURRENT_STATUS.md** - Redundant with other status docs

#### **DELETE (Redundant/Outdated)**
- ❌ **GIT_QUICK_REFERENCE.md** - Generic git info (not project-specific)
- ❌ **POWERSHELL_VERB_GUIDELINES.md** - Generic PowerShell info
- ❌ **AWS-SERVICE-VALIDATION.md** - Outdated service validation info
- ❌ **MULTI-SERVICE-FEATURES.md** - Content covered in other docs

## Cleanup Actions

### **Phase 1: Archive Session-Specific Documents**
```powershell
# Move session-specific documents to archive
Move-Item "docs\Q-SESSION-CHANGES-2025-01-02.md" "docs\archive\"
Move-Item "docs\LESSONS_LEARNED_v6.0.0.md" "docs\archive\"
Move-Item "docs\CURRENT_TESTING_GUIDE.md" "docs\archive\"
Move-Item "docs\CURRENT_STATUS.md" "docs\archive\"
```

### **Phase 2: Delete Redundant Documents**
```powershell
# Remove generic/redundant documents
Remove-Item "docs\GIT_QUICK_REFERENCE.md"
Remove-Item "docs\POWERSHELL_VERB_GUIDELINES.md"
Remove-Item "docs\AWS-SERVICE-VALIDATION.md"
Remove-Item "docs\MULTI-SERVICE-FEATURES.md"
```

### **Phase 3: Consolidate Testing Documentation**
- **Create single TESTING_GUIDE.md** with current procedures
- **Update with actual test file names** from tests/ directory
- **Remove version-specific references**
- **Focus on current v6.0.5 procedures**

### **Phase 4: Update Core Documents**
- **README.md**: Update version to v6.0.5
- **TESTING_GUIDE.md**: Consolidate all testing procedures
- **CONTRIBUTING.md**: Add key lessons learned

## Target Document Structure

### **Final docs/ Directory**
```
docs/
├── memory-bank/           # Amazon Q context (keep as-is)
├── archive/              # Historical documents
├── README.md             # Project overview
├── CHANGELOG.md          # Version history
├── CONTRIBUTING.md       # Development standards + lessons learned
├── ROADMAP.md           # Development roadmap
├── TESTING_GUIDE.md     # Consolidated testing procedures
├── TESTING_AUTOMATION.md # Enhanced testing framework
└── TEST_RESULTS.md      # Current test results
```

### **Benefits of Cleanup**
- ✅ **Clear Documentation Path**: Single source of truth for each topic
- ✅ **Reduced Confusion**: No conflicting version information
- ✅ **Easier Maintenance**: Fewer documents to keep updated
- ✅ **Better Organization**: Logical document hierarchy
- ✅ **Historical Preservation**: Important information archived, not lost

## Implementation Timeline

### **Immediate (5 minutes)**
- Archive session-specific documents
- Delete redundant generic documents

### **Short-term (15 minutes)**
- Consolidate testing documentation
- Update core document versions

### **Ongoing**
- Maintain single testing guide
- Update README with major changes
- Archive detailed session logs

## Success Criteria

- ✅ **Single Testing Guide**: One authoritative testing document
- ✅ **Current Version Info**: All documents reference correct version
- ✅ **Clear Organization**: Logical document structure
- ✅ **Preserved History**: Important information archived
- ✅ **Reduced Maintenance**: Fewer documents to maintain