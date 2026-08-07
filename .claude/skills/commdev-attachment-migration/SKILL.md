---
name: commdev-attachment-migration
description: Provision a CommDev attachment-migration S3 bucket + IAM user + IAM policy for a client via CloudFormation, then tag the policy. Use when a client needs to rclone-upload CommDev attachments (e.g. "/commdev-attachment-migration us-west-2 gre").
---

# /commdev-attachment-migration — Provision CommDev attachment transfer bucket

Parse the user's input for a region and a client code, then run the provisioning script.

## Parsing

- **Region**: must be `us-east-1` or `us-west-2`. Ask if missing or ambiguous — do not guess.
- **Client code**: any case is fine (e.g. `gre` or `GRE`) — the script normalizes it (lowercase for the CloudFormation parameter and tags, uppercase for the stack name). Ask if missing.

## Action

```
pwsh scripts/commdev-attachment/New-CommDevAttachmentBucket.ps1 -Region <REGION> -ClientCode <CODE>
```

This targets the **legacy-Shared-Services** account (343823317319) only — there is no account argument, since this process has exactly one destination account.

The script:
1. Refuses to run if a stack already exists for that client code (reports its status instead of creating a duplicate).
2. Creates the CloudFormation stack `<CODE-UPPER>-CommDev-Attachment-Migration` from the account's existing template, which provisions an S3 bucket, an IAM user (`xfer-<code>`), and an IAM policy scoped to that bucket.
3. Polls until `CREATE_COMPLETE` (or reports the failure reason from stack events).
4. Tags the IAM policy directly via `aws iam tag-policy` — CloudFormation cannot tag `AWS::IAM::ManagedPolicy` resources, so this step is required, not optional.

## Reporting

Relay the script's final summary verbatim: bucket name, IAM user name, and policy ARN. **Always include the script's manual-next-step reminder** — creating the IAM access key and storing it in NPM is intentionally not automated (the secret is only shown once in the console and shouldn't be captured by unattended automation). Do not let the response imply the task is fully done until that step is called out.

## Examples

- "/commdev-attachment-migration us-west-2 gre" → provisions for Greeley, CO in us-west-2
- "set up a commdev attachment bucket for saratoga in us-east-1" → `-Region us-east-1 -ClientCode sara` (confirm the exact client code with the user if not stated explicitly)

## Notes

- If the stack fails, the script prints the failed resource(s) and reason from CloudFormation stack events — investigate before retrying, don't just re-run blindly.
- SSO session `legacy` auto-refreshes if expired, per team standard — no manual login needed.
