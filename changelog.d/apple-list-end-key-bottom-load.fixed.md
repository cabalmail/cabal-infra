- Pressing End, or dragging the scrollbar, to the bottom of a large Apple
  folder now loads the bottom messages instead of leaving them as
  placeholders forever. The window reload asked for a full in-memory-cap
  (600-row) page, but the server clamps a page to 250 rows, and the reload
  still centred the window as though it had all 600 -- so the rows that came
  back landed hundreds of rows above the jump target, which was never
  covered (only a jump to the very top happened to work). The reload now
  fetches one server-sized page centred on the target, and the window grows
  from there as you scroll. End additionally drives that load explicitly for
  the real target and clamps to the last actual message, so a fast animated
  jump can't strand the bottom on placeholders.
