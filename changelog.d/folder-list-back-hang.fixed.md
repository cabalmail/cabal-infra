- Apple: **Going back to the folder list no longer freezes the app.** On
  iPhone, tapping back from a folder's messages to a Folders list too short
  to fill the screen could hang the app until iOS killed it. The extra room
  the list keeps below its rows so a push can tuck the filter field away was
  recomputed from scroll measurements one step out of date, and under the
  back navigation it chased itself forever; it is now worked out once the
  list's layout has settled.
