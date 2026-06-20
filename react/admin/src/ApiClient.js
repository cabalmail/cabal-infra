import axios from 'axios';
import { ONE_SECOND, ADDRESS_LIST, FOLDER_LIST } from './constants';
const TIMEOUT = ONE_SECOND * 10;
// Bulk IMAP mutations (move / flag / purge / empty-trash) run server-side as
// chunked, sequential IMAP commands and can take far longer than a normal
// request -- up to the API's 29s ceiling. Wait just past that so the client
// hears the server's real verdict instead of firing a false "failed" on a
// slow-but-successful operation.
const MUTATION_TIMEOUT = ONE_SECOND * 30;

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

  setFavorite(address, favorite) {
    localStorage.removeItem(ADDRESS_LIST);
    const response = axios.put('/set_favorite',
      JSON.stringify({
        address: address,
        favorite: !!favorite
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

  subscribeFolder(folder) {
    const response = axios.put('/subscribe_folder',
      JSON.stringify({
        host: this.host,
        folder: folder
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

  unsubscribeFolder(folder) {
    const response = axios.put('/unsubscribe_folder',
      JSON.stringify({
        host: this.host,
        folder: folder
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

  // Send

  sendMessage(smtp_host, sender, to_list, cc_list, bcc_list, subject, other_headers, html_body, text_body, draft, attachments) {
    const response = axios.put('/send',
      JSON.stringify({
        smtp_host: smtp_host,
        host: this.host,
        sender: sender,
        to_list: to_list,
        cc_list: cc_list,
        bcc_list: bcc_list,
        subject: subject,
        other_headers: other_headers,
        html: html_body,
        text: text_body,
        draft: draft, // false == outbox, true == drafts
        attachments: attachments || []
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

  // Attachment uploads
  //
  // API Gateway caps a Lambda-proxy request at 10 MB, so outbound
  // attachments are uploaded directly to the cache bucket via presigned
  // PUT URLs and then referenced by key in /send. Keys are minted by
  // the /upload_url Lambda under `outbound/<user>/<uuid>/<filename>` and
  // cleaned up by the bucket's lifecycle rule.

  getAttachmentUploadUrls(files) {
    return axios.put('/upload_url',
      JSON.stringify({
        host: this.host,
        files: files.map(f => ({
          filename: f.filename,
          mime_type: f.mimeType,
        })),
      }),
      {
        baseURL: this.baseURL,
        headers: {
          'Authorization': this.token
        },
        timeout: TIMEOUT
      }
    );
  }

  uploadAttachmentToS3(url, blob, onProgress) {
    return axios.put(url, blob, {
      // Bypass the axios default of JSON-stringifying request bodies;
      // the blob must hit S3 byte-for-byte. Likewise, no Authorization
      // header — the presigned URL already carries its own signature.
      transformRequest: [(d) => d],
      headers: {
        'Content-Type': blob.type || 'application/octet-stream',
      },
      timeout: ONE_SECOND * 120,
      onUploadProgress: onProgress,
    });
  }

  // IMAP Messages

  moveMessages(source, destination, ids, order, field) {
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
        timeout: MUTATION_TIMEOUT
      }
    );
    return response;
  } 

  purgeMessages(folder, ids) {
    const response = axios.delete('/purge_messages',
      {
        baseURL: this.baseURL,
        data: JSON.stringify({
          host: this.host,
          folder: folder,
          ids: ids
        }),
        headers: {
          'Authorization': this.token
        },
        timeout: MUTATION_TIMEOUT
      }
    );
    return response;
  }

  emptyTrash(folder) {
    const response = axios.delete('/empty_trash',
      {
        baseURL: this.baseURL,
        data: JSON.stringify({
          host: this.host,
          folder: folder
        }),
        headers: {
          'Authorization': this.token
        },
        // A full-trash purge runs server-side like the other bulk mutations.
        timeout: MUTATION_TIMEOUT
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
        timeout: MUTATION_TIMEOUT
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

  // Folder STATUS poll. `flagged=1` asks the Lambda to add a SEARCH FLAGGED
  // count (the message list's steady-state poll uses uid_next/messages to
  // decide when to re-pull the UID list, and unseen/flagged for the pill
  // counts). Cheap enough to keep on the 10s message-list cadence.
  getFolderStatus(folder) {
    const response = axios.get('/folder_status',
      {
        params: {
          host: this.host,
          folder: folder,
          flagged: 1
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

  // Structured single-folder search. `params` is a plain object whose keys
  // mirror the `/search_envelopes` query string: `folder`, `text`, `from`,
  // `to`, `subject`, `since` (YYYY-MM-DD), `before` (YYYY-MM-DD), `unread`,
  // `flagged`, `has_attachment`, `limit`, `cursor`. Booleans are coerced to
  // `1` so the Lambda's TRUTHY check fires; empty strings are dropped.
  // Phase 1 of the search plan returns single-folder results; cross-folder
  // lands in Phase 3.
  searchEnvelopes(params) {
    const query = { host: this.host };
    for (const [key, value] of Object.entries(params || {})) {
      if (value === null || value === undefined || value === '' || value === false) continue;
      query[key] = value === true ? 1 : value;
    }
    const response = axios.get('/search_envelopes',
      {
        params: query,
        baseURL: this.baseURL,
        headers: {
          'Authorization': this.token
        },
        timeout: ONE_SECOND * 25
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
  
  getRawMessage(signedUrl) {
    return axios.get(signedUrl, {
      responseType: 'text',
      transformResponse: [(v) => v],
      timeout: ONE_SECOND * 30,
    });
  }

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
  
  // Admin — DMARC Reports

  listDmarcReports(nextToken) {
    const params = {};
    if (nextToken) {
      params.next_token = nextToken;
    }
    const response = axios.get('/list_dmarc_reports', {
      params: params,
      baseURL: this.baseURL,
      headers: {
        'Authorization': this.token
      },
      timeout: TIMEOUT
    });
    return response;
  }

  fetchDmarcXml(signedUrl) {
    return axios.get(signedUrl, {
      responseType: 'text',
      transformResponse: [(v) => v],
      timeout: ONE_SECOND * 30,
    });
  }

  checkDnsRecord(domain, recordType) {
    return axios.get('/check_dns_record', {
      params: { domain: domain, record_type: recordType },
      baseURL: this.baseURL,
      headers: {
        'Authorization': this.token
      },
      timeout: TIMEOUT
    });
  }

  repairDnsRecord(domain, recordType) {
    return axios.put('/repair_dns_record',
      JSON.stringify({ domain: domain, record_type: recordType }),
      {
        baseURL: this.baseURL,
        headers: {
          'Authorization': this.token
        },
        timeout: TIMEOUT
      }
    );
  }

  // Admin — User Management

  listUsers() {
    const response = axios.get('/list_users', {
      baseURL: this.baseURL,
      headers: {
        'Authorization': this.token
      },
      timeout: TIMEOUT
    });
    return response;
  }

  confirmUser(username) {
    const response = axios.put('/confirm_user',
      JSON.stringify({ username: username }),
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

  disableUser(username) {
    const response = axios.put('/disable_user',
      JSON.stringify({ username: username }),
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

  enableUser(username) {
    const response = axios.put('/enable_user',
      JSON.stringify({ username: username }),
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

  deleteUser(username) {
    const response = axios.delete('/delete_user', {
      baseURL: this.baseURL,
      data: JSON.stringify({ username: username }),
      headers: {
        'Authorization': this.token
      },
      timeout: TIMEOUT
    });
    return response;
  }

  // Admin — Address Management

  listAllAddresses() {
    const response = axios.get('/list_addresses_admin', {
      baseURL: this.baseURL,
      headers: {
        'Authorization': this.token
      },
      timeout: TIMEOUT
    });
    return response;
  }

  assignAddress(address, username) {
    localStorage.removeItem(ADDRESS_LIST);
    const response = axios.put('/assign_address',
      JSON.stringify({ address: address, username: username }),
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

  unassignAddress(address, username) {
    localStorage.removeItem(ADDRESS_LIST);
    const response = axios.put('/unassign_address',
      JSON.stringify({ address: address, username: username }),
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

  newAddressAdmin(username, subdomain, tld, comment, address, usernames) {
    localStorage.removeItem(ADDRESS_LIST);
    const response = axios.post('/new_address_admin',
      {
        username: username,
        subdomain: subdomain,
        tld: tld,
        comment: comment,
        address: address,
        usernames: usernames
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

  // Admin — Per-user domain access (deny list)

  listUserDomainAccess() {
    const response = axios.get('/list_user_domain_access', {
      baseURL: this.baseURL,
      headers: {
        'Authorization': this.token
      },
      timeout: TIMEOUT
    });
    return response;
  }

  setUserDomainAccess(username, domain, allowed) {
    const response = axios.put('/set_user_domain_access',
      JSON.stringify({ user: username, domain: domain, allowed: !!allowed }),
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

  // Domains the current user is permitted to create addresses on.

  listMyDomains() {
    const response = axios.get('/list_my_domains', {
      baseURL: this.baseURL,
      headers: {
        'Authorization': this.token
      },
      timeout: TIMEOUT
    });
    return response;
  }

  // User preferences (theme / accent / density)

  getPreferences() {
    return axios.get('/get_preferences', {
      baseURL: this.baseURL,
      headers: {
        'Authorization': this.token
      },
      timeout: TIMEOUT
    });
  }

  putPreferences(prefs) {
    return axios.put('/set_preferences',
      JSON.stringify(prefs),
      {
        baseURL: this.baseURL,
        headers: {
          'Authorization': this.token
        },
        timeout: TIMEOUT
      }
    );
  }

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