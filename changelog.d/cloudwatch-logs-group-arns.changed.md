- **API Gateway's logging role grants log-group actions on log-group
  ARNs.** CloudWatch Logs stops honouring a log-stream ARN for log-group
  actions on 2027-04-26, and `cabal_cloudwatch_role` granted
  `CreateLogGroup`, `DescribeLogStreams` and `FilterLogEvents` only through
  `log-group:*:*`. Its policy is now two statements: those actions on
  `log-group:*`, and the stream actions (`CreateLogStream`,
  `PutLogEvents`, `GetLogEvents`) on the stream ARN as before. A scan of
  every IAM policy in the stage and prod accounts found no other statement
  the change affects.
