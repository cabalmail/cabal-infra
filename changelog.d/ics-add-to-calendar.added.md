- Apple: **Add calendar invites to Calendar.** Tapping an `.ics` attachment on
  iOS / visionOS now opens an event sheet showing the invite's details
  (time, location, organizer, recurrence) with an Add to Calendar button that
  launches the system event editor prefilled — previously the attachment
  preview was a dead end, since iOS gives third-party apps no share-sheet or
  Files route into Calendar. Multi-event files list every event; invites the
  parser can't read still fall back to the QuickLook preview. On macOS,
  opening an `.ics` attachment already triggers Calendar's own import prompt.
