'''Marks the specified folder as subscribed'''
from helper import subscribe_folder # pylint: disable=import-error
from helper import folder_subscription_response # pylint: disable=import-error

from helper import maintenance_guard # pylint: disable=import-error


@maintenance_guard
def handler(event, _context):
    '''Marks the specified folder as subscribed'''
    return folder_subscription_response(event, subscribe_folder)
