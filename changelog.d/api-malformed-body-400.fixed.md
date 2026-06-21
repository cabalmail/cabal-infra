- Every `lambda/api/` handler that reads a JSON request body now returns
  400 instead of a 500/502 with a Python traceback when the body is
  missing, malformed, or not a JSON object. A shared `parse_json_body`
  helper backs the IMAP- and DNS-touching handlers (`new`, `revoke`,
  `send`, `save_draft`, `new_address_admin`, and the folder/subscription
  endpoints); the admin user-management and address-mutation handlers,
  which deliberately avoid importing `helper.py`, apply the same guard
  inline.
