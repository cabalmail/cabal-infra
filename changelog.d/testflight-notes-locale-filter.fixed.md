- Fixed the prod TestFlight "What to Test" step failing to write notes with
  `PARAMETER_ERROR.ILLEGAL` on `filter[locale]`. It now queries the top-level
  `betaBuildLocalizations` collection, which accepts the locale filter, instead
  of the build relationship endpoint, which does not.
