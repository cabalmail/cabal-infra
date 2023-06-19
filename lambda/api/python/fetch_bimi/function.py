'''Checks for the presence of a BIMI record and returns the image URL if found'''
import json
import dns.resolver
def handler(event, _context):
    '''Checks for the presence of a BIMI record and returns the image URL if found'''
    qs = event['queryStringParameters']
    sender_domain = qs['sender_domain']
    sender_domain_parts = sender_domain.split(".")
    for x in range(len(sender_domain_parts)):
        domain = ".".join(sender_domain_parts[x:])
        print(domain)
        try:
            answer = dns.resolver.query(f'default._bimi.{domain}', 'TXT')
            return {
                "statusCode": 200,
                "body": json.dumps({
                    "url": answer[0].__str__().split(";")[1].split("=")[1]
                })
            }
        except dns.resolver.NXDOMAIN:
            pass
        except dns.resolver.NoAnswer:
            pass

    return {
        "statusCode": 200,
        "body": json.dumps({
            "url": "/mask.png"
        })
    }
