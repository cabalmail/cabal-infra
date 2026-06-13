- Every third-party GitHub Action in the CI workflows is now pinned to a
  full commit SHA with a trailing `# vX.Y.Z` comment, replacing the
  floating `@vN` tags a publisher could silently re-point. A new
  `github-actions` block in `.github/dependabot.yml` keeps those digests
  current (the Docker base-image digests were already on Dependabot), so
  the pins stay maintained without a separate Renovate app.
