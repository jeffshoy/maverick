import subprocess
import os
import datetime

# Log file
LOG_FILE = "linux_debug.log"

def log_section(title):
    """Write section headers to log file."""
    with open(LOG_FILE, "a") as log:
        log.write(f"\n===== {title} =====\n")
    print(f"\n===== {title} =====")

def run_command(command):
    """Runs a shell command and writes output to log file."""
    try:
        result = subprocess.run(command, shell=True, text=True, capture_output=True)
        output = result.stdout.strip() if result.stdout else "No output"
        error = result.stderr.strip() if result.stderr else None
        
        # Write to log
        with open(LOG_FILE, "a") as log:
            log.write(output + "\n")
            if error:
                log.write(f"ERROR: {error}\n")

        # Print to console
        print(output)
        if error:
            print(f"ERROR: {error}")

    except Exception as e:
        with open(LOG_FILE, "a") as log:
            log.write(f"Exception: {str(e)}\n")
        print(f"Exception: {str(e)}")

# Create log file with timestamp
with open(LOG_FILE, "w") as log:
    log.write(f"Linux Server Debug Report - {datetime.datetime.now()}\n")

# 1️⃣ System Information
log_section("System Information")
run_command("uname -a")
run_command("uptime")
run_command("hostnamectl")

# 2️⃣ Check System Logs for Errors
log_section("Recent System Errors")
run_command("journalctl -p 3 -n 20")  # Show last 20 critical errors

# 3️⃣ CPU and Memory Usage
log_section("CPU and Memory Usage")
run_command("top -b -n1 | head -15")
run_command("free -m")

# 4️⃣ Disk Usage and I/O Performance
log_section("Disk Usage")
run_command("df -h")
log_section("I/O Performance (10-second sample)")
run_command("iostat -x 10 1")

# 5️⃣ Check Running and Failed Services
log_section("Failed Services")
run_command("systemctl --failed")

# 6️⃣ Check Open Network Connections
log_section("Open Network Ports")
run_command("ss -tulnp")

# 7️⃣ Firewall Rules
log_section("Firewall Rules")
run_command("firewall-cmd --list-all")

# 8️⃣ SELinux Status
log_section("SELinux Status")
run_command("sestatus")

# 9️⃣ Security: List Available Security Updates
log_section("Available Security Updates")
run_command("dnf list updates --security")

# 🔟 Find World-Writable Files (Potential Security Risk)
log_section("World-Writable Files")
run_command("find / -perm -o+w -type f 2>/dev/null")

# ✅ Debugging Completed
log_section("Summary")
print(f"Debugging completed! Results saved in {LOG_FILE}")
