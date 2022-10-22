from imapclient import IMAPClient

logger = logging.getLogger()
logger.setLevel(logging.INFO)

client = IMAPClient(host="imap.${control_domain}", use_uid=True, ssl=True)

def handler(event, context):
  client.login(event['user'], event['password'])
  response = client.list_folders()
  client.logout()
  return response