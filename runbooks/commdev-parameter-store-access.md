# Accessing Parameter Store for Comm Dev

This guide walks you through accessing AWS Systems Manager Parameter Store for Comm Dev environments.

## Step 1: Sign into the AWS Access Portal

Navigate to the **New Foundation** AWS Access Portal:

**https://d-9067f93f22.awsapps.com/start/#/**

Sign in using your **cloud login** credentials.

---

## Forgot Your Cloud Login Password?

You can reset your AWS password using the self-service portal:

1. Go to: **https://accountportal.centralsquarecloud.com/authorization.do**
2. Select **Option 2**: "Forgot Password" or "ENROLL to Manage Credentials"
3. In the **Username** field, enter your **email address** (e.g. First.Last@centralsquare.com)
4. Leave the dropdown set to **"CentralSquare"**
5. Type the captcha and click **Continue**
6. Follow the on-screen steps to reset your password

Once your password has been reset, sign into AWS using the Foundations portal link above.

---

## Step 2: Select the Account

After signing in, you will see the available accounts. Choose the appropriate one:

| Account | Environment |
|---------|-------------|
| **PROD-PA-Pro** | Production |
| **Pa-pro-staging** | Staging |

Click on the account you need access to.

## Step 3: Select the Role

Click on the role: **cst-comm-readonlyaccess**

## Step 4: Change the Region

Once you are in the AWS Console, change the region to **US East (N. Virginia) us-east-1** using the region selector in the top-right corner of the screen.

## Step 5: Navigate to Parameter Store

1. In the AWS Console search bar at the top, type **Parameter Store**
2. Select **Parameter Store** under **AWS Systems Manager**

You will now have access to view the Comm Dev parameters for the selected environment.

## Step 6: Search for a Client's Parameters

To view all parameters for a specific client, search for:

```
/tenant/(CLIENTCODE)
```

For example, searching `/tenant/wind` will return all parameters for the "wind" client.
