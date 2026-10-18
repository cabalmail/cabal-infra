- **Concurrency warnings cleared in the Apple app targets.** The iOS build's
  last six — the intent that hops to the foreground to finish a clipboard
  copy, the Contacts privacy-settings opener, and the plain-text link
  detector's attribute writes — are gone, so an `iOS` build of the app is
  warning-free. No behaviour changes: the continuation still runs on the
  main actor, the settings pane still opens from the same affordance, and a
  detected link still carries its URL and underline.
