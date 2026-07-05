- Inbound SMTP connections now reach smtp-in with the real client
  address (NLB client IP preservation on the relay target group). SPF
  had been evaluated against the load balancer's own ENI and failed for
  every external sender; sendmail's connection-rate throttle and access
  map likewise treated all inbound mail as one client.
