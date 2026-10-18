- Apple: **One offline cache file per folder.** The envelope and body caches
  named a folder's files by replacing `/` and `.` with `_`, so a nested
  folder and a flat sibling spelled the same way — `a/b` and `a_b` — shared
  one file: each folder's snapshot replaced the other's, leaving neither with
  a usable offline copy of itself. Names now carry a digest of the exact
  folder path, and the files written under the old names are dropped once, at
  open, since which folder they belong to is not knowable.
