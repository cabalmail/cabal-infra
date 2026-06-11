- The destroy workflow strips `lifecycle.prevent_destroy` from its
  working copy before running, since the guard (on the ECR repos since
  0.9.5) is a plan-time hard error that blocked the entire teardown.
  Image history is still preserved: `force_delete = false` makes the
  ECR API refuse to delete repositories that contain images, so they
  survive the teardown in AWS and in state, as before.
