- **Folder-subscription endpoints share one request path.** `subscribe_folder`
  and `unsubscribe_folder` were line-for-line twins apart from the helper each
  called; both now hand the body parse, the folder validation and the `200` to
  `helper.folder_subscription_response`, passing the subscribe or unsubscribe
  operation, so the two endpoints cannot drift apart.
