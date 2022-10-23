from imapclient import IMAPClient
import json
import logging

logger = logging.getLogger()
logger.setLevel(logging.INFO)

def handler(event, context):
  client = IMAPClient(host="imap.${control_domain}", use_uid=True, ssl=True)
  logger.info(event['body'])
  body = json.loads(event['body'])
  client.login(body['user'], body['password'])
  response = client.list_folders()
  client.logout()
  logger.info(response)
  return {
    "statusCode": 200,
    "body": response
  }