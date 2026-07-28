- **Untracked committed `__pycache__/*.pyc` bytecode files.** Two stale
  handler artifacts (`lambda/api/delete_folder/` and
  `lambda/api/new_folder/`) were on `stage`; `.gitignore` now covers
  `__pycache__/` repo-wide so locally exercising a handler with
  `python -m function` cannot re-add them.
