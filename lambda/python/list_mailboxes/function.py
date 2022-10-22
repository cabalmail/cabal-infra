from imapclient import IMAPClient
import json
import logging

logger = logging.getLogger()
logger.setLevel(logging.INFO)

client = IMAPClient(host="imap.${control_domain}", use_uid=True, ssl=True)

def handler(event, context):
  logger.info(json.dumps(event))
  logger.info(event['user'])
  client.login(event['user'], event['password'])
  response = client.list_folders()
  client.logout()
  logger.info(response)
  return response