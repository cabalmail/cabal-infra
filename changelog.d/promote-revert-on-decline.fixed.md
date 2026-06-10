- `make promote` now reverts its changes when you decline the confirmation
  prompt. Answering `n` previously left the collated `CHANGELOG.md` edit and the
  deleted fragments staged in the working tree; it now restores both so a
  declined release leaves the tree exactly as it was before.
