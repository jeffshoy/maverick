# FE Legacy Cognos 11.2.4 AMI Build — Ubuntu 24.04

## Overview

This document covers the full technical process for building a golden Ubuntu 24.04 AMI
with GUI, Apache, and IBM Cognos Analytics 11.2.4 pre-installed. This AMI will be used
to manually deploy Cognos instances for FE 1.0 (legacy) clients who are migrating from
Windows Web Server to Linux Cognos.

**Two AMIs will be created:**
- us-west-2 (west) — proxy: `172.29.20.55:8080`
- us-east-1 (east) — proxy: `172.30.20.55:8080`

**Contacts:** Marc Percy (task owner), Shawn Bates

### Account Details

| | West (ISB) | East (HIC) |
|--|-----------|-----------|
| **Account** | 166463094979 | 976048299571 |
| **AWS Profile** | `PALegacyFinEntISB` | `PALegacyFinEntHIC` |
| **Region** | us-west-2 | us-east-1 |
| **VPC** | `vpc-0649bc3ae491e5ddd` | `vpc-089840e0b25e63937` |
| **Subnet** | `subnet-0d8678ad832236664` | `subnet-09e98e12f77acdad8` |
| **Security Group** | `sg-08067aefb2e2f1ff3` (SG-isb) | `sg-08a221000a220fc33` (SG-dhil) |
| **Instance Profile** | `EC2-Default-SSM-AD-Role` | `EC2-Default-SSM-AD-Role` |
| **Instance Type** | r6a.xlarge | r6a.xlarge |
| **Key Pair** | None (SSM only) | None (SSM only) |
| **Proxy** | `172.29.20.55:8080` | `172.30.20.55:8080` |
| **Reference Instance** | `i-089f9b511c61ef3cf` (ISB-PONSRP001 — existing Windows Cognos, being migrated away from) | `i-08c3d8d7b69c29e5a` (HIC-PONSRP001 — existing Windows Cognos, being migrated away from) |
| **Build Instance** | `i-0067f3e81d03d22b5` (cognos-11.2.4-ami-build-usw2) | `i-0bbee90ce9fab60be` (cognos-11.2.4-ami-build-use1) |
| **Build Instance IP** | `10.60.13.55` | `10.130.33.19` |
| **Golden AMI (v1.3)** | `ami-0f6a4e7c36328cfd0` (Shared Services 361362055558, us-west-2) | `ami-007e574ddf94a654b` (Shared Services 361362055558, us-east-1) |

---

## Compatibility Warning

IBM Cognos 11.2.4 may not officially support Ubuntu 24.04. The existing FE 2.0 automation
uses Ubuntu 24.04 with Cognos 12.x successfully. Confirm with Marc that 11.2.4 installs
cleanly on 24.04 before baking the final AMI. If it fails, fall back to Ubuntu 22.04.

---

## Prerequisites

### What You Need Before Starting

| Item | Details |
|------|---------|
| AWS Profile (west) | `PALegacyFinEntISB` |
| AWS Profile (east) | `PALegacyFinEntHIC` |
| Base AMI | Ubuntu 24.04 LTS (`ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*`) |
| Instance Type | r6a.xlarge (4 vCPU, 32 GB RAM) — matches existing reports instances |
| Root Volume | 100 GB gp3 |
| IAM Instance Profile | `EC2-Default-SSM-AD-Role` (both accounts) |
| Security Group (west) | `sg-08067aefb2e2f1ff3` (SG-isb) |
| Security Group (east) | `sg-08a221000a220fc33` (SG-dhil) |
| Key Pair | None — use SSM Session Manager for access |
| Cognos 11.2.4 Installer | Obtain from Marc — needs to be staged in S3 or transferred to instance |
| Subnet (west) | `subnet-0d8678ad832236664` |
| Subnet (east) | `subnet-09e98e12f77acdad8` |

### Cognos 11.2.4 Installer Files (from Marc Percy)

Located in SharePoint: `CentralSquare Analytics > Documents > Linux 11.2.4`

- `analytics-installer-3.7.56-linuxx86.bin` (installer binary)
- `casrv-11.2.4-2607141456-linuxi38664h.zip` (content package)
- `ResponseFile.properties` (silent install config)

---

## Phase 1 — Launch Base Instance

### West (us-west-2 — ISB)

```powershell
# Find the latest Ubuntu 24.04 AMI in us-west-2
aws ec2 describe-images --profile PALegacyFinEntISB --region us-west-2 --owners 099720109477 --filters "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*" --query "Images | sort_by(@, &CreationDate) | [-1].[ImageId,Name]" --output text

# Result: ami-0ac74609c6396bed3  ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-20260714

# Launch the instance
aws ec2 run-instances --profile PALegacyFinEntISB --region us-west-2 --image-id ami-0ac74609c6396bed3 --instance-type r6a.xlarge --subnet-id subnet-0d8678ad832236664 --security-group-ids sg-08067aefb2e2f1ff3 --iam-instance-profile Name=EC2-Default-SSM-AD-Role --block-device-mappings "[{`"DeviceName`":`"/dev/sda1`",`"Ebs`":{`"VolumeSize`":100,`"VolumeType`":`"gp3`",`"Encrypted`":true}}]" --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=cognos-11.2.4-ami-build-usw2}]" --output json
```

### East (us-east-1 — HIC)

```powershell
# Find the latest Ubuntu 24.04 AMI in us-east-1
aws ec2 describe-images --profile PALegacyFinEntHIC --region us-east-1 --owners 099720109477 --filters "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*" --query "Images | sort_by(@, &CreationDate) | [-1].[ImageId,Name]" --output text

# Result: ami-052355af2a014bd2c  ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-20260714

# Launch the instance
aws ec2 run-instances --profile PALegacyFinEntHIC --region us-east-1 --image-id ami-052355af2a014bd2c --instance-type r6a.xlarge --subnet-id subnet-09e98e12f77acdad8 --security-group-ids sg-08a221000a220fc33 --iam-instance-profile Name=EC2-Default-SSM-AD-Role --block-device-mappings "[{`"DeviceName`":`"/dev/sda1`",`"Ebs`":{`"VolumeSize`":100,`"VolumeType`":`"gp3`",`"Encrypted`":true}}]" --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=cognos-11.2.4-ami-build-use1}]" --output json
```

Note the instance ID from the output.

---

## Phase 2 — Connect and Configure Proxy

Connect via SSM Session Manager (from PowerShell on your workstation):

```powershell
# West
aws ssm start-session --profile PALegacyFinEntISB --region us-west-2 --target i-0067f3e81d03d22b5

# East
aws ssm start-session --profile PALegacyFinEntHIC --region us-east-1 --target i-0bbee90ce9fab60be

# For RDP access (port forwarding through SSM — no inbound 3389 needed):
aws ssm start-session --profile PALegacyFinEntISB --region us-west-2 --target i-0067f3e81d03d22b5 --document-name AWS-StartPortForwardingSession --parameters "portNumber=3389,localPortNumber=33389"
# Then RDP to localhost:33389
```

Once connected, switch to bash and set up the proxy. **All subsequent commands
assume you are on the instance.**

```bash
bash

# === PROXY CONFIGURATION (us-west-2) ===
# For us-east-1, replace 172.29.20.55:8080 with 172.30.20.55:8080

# System-wide environment variables
sudo tee /etc/environment << 'EOF'
http_proxy=http://172.29.20.55:8080
https_proxy=http://172.29.20.55:8080
no_proxy=localhost,127.0.0.1,169.254.169.254,10.0.0.0/8,192.168.0.0/16,172.16.0.0/12,.cloud.lcl,.amazonaws.com
HTTP_PROXY=http://172.29.20.55:8080
HTTPS_PROXY=http://172.29.20.55:8080
NO_PROXY=localhost,127.0.0.1,169.254.169.254,10.0.0.0/8,192.168.0.0/16,172.16.0.0/12,.cloud.lcl,.amazonaws.com
EOF

# APT proxy config
sudo tee /etc/apt/apt.conf.d/95proxy << 'EOF'
Acquire::http::Proxy "http://172.29.20.55:8080";
Acquire::https::Proxy "http://172.29.20.55:8080";
EOF

# Snap proxy config (for SSM agent updates)
sudo snap set system proxy.http="http://172.29.20.55:8080"
sudo snap set system proxy.https="http://172.29.20.55:8080"

# Load proxy into current session
source /etc/environment
export http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY

# Verify proxy works
curl -I https://archive.ubuntu.com
# Expected: HTTP/1.1 200 OK (or 302)
```

---

## Phase 3 — System Update and Base Packages

```bash
# Update system
sudo apt-get update -y
sudo apt-get upgrade -y

# Install base utilities and dependencies
# (these are all used by the existing Cognos automation scripts)
sudo apt-get install -y \
  wget \
  curl \
  unzip \
  htop \
  net-tools \
  software-properties-common \
  ca-certificates \
  gnupg \
  lsb-release \
  jq \
  xmlstarlet \
  python3-pip \
  python3-venv \
  python3-setuptools
```

---

## Phase 4 — Verify SSM Agent

```bash
# SSM agent should already be running on AWS Ubuntu AMIs
sudo systemctl status snap.amazon-ssm-agent.amazon-ssm-agent.service

# If not running:
sudo systemctl enable snap.amazon-ssm-agent.amazon-ssm-agent.service
sudo systemctl start snap.amazon-ssm-agent.amazon-ssm-agent.service
```

Verify from your workstation (PowerShell):

```powershell
aws ssm describe-instance-information --profile PALegacyFinEntISB --region us-west-2 --filters "Key=InstanceIds,Values=i-0067f3e81d03d22b5"
```

---

## Phase 5 — Install XFCE Desktop and xrdp

This follows the same pattern as the existing `lnx-install-desktop.sh` in the
`analytics_cloudautomation` repo.

```bash
export DEBIAN_FRONTEND=noninteractive

# Install XFCE4 desktop, xrdp, and xvfb (virtual framebuffer for headless Cognos installer)
sudo apt-get install -y xfce4 xfce4-goodies xrdp dbus-x11 xvfb

# Install Firefox as a real deb (not snap stub — snap Firefox breaks in RDP sessions)
sudo apt-get remove --purge -y firefox 2>/dev/null || true
sudo snap remove firefox 2>/dev/null || true
sudo apt-get install -y software-properties-common
sudo add-apt-repository -y ppa:mozillateam/ppa

# Pin Mozilla PPA Firefox over the snap stub
sudo tee /etc/apt/preferences.d/mozilla-firefox << 'PINEOF'
Package: firefox*
Pin: release o=LP-PPA-mozillateam
Pin-Priority: 1001
PINEOF

sudo apt-get update -y
sudo apt-get install -y firefox

# Set Firefox as default browser
sudo update-alternatives --set x-www-browser /usr/bin/firefox 2>/dev/null || true
sudo update-alternatives --set gnome-www-browser /usr/bin/firefox 2>/dev/null || true

# Configure xrdp to use XFCE4
sudo tee /etc/xrdp/startwm.sh << 'EOF'
#!/bin/sh
unset DBUS_SESSION_BUS_ADDRESS
unset XDG_RUNTIME_DIR
exec startxfce4
EOF
sudo chmod +x /etc/xrdp/startwm.sh

# Add xrdp user to ssl-cert group
sudo adduser xrdp ssl-cert 2>/dev/null || true

# Enable and start xrdp
sudo systemctl enable xrdp
sudo systemctl restart xrdp

# Set a password for the ubuntu user (required for RDP login)
sudo passwd ubuntu
# Enter a strong temporary password — will be cleaned before AMI creation
```

### Validate RDP Access

From your workstation, RDP to the instance private IP on port 3389.
Log in as `ubuntu` with the password you just set. You should see the XFCE desktop.

---

## Phase 6 — Install Apache

```bash
# Install Apache2
sudo apt-get install -y apache2

# Enable required modules (matches lnx-apache-config.sh from existing automation)
sudo a2enmod proxy
sudo a2enmod proxy_http
sudo a2enmod proxy_ajp
sudo a2enmod proxy_balancer
sudo a2enmod lbmethod_byrequests
sudo a2enmod rewrite
sudo a2enmod ssl
sudo a2enmod headers
sudo a2enmod expires
sudo a2enmod mime
sudo a2enmod deflate
sudo a2enmod slotmem_shm
sudo a2enmod alias

# Enable and start Apache
sudo systemctl enable apache2
sudo systemctl start apache2

# Verify
sudo systemctl status apache2
curl -I http://localhost
# Expected: HTTP/1.1 200 OK
```

---

## Phase 7 — Install Java 11

Required by Cognos SDK automation tools (`lnxsdkautomation.jar`). Cognos 11.2.4
itself ships its own IBM JRE, but Java 11 is needed for the supporting tooling.

```bash
sudo apt-get install -y openjdk-11-jre-headless

# Verify
java -version
# Expected: openjdk version "11.x.x"

# Set JAVA_HOME system-wide
sudo tee /etc/profile.d/java.sh << 'EOF'
export JAVA_HOME=/usr/lib/jvm/java-11-openjdk-amd64
export PATH=$JAVA_HOME/bin:$PATH
EOF

source /etc/profile.d/java.sh
```

---

## Phase 8 — Install Additional Tools (from existing automation)

These tools are installed by `lnx-server-config.sh` during the automated FE 2.0
deployments. Install them now so the AMI is ready for post-deploy configuration.

### PostgreSQL Client

```bash
sudo install -m 0755 -d /etc/apt/keyrings
curl -sSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
  | sudo gpg --dearmor -o /etc/apt/keyrings/postgresql.gpg
sudo chmod a+r /etc/apt/keyrings/postgresql.gpg

UBUNTU_CODENAME=$(lsb_release -cs)
echo "deb [signed-by=/etc/apt/keyrings/postgresql.gpg] https://apt.postgresql.org/pub/repos/apt ${UBUNTU_CODENAME}-pgdg main" \
  | sudo tee /etc/apt/sources.list.d/pgdg.list

sudo apt-get update -qq
sudo apt-get install -y postgresql-client

# Verify
psql --version
```

### Microsoft SQL Server Tools (sqlcmd)

```bash
sudo install -m 0755 -d /etc/apt/keyrings
curl -sSL https://packages.microsoft.com/keys/microsoft.asc \
  | sudo gpg --dearmor -o /etc/apt/keyrings/microsoft.gpg
sudo chmod a+r /etc/apt/keyrings/microsoft.gpg
sudo cp /etc/apt/keyrings/microsoft.gpg /usr/share/keyrings/microsoft-prod.gpg

curl -sSL https://packages.microsoft.com/config/ubuntu/24.04/prod.list \
  | sudo tee /etc/apt/sources.list.d/mssql-release.list

sudo apt-get update -qq
sudo ACCEPT_EULA=Y apt-get install -y mssql-tools18 unixodbc-dev

# Add to PATH
echo 'export PATH="$PATH:/opt/mssql-tools18/bin"' | sudo tee /etc/profile.d/mssql-tools.sh
source /etc/profile.d/mssql-tools.sh

# Verify
sqlcmd -? 2>&1 | head -3
```

### AWS CLI v2

```bash
# Check if already installed (may be on the base AMI)
aws --version 2>/dev/null || {
  curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip"
  unzip -q /tmp/awscliv2.zip -d /tmp
  sudo /tmp/aws/install
  rm -rf /tmp/awscliv2.zip /tmp/aws
}

aws --version
```

### OpenLDAP Client and Server (for Cognos authentication)

```bash
export DEBIAN_FRONTEND=noninteractive

# Pre-seed slapd with a placeholder password (will be reconfigured per-client)
sudo debconf-set-selections << 'DEBEOF'
slapd slapd/internal/adminpw password placeholder
slapd slapd/internal/generated_adminpw password placeholder
slapd slapd/password1 password placeholder
slapd slapd/password2 password placeholder
slapd slapd/domain string cognos.local
slapd shared/organization string CentralSquare
DEBEOF

# Determine correct libldap package name for Ubuntu 24.04
SLAPD_VER=$(apt-cache show slapd 2>/dev/null | grep -m1 '^Version:' | awk '{print $2}')

if apt-cache show libldap-2.5-0 &>/dev/null 2>&1; then
    LIBLDAP_PKG="libldap-2.5-0"
else
    LIBLDAP_PKG="libldap2"
fi

sudo apt-get install -y --allow-downgrades \
  slapd="${SLAPD_VER}" \
  ldap-utils="${SLAPD_VER}" \
  "${LIBLDAP_PKG}=${SLAPD_VER}"

# Stop slapd for now — will be configured per-client at deploy time
sudo systemctl stop slapd
sudo systemctl disable slapd
```

---

## Phase 8b — Install Tanium Client

**One-time, AMI-level install only.** Security team provided the Linux client bundle
(`linux-client-bundle.zip`) directly — install it once here while building the AMI. The
per-client deploy runbook does **not** need to repeat this step; every instance launched
from this AMI already has the Tanium client installed.

Per security team guidance: the Tanium agent periodically pulls updated host information
(hostname, etc.), so baking it into the AMI before per-client hostnames are set is
acceptable. No client ID / identity reset is performed before AMI creation — install and
leave running as-is.

Bundle staged in the same S3 buckets used for the Cognos installer, under a `tanium/` prefix:
- West: `s3://cognos-installer-isb-usw2/tanium/linux-client-bundle.zip`
- East: `s3://cognos-installer-hic-use1/tanium/linux-client-bundle.zip`

```bash
cd /tmp

# West instance:
aws s3 cp s3://cognos-installer-isb-usw2/tanium/linux-client-bundle.zip .

# East instance:
sudo -u ubuntu-admin /usr/local/bin/aws s3 cp s3://cognos-installer-hic-use1/tanium/linux-client-bundle.zip .

unzip linux-client-bundle.zip -d tanium-bundle
cd tanium-bundle
ls
sudo chmod +x install.sh
sudo ./install.sh

# Verify install
dpkg -l | grep -i taniumclient
systemctl status taniumclient --no-pager

# Clean up
cd /tmp
rm -rf linux-client-bundle.zip tanium-bundle
```

**Note:** Rapid7 and Carbon Black were not provided by the security team for this build —
only Tanium was supplied. This matches fleet evidence from an existing FE 2.0 Linux client,
which also only has Tanium installed (no Rapid7/Carbon Black package, service, or directory
present). Treat Tanium as the confirmed Linux security tooling requirement unless security
says otherwise.

---

## Phase 9 — Create Cognos Service Account and Directory Structure

```bash
# Create dedicated service account
sudo useradd -m -s /bin/bash -d /home/ubuntu-admin ubuntu-admin
sudo passwd ubuntu-admin
# Set a strong password — this is the account that will own the Cognos install

# Create Cognos installation directory structure
sudo mkdir -p /opt/ibm/cognos
sudo mkdir -p /opt/CentralSquare_Analytics/{server_config,logs,content,cap}
sudo mkdir -p /opt/CentralSquare_Analytics/server_config/{install,SDK,edited}
sudo mkdir -p /opt/scripts

# Set ownership
sudo chown -R ubuntu-admin:root /opt/ibm/cognos
sudo chown -R ubuntu-admin:root /opt/CentralSquare_Analytics
```

---

## Phase 10 — Transfer and Install Cognos 11.2.4

### Option A: Transfer installer from S3

Files are staged in S3 buckets (uploaded from SharePoint: `CentralSquare Analytics > Documents > Linux 11.2.4`):
- West: `s3://cognos-installer-isb-usw2/cognos-11.2.4/`
- East: `s3://cognos-installer-hic-use1/cognos-11.2.4/`

**Note:** The `EC2-Default-SSM-AD-Role` IAM role needs the `CognosInstallerS3Access` inline policy
to read from these buckets (already added during the build).

```bash
# On the instance:
cd /opt/CentralSquare_Analytics/server_config/install

# West instance:
sudo -u ubuntu-admin aws s3 cp s3://cognos-installer-isb-usw2/cognos-11.2.4/analytics-installer-3.7.56-linuxx86.bin .
sudo -u ubuntu-admin aws s3 cp s3://cognos-installer-isb-usw2/cognos-11.2.4/casrv-11.2.4-2607141456-linuxi38664h.zip .
sudo -u ubuntu-admin aws s3 cp s3://cognos-installer-isb-usw2/cognos-11.2.4/ResponseFile.properties .

# East instance:
sudo -u ubuntu-admin aws s3 cp s3://cognos-installer-hic-use1/cognos-11.2.4/analytics-installer-3.7.56-linuxx86.bin .
sudo -u ubuntu-admin aws s3 cp s3://cognos-installer-hic-use1/cognos-11.2.4/casrv-11.2.4-2607141456-linuxi38664h.zip .
sudo -u ubuntu-admin aws s3 cp s3://cognos-installer-hic-use1/cognos-11.2.4/ResponseFile.properties .
```

### Option B: SCP/transfer directly (if S3 isn't available)

```bash
# From your workstation, use SSM port forwarding to SCP:
# Or RDP in and use Firefox to download from an internal URL
```

### Create the Response File

Marc provided the response file in SharePoint. It's already uploaded to S3 and downloaded
to the instance. Contents:

```properties
# Cognos 11.2.4 Silent Install Response File
# Full server install (Data Tier + App Tier + Gateway)

MANIFEST=casrv-manifest-casrv-11.2.4-2607141456-linuxi38664h.json
REPO=casrv-11.2.4-2607141456-linuxi38664h.zip

USER_INSTALL_DIR=/opt/ibm/cognos/analytics

# Full server = enable all tiers
CASRVR_DataTier=1
CASRVR_AppTier=1
CASRVR_Gate=1
CASRVR_VIDAImageComponent=1
```

### Run the Cognos Installer (Silent/Headless)

The content package zip is ZIP64 format (>4GB) which the Cognos installer's built-in Java
cannot read directly. **Extract it first** using 7z, then point the installer at the extracted directory.

```bash
# Install 7z (needed to extract ZIP64 archives)
sudo apt-get install -y p7zip-full

# Extract the content package (answer 'a' for Always when prompted about overwrites)
cd /opt/CentralSquare_Analytics/server_config/install
sudo -u ubuntu-admin 7z x casrv-11.2.4-2607141456-linuxi38664h.zip

# Update ResponseFile.properties to point to extracted directory
sudo -u ubuntu-admin tee /opt/CentralSquare_Analytics/server_config/install/ResponseFile.properties << 'EOF'
MANIFEST=manifest/casrv-manifest/11.2.4-2607141456/casrv-manifest-11.2.4-2607141456-linuxi38664h.json
REPO=/opt/CentralSquare_Analytics/server_config/install
USER_INSTALL_DIR=/opt/ibm/cognos/analytics
CASRVR_DataTier=1
CASRVR_AppTier=1
CASRVR_Gate=1
CASRVR_VIDAImageComponent=1
EOF

# Make installer executable
sudo chmod +x /opt/CentralSquare_Analytics/server_config/install/analytics-installer-3.7.56-linuxx86.bin

# Run headless install using xvfb (takes ~2-3 minutes)
sudo -u ubuntu-admin xvfb-run -a ./analytics-installer-3.7.56-linuxx86.bin -i silent -f ./ResponseFile.properties

# Verify installation (should show ~200k+ files and cogconfig.sh exists)
find /opt/ibm/cognos/analytics -type f | wc -l
ls -la /opt/ibm/cognos/analytics/bin64/cogconfig.sh
```

### Alternative: Run the GUI Installer via RDP

If the silent install doesn't work for 11.2.4, RDP into the instance and run:

```bash
sudo -u ubuntu-admin /opt/CentralSquare_Analytics/server_config/install/analytics-installer-3.7.56-linuxx86.bin
```

Follow the GUI prompts:
- Install location: `/opt/ibm/cognos/analytics`
- Components: Select all (Data Tier, App Tier, Gateway, VIDA)
- Accept license

---

## Phase 11 — Install JDBC Drivers

Cognos needs JDBC drivers to connect to databases. Based on the existing automation,
four drivers are required:

```bash
DRIVERS_DIR="/opt/ibm/cognos/analytics/drivers"

# West instance:
sudo -u ubuntu-admin aws s3 cp s3://cognos-installer-isb-usw2/cognos-11.2.4/jt400.jar ${DRIVERS_DIR}/
sudo -u ubuntu-admin aws s3 cp s3://cognos-installer-isb-usw2/cognos-11.2.4/mssql-jdbc-9.4.1.jre8.jar ${DRIVERS_DIR}/
sudo -u ubuntu-admin aws s3 cp s3://cognos-installer-isb-usw2/cognos-11.2.4/mssql-jdbc-12.6.0.jre8.jar ${DRIVERS_DIR}/
sudo -u ubuntu-admin aws s3 cp s3://cognos-installer-isb-usw2/cognos-11.2.4/postgresql-42.7.8.jar ${DRIVERS_DIR}/

# East instance:
sudo -u ubuntu-admin /usr/local/bin/aws s3 cp s3://cognos-installer-hic-use1/cognos-11.2.4/jt400.jar ${DRIVERS_DIR}/
sudo -u ubuntu-admin /usr/local/bin/aws s3 cp s3://cognos-installer-hic-use1/cognos-11.2.4/mssql-jdbc-9.4.1.jre8.jar ${DRIVERS_DIR}/
sudo -u ubuntu-admin /usr/local/bin/aws s3 cp s3://cognos-installer-hic-use1/cognos-11.2.4/mssql-jdbc-12.6.0.jre8.jar ${DRIVERS_DIR}/
sudo -u ubuntu-admin /usr/local/bin/aws s3 cp s3://cognos-installer-hic-use1/cognos-11.2.4/postgresql-42.7.8.jar ${DRIVERS_DIR}/

# Verify
ls -la ${DRIVERS_DIR}/*.jar
```

Drivers staged in S3:
- West: `s3://cognos-installer-isb-usw2/cognos-11.2.4/`
- East: `s3://cognos-installer-hic-use1/cognos-11.2.4/`

Final driver set (per Marc — only need one mssql version):
- `jt400.jar` (iSeries/AS400)
- `mssql-jdbc-12.6.0.jre8.jar` (SQL Server)
- `postgresql-42.7.8.jar` (PostgreSQL)

---

## Phase 11b — Deploy SPSOne CAP and Images

Files from SharePoint (`CentralSquare Analytics > Documents > Linux 11.2.4`):
- `SPSOne CAP.zip` — contains AAA, Configuration, Templates folders
- `images.zip` — contains report images

```bash
cd /tmp

# West:
aws s3 cp "s3://cognos-installer-isb-usw2/cognos-11.2.4/SPSOne CAP.zip" .
aws s3 cp s3://cognos-installer-isb-usw2/cognos-11.2.4/images.zip .

# East:
sudo -u ubuntu-admin /usr/local/bin/aws s3 cp "s3://cognos-installer-hic-use1/cognos-11.2.4/SPSOne CAP.zip" .
sudo -u ubuntu-admin /usr/local/bin/aws s3 cp s3://cognos-installer-hic-use1/cognos-11.2.4/images.zip .

# Extract and deploy images
unzip images.zip -d images
cp -r images/* /opt/ibm/cognos/analytics/webcontent/bi/samples/

# Extract and deploy SPSOne CAP
unzip "SPSOne CAP.zip" -d spsone_cap
cp -r spsone_cap/AAA /opt/ibm/cognos/analytics/webapps/p2pd/WEB-INF/
cp -r spsone_cap/Templates/ps /opt/ibm/cognos/analytics/templates/
cp spsone_cap/Configuration/MotioCAP_NAMESPACE.properties /opt/ibm/cognos/analytics/configuration/

# Set ownership
sudo chown -R ubuntu-admin:root /opt/ibm/cognos/analytics/webcontent/bi/samples/
sudo chown -R ubuntu-admin:root /opt/ibm/cognos/analytics/webapps/p2pd/WEB-INF/AAA
sudo chown -R ubuntu-admin:root /opt/ibm/cognos/analytics/templates/ps
sudo chown -R ubuntu-admin:root /opt/ibm/cognos/analytics/configuration/MotioCAP_NAMESPACE.properties

# Clean up temp
rm -rf /tmp/images /tmp/images.zip /tmp/spsone_cap "/tmp/SPSOne CAP.zip"

# Clean up installer files (per Marc)
rm -rf /opt/CentralSquare_Analytics/server_config/install/*
```

---

## Phase 12 — Configure Cognos (Generic Settings Only)

Only configure settings that are universal across all clients. Client-specific settings
(database, hostname, LDAP, certificates) are configured at deploy time.

### Configure Shared Library Paths

```bash
# Register NSS libraries for dynamic linker (required for LDAP auth plugin)
# NOTE: Do NOT add /opt/ibm/cognos/analytics/bin64 here — it conflicts with system libz.
# The LD_LIBRARY_PATH in cogconfig.sh handles Cognos-specific library paths at runtime.
sudo tee /etc/ld.so.conf.d/cognos.conf << 'EOF'
/usr/lib/x86_64-linux-gnu/nss
EOF
sudo ldconfig

# Add LD_LIBRARY_PATH to cogconfig.sh
COGNOS_COGCONFIG="/opt/ibm/cognos/analytics/bin64/cogconfig.sh"
if ! grep -q "LD_LIBRARY_PATH" "$COGNOS_COGCONFIG"; then
    sudo sed -i '/^CA_INSTALL_DIR=/a export LD_LIBRARY_PATH="${CA_INSTALL_DIR}/bin64:${LD_LIBRARY_PATH}"' "$COGNOS_COGCONFIG"
fi
```

### Open Cognos Configuration GUI (via RDP)

RDP into the instance and run:

```bash
sudo -u ubuntu-admin /opt/ibm/cognos/analytics/bin64/cogconfig.sh
```

In the Cognos Configuration GUI, set these **generic** values:

| Setting | Value | Notes |
|---------|-------|-------|
| Gateway URI | `http://localhost:9300/bi` | Placeholder — overwritten per client |
| Dispatcher URI | `http://localhost:9300/p2pd/servlet/dispatch` | Standard |
| Temp file location | `/opt/ibm/cognos/analytics/temp` | Default |
| Log level | Default | |
| Content Store | **Leave unconfigured** | Client-specific |

**Save the configuration but DO NOT start the service.**

---

## Phase 13 — Create systemd Service for Cognos

This follows the same pattern used in `lnx-server-config.sh`:

```bash
sudo tee /etc/systemd/system/cognos.service << 'EOF'
[Unit]
Description=IBM Cognos Analytics 11.2.4 Service
Wants=network-online.target
After=network-online.target

[Service]
Type=forking
User=ubuntu-admin
Group=root
WorkingDirectory=/opt/ibm/cognos/analytics/bin64

Environment="JAVA_HOME=/opt/ibm/cognos/analytics/ibm-jre/jre"
ExecStart=/opt/ibm/cognos/analytics/bin64/cogconfig.sh -s
ExecStop=/opt/ibm/cognos/analytics/bin64/cogconfig.sh -stop

Restart=on-failure
RestartSec=30

# Prevent core dumps from consuming disk
LimitCORE=0

TimeoutStartSec=infinity
TimeoutStopSec=300

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd
sudo systemctl daemon-reload

# ENABLE but do NOT start — Cognos cannot start without a configured content store
# The service will be started manually after per-client config is applied at deploy time
sudo systemctl enable cognos.service
```

---

## Phase 14 — Install Amazon Root CA Certificates

**Decision Point:** Only mandatory if Cognos connects to RDS over SSL. If the FE 1.0
clients use RDS for the content store and require encrypted connections, then yes. If
they connect to databases without SSL, or if Marc's Cognos config doesn't enforce SSL
on the JDBC connection, then no. Ask Marc if the content store connections use SSL.

Required for RDS SSL connections:

```bash
CERTS_DIR="/opt/CentralSquare_Analytics/AWSCerts"
sudo mkdir -p "$CERTS_DIR"

# Download Amazon Root CAs
ROOT_CA_URLS=(
    "https://www.amazontrust.com/repository/AmazonRootCA1.cer"
    "https://www.amazontrust.com/repository/AmazonRootCA2.cer"
    "https://www.amazontrust.com/repository/AmazonRootCA3.cer"
    "https://www.amazontrust.com/repository/AmazonRootCA4.cer"
    "https://www.amazontrust.com/repository/SFSRootCAG2.cer"
)

JAVA_KEYSTORE="/opt/ibm/cognos/analytics/ibm-jre/jre/lib/security/cacerts"
KEYTOOL="/opt/ibm/cognos/analytics/ibm-jre/jre/bin/keytool"
STOREPASS="changeit"

CERT_NUM=1
for url in "${ROOT_CA_URLS[@]}"; do
    FILENAME=$(basename "$url")
    curl -s "$url" -o "${CERTS_DIR}/${FILENAME}"
    echo "Downloaded $FILENAME"

    if [[ -f "$KEYTOOL" ]] && [[ -f "$JAVA_KEYSTORE" ]]; then
        sudo -u ubuntu-admin "$KEYTOOL" -import -noprompt \
            -file "${CERTS_DIR}/${FILENAME}" \
            -keystore "$JAVA_KEYSTORE" \
            -storepass "$STOREPASS" \
            -alias "AmazonRootCA${CERT_NUM}"
        echo "Imported $FILENAME into Java keystore"
    fi
    ((CERT_NUM++))
done

# Also download the RDS regional certificate bundles
curl -s https://truststore.pki.rds.amazonaws.com/us-west-2/us-west-2-bundle.p7b \
  -o /opt/scripts/us-west-2-bundle.p7b
curl -s https://truststore.pki.rds.amazonaws.com/us-east-1/us-east-1-bundle.p7b \
  -o /opt/scripts/us-east-1-bundle.p7b
```

---

## Phase 15 — ~~Create Self-Signed SSL Certificate~~ (SKIPPED)

**Skipped per Marc.** Not needed for the AMI. Client-specific certs configured at deploy time.

```bash
SSL_DIR="/etc/ssl/cognos"
sudo mkdir -p "$SSL_DIR"

sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout "$SSL_DIR/cognos-server.key" \
    -out "$SSL_DIR/cognos-server.crt" \
    -subj "/CN=cognos-placeholder.local"

sudo chmod 600 "$SSL_DIR/cognos-server.key"
sudo chmod 644 "$SSL_DIR/cognos-server.crt"
```

This is a placeholder. Real certificates will be configured per-client at deploy time.

---

## Phase 16 — Install Healthcheck Page

```bash
# Simple healthcheck page for load balancer health monitoring
sudo tee /var/www/html/healthcheck.html << 'EOF'
<!DOCTYPE html>
<html><head><title>Health Check</title></head>
<body><p>OK</p></body></html>
EOF
```

---

## Phase 17 — Validation

Run through these checks before proceeding to AMI creation:

```bash
echo "=== Validation Checklist ==="

# 1. xrdp running
echo "--- xrdp ---"
sudo systemctl status xrdp --no-pager | grep "Active:"

# 2. SSM agent running
echo "--- SSM Agent ---"
sudo systemctl status snap.amazon-ssm-agent.amazon-ssm-agent.service --no-pager | grep "Active:"

# 3. Apache running
echo "--- Apache ---"
sudo systemctl status apache2 --no-pager | grep "Active:"
curl -s -o /dev/null -w "  HTTP status: %{http_code}\n" http://localhost

# 4. Java installed
echo "--- Java ---"
java -version 2>&1 | head -1

# 5. Cognos binaries present
echo "--- Cognos Install ---"
ls -la /opt/ibm/cognos/analytics/bin64/cogconfig.sh 2>&1

# 6. JDBC drivers present
echo "--- JDBC Drivers ---"
ls /opt/ibm/cognos/analytics/drivers/*.jar 2>/dev/null | wc -l
echo "  driver files found"

# 7. systemd service loaded
echo "--- Cognos Service ---"
sudo systemctl status cognos.service --no-pager | grep "Loaded:"

# 8. PostgreSQL client
echo "--- psql ---"
psql --version

# 9. sqlcmd
echo "--- sqlcmd ---"
/opt/mssql-tools18/bin/sqlcmd -? 2>&1 | head -1

# 10. AWS CLI
echo "--- AWS CLI ---"
aws --version

# 11. Proxy config persisted
echo "--- Proxy ---"
grep "http_proxy" /etc/environment | head -1

# 12. slapd installed (disabled — configured per-client)
echo "--- OpenLDAP ---"
dpkg -l slapd | grep -E "^ii" | awk '{print $2, $3}'

# 13. Tanium client installed and running
echo "--- Tanium ---"
dpkg -l taniumclient | grep -E "^ii" | awk '{print $2, $3}'
systemctl status taniumclient --no-pager | grep "Active:"
```

### Reboot Test

```bash
sudo reboot
```

After reboot, re-validate:
- RDP into the instance — XFCE desktop loads
- SSM session works
- Apache is running (curl http://localhost returns 200)
- Cognos service unit is loaded (inactive is expected — no content store configured)

---

## Phase 18 — Cleanup (Pre-AMI)

This is the Linux equivalent of Windows Sysprep. `cloud-init clean` resets the
machine identity so each new instance launched from this AMI gets a unique identity.

### What This Does (Linux "Sysprep" Equivalent)

| Concern | What We Reset | What Happens on New Instance Boot |
|---------|---------------|-----------------------------------|
| Hostname | `cloud-init clean` resets state | cloud-init sets hostname from EC2 metadata (unique per instance) |
| Machine ID | Truncate `/etc/machine-id` | systemd regenerates a new unique ID on boot |
| SSH host keys | Delete `/etc/ssh/ssh_host_*` | `ssh-keygen` creates new unique keys on boot |
| Network identity | cloud-init handles DHCP | New IP assigned via DHCP, unique per instance |
| User sessions | Clear history, wtmp/btmp | No stale session data carried over |

**Unlike Windows Sysprep:** The instance IS still usable after these steps. You CAN
start it again — cloud-init will re-run, regenerate keys, set a new hostname, etc.
It won't be "broken" like a sysprep'd Windows box. However, best practice is:
- Stop the instance
- Create the AMI
- Leave the build instance stopped (don't terminate — useful for v1.1 updates later)
- Deploy new instances from the AMI

**Computer name / hostname:** Each new instance launched from this AMI will automatically
get a unique hostname based on its private IP (e.g. `ip-10-60-5-123`). There is NO
risk of duplicate hostnames like Windows without sysprep. cloud-init handles this on
every boot.

### Cleanup Commands (run on both instances)

```bash
# Clean apt cache (reduces AMI size)
sudo apt-get clean
sudo apt-get autoremove -y

# Remove the ubuntu user password (force set on first login per client)
sudo passwd -d ubuntu

# === CLOUD-INIT CLEAN — THIS IS THE LINUX "SYSPREP" ===
sudo cloud-init clean --logs --seed

# Remove SSH host keys (regenerated automatically on new instance boot)
sudo rm -f /etc/ssh/ssh_host_*

# Truncate machine-id (systemd regenerates on boot)
sudo truncate -s 0 /etc/machine-id
sudo rm -f /var/lib/dbus/machine-id

# Clear bash history for all users
history -c && cat /dev/null > ~/.bash_history
sudo -u ubuntu bash -c 'cat /dev/null > ~/.bash_history'
sudo -u ubuntu-admin bash -c 'cat /dev/null > ~/.bash_history'

# Clear login records
sudo rm -f /var/log/wtmp /var/log/btmp

# Clear temp files
sudo rm -rf /tmp/* /var/tmp/*

# DO NOT shut down from inside the instance — stop it from AWS CLI/Console
```

---

## Phase 19 — Create AMI (from your workstation — PowerShell)

```powershell
# Stop the instance (do NOT terminate)
aws ec2 stop-instances --profile PALegacyFinEntISB --region us-west-2 --instance-ids i-0067f3e81d03d22b5

aws ec2 wait instance-stopped --profile PALegacyFinEntISB --region us-west-2 --instance-ids i-0067f3e81d03d22b5

# Create the AMI
$datestamp = Get-Date -Format "yyyyMMdd"
aws ec2 create-image --profile PALegacyFinEntISB --region us-west-2 --instance-id i-0067f3e81d03d22b5 --name "fe-legacy-cognos-11.2.4-ubuntu-24.04-usw2-v1.0-$datestamp" --description "FE Legacy Cognos 11.2.4 | Ubuntu 24.04 | XFCE+xrdp | Apache | us-west-2" --tag-specifications "ResourceType=image,Tags=[{Key=Name,Value=fe-legacy-cognos-11.2.4-usw2},{Key=Version,Value=1.0},{Key=Owner,Value=CloudOps},{Key=CognosVersion,Value=11.2.4},{Key=OS,Value=Ubuntu-24.04},{Key=Region,Value=us-west-2},{Key=Purpose,Value=FE-Legacy-Migration}]" "ResourceType=snapshot,Tags=[{Key=Name,Value=fe-legacy-cognos-11.2.4-usw2-snapshot}]"

# Wait for AMI to become available (takes several minutes — replace with AMI ID from create-image output)
aws ec2 wait image-available --profile PALegacyFinEntISB --region us-west-2 --image-ids ami-0f7d564d88c508135
```

Note the AMI ID from the `create-image` output.

---

## Phase 20 — Build the East AMI

Repeat Phases 2–19 in us-east-1 with the following differences:

| Setting | us-west-2 (ISB) | us-east-1 (HIC) |
|---------|-----------------|-----------------|
| Profile | `PALegacyFinEntISB` | `PALegacyFinEntHIC` |
| Region flag | `--region us-west-2` | `--region us-east-1` |
| Proxy | `inf-proxy-usw2.cloud.lcl:3128` | `inf-proxy-use1.cloud.lcl:3128` |
| AMI name suffix | `usw2` | `use1` |
| Instance name tag | `cognos-11.2.4-ami-build-usw2` | `cognos-11.2.4-ami-build-use1` |

**All other steps are identical** — only the proxy URL in `/etc/environment`,
`/etc/apt/apt.conf.d/95proxy`, and snap proxy differs.

### Create East AMI (PowerShell)

```powershell
aws ec2 stop-instances --profile PALegacyFinEntHIC --region us-east-1 --instance-ids i-0bbee90ce9fab60be

aws ec2 wait instance-stopped --profile PALegacyFinEntHIC --region us-east-1 --instance-ids i-0bbee90ce9fab60be

$datestamp = Get-Date -Format "yyyyMMdd"
aws ec2 create-image --profile PALegacyFinEntHIC --region us-east-1 --instance-id i-0bbee90ce9fab60be --name "fe-legacy-cognos-11.2.4-ubuntu-24.04-use1-v1.0-$datestamp" --description "FE Legacy Cognos 11.2.4 | Ubuntu 24.04 | XFCE+xrdp | Apache | us-east-1" --tag-specifications "ResourceType=image,Tags=[{Key=Name,Value=fe-legacy-cognos-11.2.4-use1},{Key=Version,Value=1.0},{Key=Owner,Value=CloudOps},{Key=CognosVersion,Value=11.2.4},{Key=OS,Value=Ubuntu-24.04},{Key=Region,Value=us-east-1},{Key=Purpose,Value=FE-Legacy-Migration}]" "ResourceType=snapshot,Tags=[{Key=Name,Value=fe-legacy-cognos-11.2.4-use1-snapshot}]"

aws ec2 wait image-available --profile PALegacyFinEntHIC --region us-east-1 --image-ids ami-0dd54ace916faedd6
```

---

## Post-AMI: Deploying to a Client

When deploying this AMI to an FE 1.0 legacy client, the process is:

1. Launch EC2 instance from the golden AMI in the client's account/region
2. Connect via SSM or RDP
3. Set passwords for `ubuntu` and `ubuntu-admin` users
4. Configure OpenLDAP (run `lnx-ldapconfig.sh` or configure manually)
5. Open Cognos Configuration GUI (RDP → `cogconfig.sh`)
6. Set client-specific values:
   - Content store database host, name, user, password
   - Gateway URI / hostname
   - SMTP settings (if applicable)
   - Authentication namespace (LDAP/OIDC)
7. Configure Apache virtual host for the client's DNS name
8. Generate or install SSL certificate for the client
9. Start Cognos: `sudo systemctl start cognos`
10. Validate: `curl http://localhost:9300/bi` returns 200/302
11. Configure load balancer target group to point to this instance

---

## Software Inventory (What's on the AMI)

| Component | Version | Purpose |
|-----------|---------|---------|
| Ubuntu | 24.04 LTS | Base OS |
| XFCE4 | (latest from apt) | Lightweight desktop for GUI access |
| xrdp | (latest from apt) | Remote Desktop Protocol server |
| xvfb | (latest from apt) | Virtual framebuffer for headless GUI operations |
| Firefox | (Mozilla PPA deb) | Web browser for Cognos web console |
| Apache2 | (latest from apt) | Reverse proxy / web server |
| IBM Cognos Analytics | 11.2.4 | Reporting/BI platform |
| OpenJDK | 11 | Required by lnxsdkautomation.jar |
| IBM JRE | (bundled with Cognos) | Cognos runtime |
| PostgreSQL client (psql) | (latest from pgdg) | Database connectivity for content store |
| mssql-tools18 (sqlcmd) | (latest from MS repo) | SQL Server connectivity |
| OpenLDAP (slapd) | (latest from apt) | Local LDAP for Cognos auth |
| AWS CLI v2 | (latest) | AWS API access |
| SSM Agent | (pre-installed snap) | AWS Systems Manager access |
| jq | (latest from apt) | JSON processing in scripts |
| xmlstarlet | (latest from apt) | XML config file editing |
| curl, wget, unzip | (latest from apt) | Utility tools |
| JDBC: mssql-jdbc | 12.6.0.jre8 | SQL Server driver for Cognos |
| JDBC: postgresql | 42.7.8 | PostgreSQL driver for Cognos |
| JDBC: jt400 | (latest) | iSeries/AS400 driver for Cognos |
| SPSOne CAP | (from SharePoint) | AAA jars, MotioCAP properties, Templates |
| Tanium Client | (from security team bundle, v1.2) | Endpoint security/management agent |

---

## Key Differences from FE 2.0 Automation

| Aspect | FE 2.0 (automated) | FE 1.0 Legacy (this AMI) |
|--------|--------------------|-----------------------|
| Deployment method | CloudFormation + ASG + cfn-init | Manual AMI launch per client |
| Base AMI | cloud-foundation-ubuntu-2404 (hardened) | Standard Ubuntu 24.04 from AWS |
| Cognos version | 12.x | 11.2.4 |
| Config injection | Automated (S3 + Secrets Manager) | Manual (RDP + Cognos Config GUI) |
| Scaling | Auto Scaling Group | Single instance per client |
| Client config | JSON files in S3 per tenant | Configured manually per deploy |
| LDAP | Auto-configured during bootstrap | Configured manually per deploy |
| Proxy | Handled by base AMI (assumed) | Baked into this AMI per region |

---

## Open Questions for Marc/Shawn

- [ ] Confirm Cognos 11.2.4 installer filename (the `.bin` and `.zip` names) **✅ CONFIRMED**
- [ ] Where should the installer be staged? (S3 bucket path) **✅ Done — cognos-installer-isb-usw2 / cognos-installer-hic-use1**
- [ ] Confirm Ubuntu 24.04 works with 11.2.4 (not on IBM supported list — test first) **✅ WORKS**
- [ ] Does the client account already have the foundation base AMI, or use stock Ubuntu? **Stock Ubuntu 24.04**
- [ ] What security tooling is pre-loaded in the client account (CrowdStrike, Tanium, etc.)? **✅ Tanium confirmed as the required Linux tool — bundle provided by security team, installed on AMI in Phase 8b (v1.2)**
- [ ] Do security tools need specific exceptions for Cognos ports (9300, 9080, 389)?
- [ ] Is there an existing ALB in the client accounts, or does one need to be created per client?
- [ ] Will GlobalLogic need RDP access to deployed instances for migrations?
- [ ] Does `SG-isb` / `SG-dhil` already allow TCP 3389 inbound for RDP during the build phase? **✅ YES — both SGs allow all traffic from 0.0.0.0/0**

## AMI Update — v1.1 (Complete)

The following were added to the AMI and re-baked as v1.1.

1. **Added `ubuntu-admin` to sudoers** (per Marc):
```bash
echo "ubuntu-admin ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/ubuntu-admin
sudo chmod 440 /etc/sudoers.d/ubuntu-admin
```

2. **Installed domain join packages** (avoids slow proxy downloads per-client):
```bash
sudo apt-get install -y realmd sssd sssd-tools adcli packagekit
```

3. **Updated no_proxy bypass list** (added internal domains so traffic doesn't route through proxy):
`.aspgov.com`, `.aspgov.pri`, `.govnow.com` added to the `no_proxy` / `NO_PROXY` lines in `/etc/environment`:
```
no_proxy=localhost,127.0.0.1,169.254.169.254,10.0.0.0/8,192.168.0.0/16,172.16.0.0/12,.cloud.lcl,.amazonaws.com,.aspgov.com,.aspgov.pri,.govnow.com
```

**Note for the client deploy runbook:** since `realmd`/`sssd`/`sssd-tools`/`adcli`/`packagekit`
are now baked into the AMI, Step 5 of `fe-legacy-cognos-client-deploy.md` (Domain Join) no
longer needs the `apt-get install` line — packages are already present, only `realm discover`
/ `realm join` are needed per client.

---

## AMI Update — v1.2 (Complete)

Added the Tanium client (see Phase 8b) using the Linux bundle provided directly by the
security team. `ami-0e6dbd9e1bb26ffb4` (west) and `ami-0f8dc6e50d85be4c5` (east) are the
current v1.2 golden AMIs — all AMI ID references throughout this document and the client
deploy runbook reflect this build.

Per security team guidance, the Tanium agent periodically re-pulls host information
(hostname, etc.), so no per-client identity reset is required — baked into the AMI once,
inherited by every instance launched from it. This is a one-time AMI-level step; the
per-client deploy runbook does not install Tanium.

---

## Reference

- Existing automation repo: `$env:USERPROFILE\repos\analytics_cloudautomation`
- Desktop install script: `linux-cognos-automation/cfn/bootstrap/scripts/lnx-install-desktop.sh`
- Server config script: `linux-cognos-automation/cfn/bootstrap/scripts/lnx-server-config.sh`
- Apache config script: `linux-cognos-automation/cfn/bootstrap/scripts/lnx-apache-config.sh`
- Cognos install script: `linux-cognos-automation/cfn/bootstrap/scripts/lnx-install-cognos.sh`
- LDAP config script: `linux-cognos-automation/cfn/bootstrap/scripts/lnx-ldapconfig.sh`
- REST API config: `linux-cognos-automation/cfn/bootstrap/scripts/lnx-cog-config-restapi.sh`
- CloudFormation template: `linux-cognos-automation/cfn/templates/lnx-cognos-stack.yml`
- Deployment checklist: `linux-cognos-automation/docs/lnx-cognos-deployment-checklist.md`
