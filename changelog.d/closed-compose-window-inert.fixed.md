- Apple: **A closed compose window can't come back with its draft.**
  On iPhone Duo the system keeps listing a compose window in its window
  switcher after Send or Discard closes it, and picking it there brought
  back a live composer holding the sent or discarded draft, Send
  included (#2257). Now a closed window that has left the screen holds
  nothing, and one picked from the switcher steps straight back out to
  the mail window. The switcher still lists it until it is swiped away,
  since iOS won't let an app close a window for good on a phone. iPad
  keeps closed compose windows the same way and should behave alike;
  that is not yet checked.
