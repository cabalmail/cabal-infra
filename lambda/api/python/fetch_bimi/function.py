'''Checks for the presence of a BIMI record and returns the image URL if found'''
import json
import dnspython as dns
import dns.resolver

# https://d3frv9g52qce38.cloudfront.net/amazondefault/order_329474121_logo.svg
# "v=BIMI1;l=https://d3frv9g52qce38.cloudfront.net/amazondefault/order_329474121_logo.svg;a=https://d3frv9g52qce38.cloudfront.net/amazondefault/amazon_web_services_inc.pem"
# default._bimi.[domain]
def handler(event, _context):
    '''Preps an attachment for download from S3 given a folder, message ID, and attachment serial number'''
    qs = event['queryStringParameters']
    sender_domain = qs['sender_domain']
    result = dns.resolver.query(sender_domain, 'TXT').response.answer[0][-1].strings[0]
    return {
        "statusCode": 200,
        "body": json.dumps({
            "url": result
        })
    }
