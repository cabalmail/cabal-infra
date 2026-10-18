- Apple: **A sign-in reply the network answered for.** A 2xx from Cognito
  whose body isn't JSON — an empty body, or a hotel or café sign-in page
  answering for it — threw Foundation's error out of the Kit, so it showed
  as "The data couldn't be read because it isn't in the correct format."
  and a cold launch dropped to the sign-in form even though the session on
  disk was fine. It now reads as "Couldn't read the server's reply." and,
  like a refresh that never reached Cognito, leaves the stored session
  alone for the first call made back on a real network.
