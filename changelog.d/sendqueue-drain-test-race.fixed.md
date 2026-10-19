- **Flaky outbox drain test.** `testAMessageEnqueuedDuringADrainIsSentByTheSameDrain`
  asserted the outbox was empty as soon as the second message's send had
  started, but the drain removes an entry only once its send returns, so a
  slow simulator could catch it in between; the visionOS leg of a stage
  run did. It now waits for the outbox to empty, and still fails if the
  mid-drain kick is dropped.
