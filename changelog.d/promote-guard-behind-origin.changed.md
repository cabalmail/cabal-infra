- `make promote` now refuses to cut a release when the local `stage` branch is
  behind `origin/stage`, so a stale checkout can no longer collate the changelog
  and open the stage->main PR against the wrong base. (The pre-existing guard
  that the release must be cut from `stage` is unchanged.)
