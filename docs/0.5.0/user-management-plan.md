# Admin Dashboard Plan

## Context

User management currently happens in the AWS Cognito console. When confirming users, the admin has no visibility into whether ECS refresh succeeded (now addressed by the earlier fix to surface errors). A dashboard tab in the React app would centralize user management with proper feedback, and serve as a foundation for a more comprehensive admin workflow.

## Approach

Three layers of changes: Terraform (Cognito group + Lambda infra), Lambda functions (5 new admin endpoints), React (admin tab with user tables).

### 1. Terraform — Cognito Admin Group

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

### 3. Lambda Functions (5 new, under `lambda/api/`)

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

**`react/admin/src/App.js`**:
- Add `isAdmin: false` to initial state
- In `doLogin` success callback: decode JWT payload via `atob(token.split('.')[1])`, extract `cognito:groups`, set `isAdmin`
- Reset `isAdmin: false` in `doLogout`
- Pass `isAdmin` to `Nav`
- Add `"Users"` case to `renderContent()`, rendering new `Users` component
- Import `Users` component

### 6. React — Nav

**`react/admin/src/Nav/index.js`** — Destructure `isAdmin` from props, add conditional class `is-admin` to nav div, add Users link with id `users`.

**`react/admin/src/Nav/Nav.css`** — Add rules to hide `#users` when logged out or when nav lacks `.is-admin`.

### 7. React — Users Component (new)

**`react/admin/src/Users/index.js`** — Class-based component following Addresses/Folders pattern:
- State: `{ users: [], loading: true }`
- `loadUsers()` calls `api.listUsers()`, populates state
- Action handlers: `confirmUser`, `disableUser`, `enableUser`, `deleteUser` — each calls API, shows message via `setMessage`, reloads user list
- `render()`: Two sections — "Pending Users" (status !== CONFIRMED) with confirm/delete buttons, "Confirmed Users" with disable-or-enable/delete buttons. Refresh button at top.

**`react/admin/src/Users/Users.css`** — Grid layout for user rows, following Addresses CSS patterns.

## Verification

1. `cd react/admin && npm run build` — confirm React compiles without errors
2. `cd lambda/api && pylint --rcfile .pylintrc list_users/function.py confirm_user/function.py disable_user/function.py enable_user/function.py delete_user/function.py` — lint new Lambdas
3. Manual: log in as master user, verify Users tab appears; log in as non-admin, verify it does not
