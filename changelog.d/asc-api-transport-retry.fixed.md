- **A timed-out App Store Connect request no longer fails a TestFlight
  upload job.** The retry added in 1.11.0 covered refusals Apple actually
  answered; a request that never reached a status code — a connect
  timeout, a read timeout, a DNS failure, a reset connection — still
  failed the job on its first attempt, twice on the same day. Those now
  retry on the same terms as a transient 5xx, with the same bound and the
  same rule about which calls a repeat is safe for.
