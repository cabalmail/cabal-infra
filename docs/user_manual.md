# Cabalmail App
The included serverless app can be used to create and revoke email addresses.

## Personas

[End User](#user)
: Creates and revokes email addresses for their own use

[Administrator](#admin)
: Approves or rejects requests to create new accounts

## Working with the App (End User)<a name="user"></a>
As an end user, you must first establish an account. Once approved, you can use the app to create and revoke addresses. All addresses that you create are aliased to a single inbox. You can reach the app at `https://admin.example.com/` (substituting your control domain for `example.com`).

### Creating an Account
1. Visit the login page at the admin URL.

2. Click the "Or request an account" link on the login page.

    <img src="./app_screens/1_login.png" alt="Login Page" width="400" />

3. Fill out the form. All fields are mandatory. When done, tap or click the "Request Account" button.

    <img src="./app_screens/0_signup.png" alt="Signup Page" width="400" />

4. Wait for an administrator to approve your account.

### Loging in
1. Visit the login page at the admin URL.

2. Enter your username and password.

    <img src="./app_screens/1_login.png" alt="Login Page" width="400" />

3. Tap or click the "Sign in" button.

### Requesting an Address
After logging in, the default screen is the request address form.

1. If you're not already on the request address form, tap the asterisk tab in the lower left (mobile) or click on the "New address" tab in the upper left (desktop).

    <img src="./app_screens/2_request_address.png" alt="Request Address Page" width="400" />

2. Fill out the form. Optionally, click the "Generate Random" button to quickly create a unique address suitable for online contact forms. All fields are mandatory. (For "Comment", we recommend that you record the name of the person or company to whom you intend to give the address. This will help locate it later, especially if you used the "Generate Random" button.) When done, tap or click on the "Request Address" button.

    <img src="./app_screens/3_request_address.png" alt="Request Address Page" width="400" />

    
3. After a moment, a popup will appear informing you that the address has been requested, and that it should be ready for use within five minutes. As a convenience, the app pushes the new address into your clipboard so that you can easily paste it.

    <img src="./app_screens/4_request_address.png" alt="Request Address Page" width="400" />

### Listing Your Addresses
A list of your addresses can be accessed by tapping the list tab in the lower center (mobile) or clicking on the "View addresses" tab in the upper left (desktop). At the top of this screen, you can filter by top level domain or other text.

<img src="./app_screens/5_list_addresses.png" alt="Address List Page" width="400" />

### Copying an Address
You can copy an address to your clipboard by tapping or clicking on it from the list screen.

<img src="./app_screens/6_copy_address.png" alt="Copying an Address" width="400" />

### Revoking an Address
1. Locate the offending address on the list screen, and tap the > icon (mobile) or click the "Details" link (desktop) associated with the address. This brings up a details screen.

    <img src="./app_screens/7_view_address_details.png" alt="Address List Page" width="400" />

2. On the details screen, verify that you have selected the correct address.

3. Tap or click the "Revoke" button.

    <img src="./app_screens/8_revoke_address.png" alt="Revoking an Address" width="400" />

### Log Out
When done, log out of the application by tapping the exit-door icon in the lower right (mobile) or clicking on the "Sign out" button in the upper right (desktop).

<img src="./app_screens/9_logout.png" alt="Logged Out" width="400" />

## Managing Accounts (Administrator)<a name="admin"></a>

Cabalmail does not create a custom user interface for administering end user accounts. Rather, this is done in the AWS Cognito console.

### Approving Account Requests
1. Log in to your AWS account using the IAM user that you created during [AWS setup step 2](./aws.md).
2. Make sure you are in the correct AWS region (as specified in your Terraform variables). Use the menu in the upper right of the AWS console if you need to change regions.
3. Navigate to [Cognito](https://console.aws.amazon.com/cognito/home).
4. Click the "Manage User Pools" button.
5. Click on the "cabal" user pool.
6. In the left navigation, click on "Users and groups" under the heading "General settings".
7. Click on the user name of the user who you want to approve.
8. Examine the user's details to verify that you selected the right one.
9. Click the "Enable user" button.

### Disabling an Account<a name="disable"></a>
1. Log in to your AWS account using the IAM user that you created during [AWS setup step 2](./aws.md).
2. Make sure you are in the correct AWS region (as specified in your Terraform variables). Use the menu in the upper right of the AWS console if you need to change regions.
3. Navigate to [Cognito](https://console.aws.amazon.com/cognito/home).
4. Click the "Manage User Pools" button.
5. Click on the "cabal" user pool.
6. In the left navigation, click on "Users and groups" under the heading "General settings".
7. Click on the user name of the user who you want to delete.
8. Examine the user's details to verify that you selected the right one.
9. Click the "Disable user" button.

### Deleting an Account
1. Follow the steps in [Disabling an Account](#disable).
2. Click the "Delete user" button.