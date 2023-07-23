import axios from 'axios';
import { ONE_SECOND, ADDRESS_LIST, FOLDER_LIST } from './constants';
const TIMEOUT = ONE_SECOND * 10;

export default class ApiClient {

  constructor(baseURL, token, host) {
    this.baseURL = baseURL;
    this.token = token;
    this.host = host;
  }

  // Helper

  #createPromise(key) {
    let p = new Promise(function(resolve, reject) {
      let d = localStorage.getItem(key);
      if (d !== null) {
        resolve(JSON.parse(d));
      } else {
        reject("Storage error");
      }
    });
    return p;
  }

  // Addresses

  newAddress(username, subdomain, tld, comment, address) {
    localStorage.removeItem(ADDRESS_LIST);
    const response = axios.post(
      '/new',
      {
        username: username,
        subdomain: subdomain,
        tld: tld,
        comment: comment,
        address: address
      },
      {
        baseURL: this.baseURL,
        headers: {
          'Authorization': this.token
        },
        timeout: TIMEOUT
      }
    );
    return response;
  }

  getAddresses() {
    if (localStorage.getItem(ADDRESS_LIST) !== null) {
      return this.#createPromise(ADDRESS_LIST);
    }
    const response = axios.get('/list', {
      baseURL: this.baseURL,
      headers: {
        'Authorization': this.token
      },
      timeout: TIMEOUT
    });
    return response;
  }

  deleteAddress(address, subdomain, tld, public_key) {
    localStorage.removeItem(ADDRESS_LIST);
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
      timeout: TIMEOUT
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
      timeout: TIMEOUT
    });
    return response;
  }

  // IMAP Folders

  deleteFolder(name) {
    localStorage.removeItem(FOLDER_LIST);
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
        timeout: TIMEOUT
      }
    );
    return response;
  }

  newFolder(parent, name) {
    localStorage.removeItem(FOLDER_LIST);
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
        timeout: TIMEOUT
      }
    );
    return response;
  }

  getFolderList() {
    if (localStorage.getItem(FOLDER_LIST) !== null) {
      return this.#createPromise(FOLDER_LIST);
    }
    const response = axios.get('/list_folders', {
      params: {
        host: this.host
      },
      baseURL: this.baseURL,
      headers: {
        'Authorization': this.token
      },
      timeout: TIMEOUT
    });
    return response;
  }

  // Send

  sendMessage(smtp_host, sender, to_list, cc_list, bcc_list, subject, html_body, text_body, draft) {
    // TODO:
    // - attachments
    const response = axios.put('/send',
      JSON.stringify({
        smtp_host: smtp_host,
        host: this.host,
        sender: sender,
        to_list: to_list,
        cc_list: cc_list,
        bcc_list: bcc_list,
        subject: subject,
        html: html_body,
        text: text_body,
        draft: draft // false == outbox, true == drafts
      }),
      {
        baseURL: this.baseURL,
        headers: {
          'Authorization': this.token
        },
        timeout: TIMEOUT
      }
    );
    return response;
  }

  // IMAP Messages

  moveMessages(source, destination, ids, order, field) {
    if (source === "INBOX" || destination === "INBOX") {
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
        timeout: TIMEOUT
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
        timeout: TIMEOUT
      }
    );
    return response;
  }

  getMessages(folder, order, field) {
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
        timeout: TIMEOUT
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
        timeout: TIMEOUT
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
        timeout: TIMEOUT
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