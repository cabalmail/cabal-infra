# Registrar-specific Instructions

The output of [terraform/dns](../terraform/dns) contains nameservers that you must add to your domain registration. To update the nameservers for a domain registration, follow the instructions at your registrar. The procedure will be different for each registrar. Here's a partial list:

* [Arvixe](https://blog.arvixe.com/modifying-a-domains-name-servers/)
* [AWS Route53 Registrar](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/domain-name-servers-glue-records.html#domain-name-servers-glue-records-adding-changing)
* [Bluehost](https://www.bluehost.com/help/article/use-custom-name-servers)
* [Domain.com](https://www.domain.com/help/article/domain-management-how-to-update-nameservers)
* [eNom](https://cp.enom.com/kb/kb/kb_0086_how-to-change-dns.htm)
* [Gandi](https://docs.gandi.net/en/domain_names/common_operations/changing_nameservers.html)
* [GoDaddy](https://www.godaddy.com/help/change-nameservers-for-my-domains-664)
* [Google](https://support.google.com/domains/answer/3290309?hl=en)
* [HostGator](https://www.hostgator.com/help/article/changing-name-servers-with-launchpad)
* [Hostinger](https://www.hostinger.com/tutorials/how-to-change-domain-nameservers)
* [Inmotion Hosting](https://www.inmotionhosting.com/support/domain-names/change-domain-nameservers-amp/)
* [Ionos](https://www.ionos.com/help/domains/using-your-own-name-servers/add-change-or-delete-an-ns-record-for-a-subdomain/)
* [Just Host](https://my.justhost.com/cgi/help/222)
* [Media Temple](https://mediatemple.net/community/products/dv/204643220/how-do-i-edit-my-domain%27s-nameservers)
* [Name.com](https://www.name.com/support/articles/205934547-Changing-nameservers-for-DNS-management)
* [Namecheap](https://www.namecheap.com/support/knowledgebase/article.aspx/767/10/how-to-change-dns-for-a-domain/)
* [Network Solutions](https://customerservice.networksolutions.com/prweb/PRAuth/webkm/help/article/KC-454/networksolutions)

It can take up to a day for your changes to become active, though experience suggests that it often is complete after only a few minutes. You can check whether your changes have been implemented by looking up your domain in [the whois database](https://lookup.icann.org/).

## If DNSSEC is enabled: the registration also carries a DS record

When [DNSSEC](./dnssec.md) is enabled for a domain, its registration holds a second piece of state besides the nameservers: the DS record (or, at registrars like Route 53 Registered Domains, the public key the registry derives the DS from). The two must stay consistent. In particular, **never point a registration that still carries a DS record at a zone that does not serve signed responses** - for example, a freshly re-created zone after an environment teardown and re-bootstrap. Validating resolvers will SERVFAIL the domain until the DS is removed and caches expire. Before re-delegating nameservers to a new zone, or tearing an environment down, run the DNSSEC disable procedure in [docs/dnssec.md](./dnssec.md) first: remove the DS at the registrar, wait out the caches, then stop signing.

Note also that the registrar console may live in a different AWS account than the environment whose zones it delegates to; the nameservers and DS values transfer by copy-paste either way.