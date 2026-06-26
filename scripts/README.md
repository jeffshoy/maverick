# Scripts

All CloudOps SRE automation, organized by domain. Run any script via the **Kiro task launcher** (Ctrl+Shift+P → Tasks: Run Task) — see the repo root [`README.md`](../README.md) for setup.

| Folder | Domain | Scripts |
|--------|--------|---------|
| [`plus/`](plus/README.md) | PLUS Customer Users | Create, enable, and disable PLUS customer users (aspgov.pri + SQL + rpt + centroid) |
| [`ad/`](ad/README.md) | Active Directory | User disable, user creation (FE Centroid, Aptean) |
| [`adssp/`](adssp/README.md) | ADSS+ | User sync, IBMi group management, RADIUS/NPS setup |
| [`aws/`](aws/README.md) | AWS EC2 / SSM | Disk expand, server reboot, service restart, site monitor, RDS license reset, SSM connect |
| [`aws-dx/`](aws-dx/) | AWS Direct Connect | Route-table helpers (Bash) |
| [`sectigo/`](sectigo/) | Sectigo | Mass certificate revocation, mass server registration |
| [`dns/`](dns/) | DNS | Microsoft DNS record changes |
