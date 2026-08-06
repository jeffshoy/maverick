name: cis-hardening-rhel9
description: Applies CIS Benchmark Level 1 Server hardening to RHEL 9 via OpenSCAP/ComplianceAsCode.
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
            - dnf upgrade -y
            - dnf clean all

      - name: RebootIfRequired
        action: Reboot
        onFailure: Abort
        inputs:
          delaySeconds: 30

      - name: InstallOpenSCAP
        action: ExecuteBash
        onFailure: Abort
        inputs:
          commands:
            - dnf install -y openscap-scanner scap-security-guide awscli

      - name: LocateDatastream
        action: ExecuteBash
        onFailure: Abort
        inputs:
          commands:
            - |
              set -euo pipefail
              DS=/usr/share/xml/scap/ssg/content/ssg-rhel9-ds.xml
              if [ ! -f "$DS" ]; then
                echo "Expected datastream $DS not found" >&2
                exit 1
              fi
              echo "$DS" > /tmp/datastream_path

      - name: RemediateCisProfile
        action: ExecuteBash
        onFailure: Abort
        timeoutSeconds: 3600
        inputs:
          commands:
            - |
              set -uo pipefail
              DS=$(cat /tmp/datastream_path)
              mkdir -p /var/log/cis-hardening
              oscap xccdf eval \
                --profile xccdf_org.ssgproject.content_profile_cis \
                --remediate \
                --results /var/log/cis-hardening/build-results.xml \
                --report /var/log/cis-hardening/build-report.html \
                "$DS"
              rc=$?
              # oscap exit codes: 0 = all rules pass, 2 = some rules failed
              # (expected — e.g. physical-security/org-policy rules that can't be
              # automated), 1 = a real tool/config error. Only 1 aborts the build.
              if [ "$rc" -eq 1 ]; then
                echo "oscap reported a tool error (exit 1) during remediation" >&2
                exit 1
              fi
              echo "oscap remediation exit code: $rc (0=pass, 2=some rules failed as expected)"
              exit 0

      - name: UploadBuildReport
        action: ExecuteBash
        onFailure: Continue
        inputs:
          commands:
            - |
              aws s3 cp /var/log/cis-hardening/build-report.html \
                s3://${logs_bucket}/rhel9/build-report-$(date -u +%Y%m%dT%H%M%SZ).html || true

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
              oscap xccdf eval \
                --profile xccdf_org.ssgproject.content_profile_cis \
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
                s3://${logs_bucket}/rhel9/validate-report-$(date -u +%Y%m%dT%H%M%SZ).html || true
