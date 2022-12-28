import axios from 'axios';

export default class ApiClient {

  constructor(baseURL, token, host) {
    this.baseURL = baseURL;
    this.token = token;
    this.host = host;
  }

  getFolderList() {
    const response = axios.get('/list_folders', {
      params: {
        host: this.host
      },
      baseURL: this.baseURL,
      headers: {
        'Authorization': this.token
      },
      timeout: 10000
    });
    return response;
  }

  moveMessages(source, destination, ids, order, field) {
    const response = axios.put('/move_message',
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
        timeout: 10000
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
        timeout: 10000
      }
    );
    return response;
  }

  getMessages(folder, field, order) {
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
        timeout: 8000
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
          ids: ids
        },
        baseURL: this.baseURL,
        headers: {
          'Authorization': this.token
        },
        timeout: 10000
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
        timeout: 90000
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
        timeout: 20000
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
        timeout: 90000
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
        timeout: 20000
      }
    );
    return response;
  };

}