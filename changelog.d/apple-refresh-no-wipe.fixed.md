- The Apple message list no longer collapses a scrolled, deeply-paginated
  folder back to the top page on a routine background refresh. A top-page
  refresh now reconciles deletions only while the list still fits in one page;
  once the user has scrolled past the first page it folds in new mail without
  pruning the loaded tail. The previous design bounded that prune by a UID
  band, which broke for the default arrival sort (the server pages by
  INTERNALDATE while the client orders by the Date header, so the band spanned
  most of the folder and flagged the paginated tail as expunged). A flaky
  folder STATUS (missing or zero UIDVALIDITY) and an empty top-page fetch are
  likewise no longer read as a mailbox rebuild or a mass expunge.
