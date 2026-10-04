- Apple: **The message list and reader stop writing diagnostic logs.**
  Both wrote a line to the system log at each step of loading a page of
  mail or opening a message, where a sysdiagnose could pick it up. The
  logging was left over from bugs that have since been fixed, and it is
  now taken out.
