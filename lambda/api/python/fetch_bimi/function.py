'''Checks for the presence of a BIMI record and returns the image URL if found'''
import json
import dns.resolver
def handler(event, _context):
    '''Checks for the presence of a BIMI record and returns the image URL if found'''
    qs = event['queryStringParameters']
    sender_domain = qs['sender_domain']
    answer = dns.resolver.query(f'default._bimi.{sender_domain}', 'TXT')

    return {
        "statusCode": 200,
        "body": json.dumps({
            "url": answer[0].__str__().split(";")[1].split("=")[1]
        })
    }
    