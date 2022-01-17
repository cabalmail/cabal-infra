# About Cabalmail

Coming soon. The Cabalmail repository creates AWS infrastructure and machine configuration for a Cabalmail system — a system for hosting and managing your personal email by creating new addresses for each interlocutor.

WARNING: This should not be regarded as an enterprise or ISP-grade email solution. It has been tested on a small pool of users for their personal email. Use at your own risk!

Cabalmail is a suite of infrastructure code ([Terraform](https://www.terraform.io/)), configuration management code ([Chef Infra](https://www.chef.io/)), and application code ([React](https://reactjs.org/)) that together create the following system components:

* IMAP host
* SMTP relay host
* SMTP submission host
* Administrative interface for managing addresses
* Private cloud network
* DNS
* Other supporting infrastructure

Cabalmail allows you to host your email and to create multiple unique addresses that all point to the same inbox (one inbox per user, many addresses per inbox). This allows you to give distinct email address to all the people, institutions, corporations, etc., from whom you wish to receive email, allowing fine-grained control of who is authorized to insert messages into your inbox.

For the curious, here is [a brief history of Cabalmail](./genesis.md).

## Subdomains

What's special about Cabalmail is that it allows (OK: forces) you to create new subdomains for each address. If we assume your mail domain is example.com, then Cabalmail will *not* support addresses of the form foo@example.com. Rather, each address will be hosted at a subdomain of example.com, such as foo@bar.example.com.

By making it easy to create new addresses that point to a given inbox, Cabalmail makes it feasible to create new addresses for each person, company, etc., that needs to contact you. This approach is similar to the technique of ["plus-addressing" or "subaddressing"](https://tools.ietf.org/id/draft-newman-email-subaddr-01.html).

"So why not just use plus-addressing?" Good question. See the next section.

## Spam Handling

There isn't any. By not running Bayesian filters, machine learning algorithms, or other compute-intensive measures, you can operate your own email infrastructure with very small machines. Mine (which serves seven domains and four users) runs just fine on three t2.micros. My monthly AWS cost is less than $100. That's a lot of money in a world of free Gmail accounts, but if you value enhanced control and privacy, you may find it worthwhile. And bear in mind that you can spread the cost among several users.

"But what if I start to get spam?" That's the best part. Simply go to the admin interface and revoke the address. This process does more than simply remove the address from your aliases; it also revokes any related DNS records. Because each address has a unique subdomain, the spam-sending relays can't even find your SMTP servers, so there is no need for your machines to accept the connection, evaluate the reputation of the sender, match the To: header against a list of supported addresses, apply spam filters, etc.

Admitedly, Cabalmail serves a specialized use case, which is definitely not for everyone. To get the benefits of a Cabalmail system, you must get used to creating a new email address *each and every time you provide your contact information to a third party.* The administrative interface makes this easy, but it _is_ an additional step.

## Availability

The Cabalmail developement team is hard at work preparing our first release. Stay tuned.