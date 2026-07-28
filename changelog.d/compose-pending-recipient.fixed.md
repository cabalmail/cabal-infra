- **First Send click with an uncommitted recipient in the React composer.**
  Typing an address and clicking Send without first pressing Enter was
  rejected with "Please specify at least one recipient." even though the
  address was visibly in the field, and an uncommitted second address was
  dropped from the message entirely. Send now folds the pending input text
  into the recipient lists before validating and sending, and commits it to
  the row it was typed in rather than always to To.
