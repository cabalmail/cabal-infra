'''Checks for the presence of a BIMI record and returns the image URL if found'''
import json
import dns.resolver # pylint: disable=import-error
def handler(event, _context):
    '''Checks for the presence of a BIMI record and returns the image URL if found'''
    query_string = event['queryStringParameters']
    sender_domain = query_string['sender_domain']
    sender_domain_parts = sender_domain.split(".")
    length = len(sender_domain_parts)
    for part in range(length):
        domain = ".".join(sender_domain_parts[part:])
        print(domain)
        try:
            answer = dns.resolver.query(f'default._bimi.{domain}', 'TXT')
            return {
                "statusCode": 200,
                "body": json.dumps({
                    "url": str(answer[0]).split(";")[1].split("=")[1]
                })
            }
        except dns.resolver.NXDOMAIN:
            pass
        except dns.resolver.NoAnswer:
            pass

    return {
        "statusCode": 200,
        "body": json.dumps({
            "url": f'https://www.{".".join(sender_domain_parts[length-2:])}/favicon.ico'
        })
    }

