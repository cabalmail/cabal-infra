# Admin Dashboard Plan

## Context

User management currently happens in the AWS Cognito console. When confirming users, the admin has no visibility into whether ECS refresh succeeded (now addressed by the earlier fix to surface errors). A dashboard tab in the React app would centralize user management with proper feedback, and serve as a foundation for a more comprehensive admin workflow.

## Approach

Four phases of work: core admin dashboard (Terraform, Lambda, React), phone number verification via SMS, DMARC report ingestion and display, and multi-user address management.

---

## Phase 1: Core Admin Dashboard

### 1. Terraform — Cognito Admin Group (Issue #54)

**`terraform/infra/modules/user_pool/main.tf`** — Add `aws_cognito_user_pool_group "admin"` resource.

**`terraform/infra/modules/user_pool/outputs.tf`** — Add output for `admin_group_name`.

**`terraform/infra/modules/app/master_user.tf`** — Add `aws_cognito_user_in_group "master_admin"` to place master user in admin group.

**`terraform/infra/modules/app/variables.tf`** — Add `admin_group_name` variable.

**`terraform/infra/main.tf`** — Pass `admin_group_name = module.pool.admin_group_name` to the admin module.

When a user belongs to a Cognito group, the `cognito:groups` claim is automatically included in the JWT, enabling both frontend (show/hide tab) and backend (authorization check) admin detection.

### 2. Terraform — Lambda Infrastructure

**`terraform/infra/modules/app/locals.tf`** — Add 5 entries to `supported_lambdas`:
- `list_users` (GET), `confirm_user` (PUT), `disable_user` (PUT), `enable_user` (PUT), `delete_user` (DELETE)
- All: `python3.13`, `memory = 128`, `cache = false`, `cache_ttl = 0`
- Including `enable_user` so disable is reversible

**`terraform/infra/modules/app/modules/call/lambda.tf`** — Two changes:
- Add Cognito IAM permissions (`cognito-idp:ListUsers`, `AdminConfirmSignUp`, `AdminDisableUser`, `AdminEnableUser`, `AdminDeleteUser`) to the shared policy. All functions already run behind Cognito auth, so the blast radius is already scoped. Admin Lambdas enforce group membership in code.
- Add `USER_POOL_ID` env var to the Lambda function environment block.

**`terraform/infra/modules/app/modules/call/variables.tf`** — Add `user_pool_id` variable.

**`terraform/infra/modules/app/main.tf`** — Pass `user_pool_id = var.user_pool_id` to `module "cabal_method"`.

### 3. Lambda Functions (5 new, under `lambda/api/`) (Issue #55)

Each function: `function.py` + empty `requirements.txt` (build script auto-discovers directories).

All share this authorization pattern:
```python
groups = event['requestContext']['authorizer']['claims'].get('cognito:groups', '')
if 'admin' not in groups:
    return {'statusCode': 403, 'body': json.dumps({'Error': 'Admin access required'})}
```

- **`list_users/`** — `cognito.list_users()` with pagination, returns formatted user list (username, status, enabled, created, osid)
- **`confirm_user/`** — `cognito.admin_confirm_sign_up()`. The existing `post_confirmation` trigger (`assign_osid`) fires automatically, handling OSID assignment and ECS refresh. Errors propagate back (per our earlier fix).
- **`disable_user/`** — `cognito.admin_disable_user()`
- **`enable_user/`** — `cognito.admin_enable_user()`
- **`delete_user/`** — `cognito.admin_delete_user()`, with a guard against self-deletion

### 4. React — ApiClient

**`react/admin/src/ApiClient.js`** — Add 5 methods: `listUsers()`, `confirmUser(username)`, `disableUser(username)`, `enableUser(username)`, `deleteUser(username)`. Follow existing axios patterns.

### 5. React — App Integration

**`react/admin/src/App.jsx`**:
- In `doLogin` success callback: decode JWT payload via `atob(token.split('.')[1])`, extract `cognito:groups`, set `isAdmin` state
- Reset `isAdmin` to `false` in `doLogout`
- Pass `isAdmin` to `Nav`
- Add `"Users"` case to `renderContent()`, rendering new lazy-loaded `Users` component
- Add `"DMARC"` case to `renderContent()`, rendering new lazy-loaded `Dmarc` component
- Add lazy imports for `Users` and `Dmarc` components

### 6. React — Nav

**`react/admin/src/Nav/index.jsx`** — Destructure `isAdmin` from props, add conditional class `is-admin` to nav div, add Users link with id `users` and DMARC link with id `dmarc`.

**`react/admin/src/Nav/Nav.css`** — Add rules to hide `#users` and `#dmarc` when logged out or when nav lacks `.is-admin`.

### 7. React — Users Component (new)

**`react/admin/src/Users/index.jsx`** — Functional component using hooks, following existing patterns:
- `useApi()` hook for API access, `useAppMessage()` for toast notifications
- State via `useState`: `users`, `loading`
- `loadUsers()` calls `api.listUsers()`, populates state
- Action handlers wrapped in `useCallback`: `confirmUser`, `disableUser`, `enableUser`, `deleteUser` — each calls API, shows message via `setMessage`, reloads user list
- Two sections — "Pending Users" (status !== CONFIRMED) with confirm/delete buttons, "Confirmed Users" with disable-or-enable/delete buttons. Refresh button at top.

**`react/admin/src/Users/Users.css`** — Grid layout for user rows, following Addresses CSS patterns.

### Phase 1 Verification

1. `cd react/admin && npm run build` — confirm React compiles without errors
2. `cd lambda/api && pylint --rcfile .pylintrc list_users/function.py confirm_user/function.py disable_user/function.py enable_user/function.py delete_user/function.py` — lint new Lambdas
3. Manual: log in as master user, verify Users tab appears; log in as non-admin, verify it does not
4. `cd react/admin && npm run test` — verify new component tests pass

---

## Phase 2: Phone Number Verification via SMS (Issue #55)

Add SMS-based phone number verification to the sign-up flow so that collected phone numbers are validated.

**`terraform/infra/modules/user_pool/main.tf`** — Configure the Cognito user pool for SMS verification:
- Set `auto_verified_attributes` to include `phone_number`
- Configure `sms_configuration` with an IAM role that grants `sns:Publish` permission
- Set `sms_verification_message` with a verification code template

**`terraform/infra/modules/user_pool/sns.tf`** (new) — Create:
- IAM role for Cognito to publish to SNS
- IAM policy granting `sns:Publish`
- Trust policy allowing `cognito-idp.amazonaws.com` to assume the role

Cognito handles the verification flow automatically: after sign-up, it sends an SMS with a verification code, and the user confirms via `ConfirmSignUp` or `VerifyUserAttribute`. The React sign-up flow should prompt the user to enter the code they receive.

**`react/admin/src/SignUp/index.jsx`** — Update the registration flow to include a phone verification step after initial sign-up, prompting the user to enter the SMS code.

### Phase 2 Verification

1. Manual: sign up a new user with a phone number, verify SMS verification code is sent and can be confirmed

---

## Phase 3: DMARC Report Ingestion and Display (Issue #103)

Automatically ingest DMARC aggregate reports (currently landing in the admin's inbox as zipped/gzipped XML attachments) into a database and present them in the admin interface.

### 3a. Report Ingestion Pipeline

**SES Receipt Rule** — Route incoming DMARC report emails (sent to the `rua` address on the control domain) to an S3 bucket instead of (or in addition to) the admin's inbox.

**`lambda/api/process_dmarc/`** (new) — Lambda triggered by S3 `ObjectCreated` events on the DMARC report bucket:
- Extract the MIME attachment (zip or gzip)
- Decompress and parse the XML (schema: RFC 7489 `feedback` element)
- Extract key fields: reporting org, date range, source IP, count, disposition, DKIM result, SPF result, domain, header-from
- Write parsed records to DynamoDB

**`terraform/infra/modules/app/dmarc.tf`** (new) — Infrastructure for the ingestion pipeline:
- S3 bucket for incoming DMARC report emails
- SES receipt rule to deliver to the bucket
- Lambda function with S3 trigger
- DynamoDB table (`dmarc_reports`) with partition key `domain#date_range_end` and sort key `source_ip#report_id` for efficient reverse-chronological queries
- IAM permissions for the Lambda (S3 read, DynamoDB write)

### 3b. API Endpoint

**`lambda/api/list_dmarc_reports/`** (new) — Admin-only Lambda (same auth pattern as user management endpoints):
- Query DynamoDB, return results in reverse chronological order
- Support pagination via `LastEvaluatedKey`
- Return: reporting org, date range, source IP, message count, disposition, DKIM alignment, SPF alignment, domain

**`terraform/infra/modules/app/locals.tf`** — Add `list_dmarc_reports` (GET) to `supported_lambdas`.

**`react/admin/src/ApiClient.js`** — Add `listDmarcReports(paginationToken)` method.

### 3c. React — DMARC Component (new)

**`react/admin/src/Dmarc/index.jsx`** — Functional component using hooks:
- `useApi()` hook for API access, `useAppMessage()` for toast notifications
- State via `useState`: `reports`, `loading`, `nextToken`
- `loadReports()` calls `api.listDmarcReports()`, populates state
- Tabular display in reverse chronological order showing: date, reporting org, source IP, message count, DKIM result, SPF result, disposition
- Color-coded pass/fail indicators for DKIM and SPF columns
- "Load more" button for pagination
- Refresh button at top

**`react/admin/src/Dmarc/Dmarc.css`** — Table layout for report rows.

### Phase 3 Verification

1. `cd lambda/api && pylint --rcfile .pylintrc process_dmarc/function.py list_dmarc_reports/function.py` — lint new Lambdas
2. Manual: log in as master user, verify DMARC tab appears; log in as non-admin, verify it does not
3. Manual: send a test email to trigger a DMARC report, verify it appears in the DMARC tab after ingestion

---

## Phase 4: Multi-User Address Management

The Docker infrastructure already supports delivering mail to multiple users per address. In `docker/shared/generate-config.sh`, the `user` field from the `cabal-addresses` DynamoDB table is split on `/` — a value like `user1/user2` produces a virtusertable alias (`user1_user2`) that expands via `/etc/aliases.dynamic` to deliver to both users. This phase exposes that latent feature through the API and admin UI, restricted to admin users only.

### 4a. Lambda — Address Assignment Endpoints

**`lambda/api/assign_address/`** (new) — Admin-only Lambda that adds a user to an existing address:
- Reads the current `user` field from DynamoDB for the given address
- Appends the new username (slash-separated): e.g., `user1` becomes `user1/user2`
- Validates that the target user exists in Cognito before writing
- Writes the updated value back to DynamoDB
- Publishes an SNS message to trigger container reconfiguration (same pattern as `new` and `revoke`)

**`lambda/api/unassign_address/`** (new) — Admin-only Lambda that removes a user from a multi-user address:
- Reads the current `user` field, removes the specified username from the slash-separated list
- If only one user remains, writes back the single username (no slash)
- Guards against removing the last user — use `revoke` to delete the address entirely
- Publishes SNS reconfiguration message

**`lambda/api/new/function.py`** — No changes needed. The existing `new` endpoint creates addresses with a single user. Multi-user assignment is admin-only and handled by `assign_address`.

However, a new admin-only variant is needed:

**`lambda/api/new_address_admin/`** (new) — Admin-only Lambda that creates an address with one or more users:
- Accepts a list of usernames instead of deriving user from the JWT
- Validates all target users exist in Cognito
- Writes the address to DynamoDB with a slash-separated `user` field if multiple users are specified
- Publishes SNS reconfiguration message
- This is distinct from the existing `new` endpoint, which is self-service (users create addresses for themselves)

### 4b. Terraform — Lambda Infrastructure for Address Assignment

**`terraform/infra/modules/app/locals.tf`** — Add 3 entries to `supported_lambdas`:
- `assign_address` (PUT), `unassign_address` (PUT), `new_address_admin` (POST)
- All: `python3.13`, `memory = 128`, `cache = false`, `cache_ttl = 0`

### 4c. React — ApiClient

**`react/admin/src/ApiClient.js`** — Add 3 methods:
- `assignAddress(address, username)` — add a user to an existing address
- `unassignAddress(address, username)` — remove a user from an address
- `newAddressAdmin(address, usernames)` — create an address assigned to one or more users

### 4d. React — Users Component Updates

**`react/admin/src/Users/index.jsx`** — Extend the confirmed users section:
- Each user row shows their assigned addresses (fetched via existing `list` endpoint filtered by user, or a new admin endpoint)
- "Assign Address" action on each user: opens a picker/autocomplete showing existing addresses, with an option to assign the user to the selected address
- "Create Address" action: form to create a new address assigned to the selected user(s)

### 4e. React — Addresses Admin View

**`react/admin/src/Addresses/Admin.jsx`** (new) — Admin-only view of all addresses across all users:
- Displays each address with its assigned user(s)
- For multi-user addresses, shows all assigned users with individual "Remove" buttons (calls `unassignAddress`)
- "Add User" button on each address row: opens a user picker to assign an additional user (calls `assignAddress`)
- "New Address" button: form that accepts the address fields plus one or more usernames (calls `newAddressAdmin`)
- Accessible from the Users tab or as a sub-view within the admin interface

### Phase 4 Verification

1. `cd lambda/api && pylint --rcfile .pylintrc assign_address/function.py unassign_address/function.py new_address_admin/function.py` — lint new Lambdas
2. Manual: as admin, assign a second user to an existing address; verify both users receive mail sent to that address
3. Manual: as admin, create a new address with two users assigned; verify delivery to both
4. Manual: as admin, remove one user from a multi-user address; verify only the remaining user receives mail
5. Manual: verify non-admin users cannot access the assign/unassign/new_address_admin endpoints
