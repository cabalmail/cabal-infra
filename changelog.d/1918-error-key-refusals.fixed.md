- Apple: **A refused request says what the server said.** Most of the mail
  API refuses a request as `{"Error": "<sentence>"}`, and the clients read
  only the `status` and `message` keys — so a reserved subdomain, an
  unknown domain, an empty local part or revoking someone else's address
  all read "The server couldn't complete that request (400)." instead of
  the reason. The sentence under that key is used now for a 4xx; a 500
  stays generic, since four handlers put raw exception text there.
