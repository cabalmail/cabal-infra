import axios from 'axios';
import { ONE_SECOND } from './constants';

export default class ApiClient {

  constructor(baseURL, token, host) {
    this.baseURL = baseURL;
    this.token = token;
    this.host = host;
  }

  // Addresses
axios.post('/user', {
    firstName: 'Fred',
    lastName: 'Flintstone'
  })

  newAddress(username, subdomain, tld, comment, address) {
    localStorage.removeItem("address_list");
    const response = axios.post(
      '/new',
      {
        username: username,
        subdomain: subdomain,
        tld: domain,
        comment: comment,
        address: address
      },
      {
        baseURL: this.baseUrl,
        headers: {
          'Authorization': this.token
        },
        timeout: ONE_SECOND * 10
      }
    );
  }

  getAddresses() {
    if (localStorage.getItem("address_list") !== null) {
      return localStorage.getItem("address_list");
    }
    const response = axios.get('/list', {
      baseURL: this.baseURL,
      headers: {
        'Authorization': this.token
      },
      timeout: ONE_SECOND * 10
    });
  }

  deleteAddress(address, subdomain, tld, public_key) {
    localStorage.removeItem("address_list");
    const response = axios.delete('/revoke', {
      baseURL: this.baseURL,
      data: JSON.stringify({
        address: address,
        subdomain: subdomain,
        tld: tld,
        public_key: public_key
      }),
      headers: {
        'Authorization': this.token
      },
      timeout: ONE_SECOND * 10
    });
    return response;
  }

  // BIMI

  getBimiUrl(sender) {
    const sender_domain = sender.split("@")[1];
    const response = axios.get('/fetch_bimi', {
      params: {
        sender_domain: sender_domain
      },
      baseURL: this.baseURL,
      headers: {
        'Authorization': this.token
      },
      timeout: ONE_SECOND * 10
    });
    return response;
  }

  // IMAP Folders

  deleteFolder(name) {
    localStorage.removeItem("folder_list");
    const response = axios.delete('/delete_folder',
      {
        baseURL: this.baseURL,
        data: JSON.stringify({
          host: this.host,
          name: name
        }),
        headers: {
          'Authorization': this.token
        },
        timeout: ONE_SECOND * 10
      }
    );
    return response;
  }

  newFolder(parent, name) {
    localStorage.removeItem("folder_list");
    const response = axios.put('/new_folder',
      JSON.stringify({
        host: this.host,
        name: name,
        parent: parent
      }),
      {
        baseURL: this.baseURL,
        headers: {
          'Authorization': this.token
        },
        timeout: ONE_SECOND * 10
      }
    );
    return response;
  }

  getFolderList() {
    if (localStorage.getItem("folder_list") !== null) {
      return localStorage.getItem("folder_list");
    }
    const response = axios.get('/list_folders', {
      params: {
        host: this.host
      },
      baseURL: this.baseURL,
      headers: {
        'Authorization': this.token
      },
      timeout: ONE_SECOND * 10
    });
    return response;
  }

  // IMAP Messages

  moveMessages(source, destination, ids, order, field) {
    if (source == "INBOX" || destination == "INBOX") {
      localStorage.removeItem("INBOX");
    }
    const response = axios.put('/move_messages',
      JSON.stringify({
        host: this.host,
        source: source,
        destination: destination,
        ids: ids,
        sort_order: order,
        sort_field: field
      }),
      {
        baseURL: this.baseURL,
        headers: {
          'Authorization': this.token
        },
        timeout: ONE_SECOND * 10
      }
    );
    return response;
  } 

  setFlag(folder, flag, op, ids, order, field) {
    const response = axios.put('/set_flag',
      JSON.stringify({
        host: this.host,
        folder: folder,
        ids: ids,
        flag: flag,
        op: op,
        sort_order: order,
        sort_field: field
      }),
      {
        baseURL: this.baseURL,
        headers: {
          'Authorization': this.token
        },
        timeout: ONE_SECOND * 10
      }
    );
    return response;
  }

  getMessages(folder, order, field) {
    if (folder == "INBOX") {
      if (localStorage.getItem("INBOX") !== null) {
        return localStorage.getItem("INBOX");
      }
    }
    const response = axios.get('/list_messages',
      {
        params: {
          folder: folder,
          host: this.host,
          sort_order: order,
          sort_field: field
        },
        baseURL: this.baseURL,
        headers: {
          'Authorization': this.token
        },
        timeout: ONE_SECOND * 10
      }
    );
    return response;
  }

  getEnvelopes(folder, ids) {
    const response = axios.get('/list_envelopes',
      {
        params: {
          host: this.host,
          folder: folder,
          ids: `[${ids.join(",")}]`
        },
        baseURL: this.baseURL,
        headers: {
          'Authorization': this.token
        },
        timeout: ONE_SECOND * 10
      }
    );
    return response;
  }

  fetchImage(cid, folder, id, seen) {
    const response = axios.get('/fetch_inline_image',
      {
        params: {
          folder: folder,
          host: this.host,
          id: id,
          index: "<" + cid + ">",
          seen: seen
        },
        baseURL: this.baseURL,
        headers: {
          'Authorization': this.token
        },
        timeout: ONE_SECOND * 10
      }
    );
    return response;
  }

  getMessage(folder, id, seen) {
    const response = axios.get('/fetch_message',
      {
        params: {
          folder: folder,
          host: this.host,
          id: id,
          seen: seen
        },
        baseURL: this.baseURL,
        headers: {
          'Authorization': this.token
        },
        timeout: ONE_SECOND * 20
      }
    );
    return response;
  };
  
  getAttachment(a, folder, id, seen) {
    const response = axios.get('/fetch_attachment',
      {
        params: {
          folder: folder,
          host: this.host,
          id: id,
          index: a.id,
          filename: a.name,
          seen: seen
        },
        baseURL: this.baseURL,
        headers: {
          'Authorization': this.token
        },
        timeout: ONE_SECOND * 90
      }
    );
    return response;
  };
  
  getAttachments(folder, id, seen) {
    const response = axios.get('/list_attachments',
      {
        params: {
          folder: folder,
          host: this.host,
          id: id,
          seen: seen
        },
        baseURL: this.baseURL,
        headers: {
          'Authorization': this.token
        },
        timeout: ONE_SECOND * 20
      }
    );
    return response;
  };

}