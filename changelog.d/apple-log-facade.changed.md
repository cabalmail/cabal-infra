- Apple: **Debug Log lines arrive in order, and reach Console.** Each line
  used to reach Settings → Debug Log a moment after it was written, so
  lines written close together could appear out of order. They now land
  in the order they were written, and the composer's errors, which went
  only to the system log, show there too. Every line also goes to the
  system log under the `com.cabalmail.Cabalmail` subsystem, with its text
  marked private, so Console shows it only while a debugger is attached
  or once private data is enabled for that subsystem.
