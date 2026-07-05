- Tightened server-side validation on the address- and folder-management
  endpoints: address revocation now derives the DNS records to delete from the
  stored address row rather than client-supplied `subdomain`/`tld` (so a caller
  can no longer target another user's records); new addresses store a
  server-derived `address` key instead of a client-supplied one; the
  folder-management endpoints (`new_folder`, `delete_folder`,
  `subscribe_folder`, `unsubscribe_folder`, `folder_status`) now validate the
  folder name like the read paths already did; and the admin-group check is an
  exact membership test instead of a substring match.
