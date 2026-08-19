name: cis-hardening-ubuntu2404
description: Applies CIS Benchmark Level 1 Server hardening to Ubuntu 24.04 via OpenSCAP/ComplianceAsCode.
schemaVersion: "1.0"

phases:
  - name: build
    steps:
      - name: FullSystemUpgrade
        action: ExecuteBash
        onFailure: Abort
        timeoutSeconds: 1800
        inputs:
          commands:
            # Patch to current before hardening, not after — hardening should apply to
            # the packages the AMI will actually ship with, not a stale pre-patch state.
            - export DEBIAN_FRONTEND=noninteractive
            - apt-get update
            - apt-get -y -o Dpkg::Options::="--force-confold" dist-upgrade
            - apt-get -y autoremove
            - apt-get clean

      - name: RebootIfRequired
        action: Reboot
        onFailure: Abort
        inputs:
          delaySeconds: 30

      - name: PreHardenFixes
        action: ExecuteBash
        onFailure: Abort
        inputs:
          commands:
            # nftables_ensure_default_deny_policy: carried over verbatim from the
            # ubuntu-2204 component, which needed this because that base image ships
            # nftables masked. NOT YET CONFIRMED whether the 24.04 Canonical Pro base
            # image does the same — this step is defensive (unmask is a no-op if it's
            # already unmasked) but verify via the build/validate reports whether this
            # rule actually needed fixing here, or was already passing.
            - systemctl unmask nftables || true
            - |
              if [ ! -s /etc/nftables.conf ] || ! grep -q 'hook input' /etc/nftables.conf; then
                cat > /etc/nftables.conf <<'NFT_EOF'
              #!/usr/sbin/nft -f
              flush ruleset
              table inet filter {
                chain input {
                  type filter hook input priority 0; policy drop;
                  ct state established,related accept
                  iif lo accept
                  tcp dport 22 accept
                  icmp type echo-request accept
                }
                chain forward {
                  type filter hook forward priority 0; policy drop;
                }
                chain output {
                  type filter hook output priority 0; policy drop;
                  ct state established,related accept
                  oif lo accept
                  udp dport 53 accept
                  tcp dport { 53, 80, 443 } accept
                }
              }
              NFT_EOF
              fi
            - systemctl enable nftables || true

      - name: InstallOpenSCAP
        action: ExecuteBash
        onFailure: Abort
        inputs:
          commands:
            # Package names differ from ubuntu-2204: Ubuntu 24.04's 64-bit time_t
            # transition renamed the library package to libopenscap25t64 (was
            # libopenscap8), and the oscap CLI binary now ships in its own
            # openscap-scanner package rather than being pulled in transitively —
            # confirmed via packages.ubuntu.com, not carried over from the 22.04 list.
            # No apt package ships the CIS datastream itself, so pull it directly from
            # ComplianceAsCode's own release (same pinned SSG_VERSION as ubuntu-2204 —
            # 0.1.81 already includes ubuntu2404 support, added upstream in 0.1.76).
            - apt-get update
            - apt-get install -y openscap-scanner libopenscap25t64 python3-openscap awscli curl ca-certificates
            - |
              set -euo pipefail
              SSG_VERSION="0.1.81"
              mkdir -p /usr/share/xml/scap/ssg/content /tmp/ssg-download
              curl -fsSL -o /tmp/ssg-download/ssg.tar.gz \
                "https://github.com/ComplianceAsCode/content/releases/download/v$${SSG_VERSION}/scap-security-guide-$${SSG_VERSION}.tar.gz"
              tar -xzf /tmp/ssg-download/ssg.tar.gz -C /tmp/ssg-download
              cp "/tmp/ssg-download/scap-security-guide-$${SSG_VERSION}/ssg-ubuntu2404-ds.xml" \
                /usr/share/xml/scap/ssg/content/
              rm -rf /tmp/ssg-download

      - name: LocateDatastreamAndProfile
        action: ExecuteBash
        onFailure: Abort
        inputs:
          commands:
            - |
              set -euo pipefail
              DS=""
              for candidate in \
                /usr/share/xml/scap/ssg/content/ssg-ubuntu2404-ds.xml \
                /usr/share/scap-security-guide/ssg-ubuntu2404-ds.xml
              do
                if [ -f "$candidate" ]; then DS="$candidate"; break; fi
              done
              if [ -z "$DS" ]; then
                echo "No ssg-ubuntu2404-ds.xml datastream found on this AMI." >&2
                echo "OPEN RISK (see project plan): ComplianceAsCode's Ubuntu 24.04 CIS profile coverage is unconfirmed." >&2
                echo "Confirm via 'oscap info <datastream>' on a test instance before relying on this component." >&2
                exit 1
              fi
              echo "$DS" > /tmp/datastream_path
              # OPEN RISK: ComplianceAsCode's own 24.04 release notes describe the CIS
              # profile as "draft" (added v0.1.76, alongside the new ubuntu2404 product
              # itself) — expect this to be less mature than the 22.04 profile used by
              # the sibling component. Prefer a CIS-named profile; fall back to any
              # profile containing "cis" if the exact ID below doesn't match this
              # datastream's actual profile naming.
              PROFILE="xccdf_org.ssgproject.content_profile_cis_level1_server"
              if ! oscap info "$DS" 2>/dev/null | grep -q "$PROFILE"; then
                PROFILE=$(oscap info "$DS" 2>/dev/null | grep -oP 'xccdf_org\.ssgproject\.content_profile_cis\S*' | head -1 || true)
              fi
              if [ -z "$PROFILE" ]; then
                echo "No CIS profile found in $DS — see OPEN RISK note above." >&2
                exit 1
              fi
              echo "$PROFILE" > /tmp/profile_id

      - name: RemediateCisProfile
        action: ExecuteBash
        onFailure: Abort
        timeoutSeconds: 3600
        inputs:
          commands:
            - |
              set -uo pipefail
              DS=$(cat /tmp/datastream_path)
              PROFILE=$(cat /tmp/profile_id)
              mkdir -p /var/log/cis-hardening

              # Same multi-pass convergence loop as ubuntu-2204 — a single --remediate
              # pass leaves order-dependent rules failing there (23 -> 7 -> 6 over 3
              # passes). Not yet re-measured for this profile specifically; loop until
              # 2 consecutive passes agree or the pass cap is hit, same as the sibling
              # component, rather than assuming the same convergence curve applies.
              MAX_PASSES=5
              prev_fail_count=-1
              for pass in $(seq 1 $MAX_PASSES); do
                echo "=== Remediation pass $pass/$MAX_PASSES ==="
                oscap xccdf eval \
                  --profile "$PROFILE" \
                  --remediate \
                  --results /var/log/cis-hardening/build-results.xml \
                  --report /var/log/cis-hardening/build-report.html \
                  "$DS"
                rc=$?
                if [ "$rc" -eq 1 ]; then
                  echo "oscap reported a tool error (exit 1) during remediation pass $pass" >&2
                  exit 1
                fi
                fail_count=$(grep -o 'result>fail' /var/log/cis-hardening/build-results.xml | wc -l)
                echo "Pass $pass: $fail_count rules failing (exit code $rc)"
                if [ "$fail_count" -eq "$prev_fail_count" ]; then
                  echo "Converged after $pass passes ($fail_count rules still failing — expected for non-automatable/policy-decision rules)."
                  break
                fi
                prev_fail_count=$fail_count
              done
              echo "Final remediation state: $fail_count rules failing after $pass pass(es)."
              exit 0

      - name: UploadBuildReport
        action: ExecuteBash
        onFailure: Continue
        inputs:
          commands:
            - |
              aws s3 cp /var/log/cis-hardening/build-report.html \
                s3://${logs_bucket}/ubuntu2404/build-report-$(date -u +%Y%m%dT%H%M%SZ).html || true

  - name: validate
    steps:
      - name: RevalidateCisProfile
        action: ExecuteBash
        onFailure: Abort
        timeoutSeconds: 3600
        inputs:
          commands:
            - |
              set -uo pipefail
              DS=$(cat /tmp/datastream_path)
              PROFILE=$(cat /tmp/profile_id)
              oscap xccdf eval \
                --profile "$PROFILE" \
                --results /var/log/cis-hardening/validate-results.xml \
                --report /var/log/cis-hardening/validate-report.html \
                "$DS"
              rc=$?
              if [ "$rc" -eq 1 ]; then
                echo "oscap reported a tool error (exit 1) during validation" >&2
                exit 1
              fi
              echo "oscap validation exit code: $rc (0=pass, 2=some rules failed as expected — see uploaded report)"
              exit 0

      - name: UploadValidateReport
        action: ExecuteBash
        onFailure: Continue
        inputs:
          commands:
            - |
              aws s3 cp /var/log/cis-hardening/validate-report.html \
                s3://${logs_bucket}/ubuntu2404/validate-report-$(date -u +%Y%m%dT%H%M%SZ).html || true
