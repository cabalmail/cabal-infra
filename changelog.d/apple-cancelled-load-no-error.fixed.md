- Apple: **A screen that leaves mid-load no longer keeps a "cancelled"
  error.** When the folder sidebar, the Feeds sidebar or a feed's list went
  off screen while it was loading (on iPhone, the launch opens the inbox
  over the folder sidebar at once), the load's cancellation showed as
  "Couldn't reach the server. cancelled.", and the sidebars kept it until a
  manual refresh. Such a load now shows nothing, and the sidebar loads
  again the next time it appears. The message source and Move to Folder
  sheets and the notification folder picker do the same.
