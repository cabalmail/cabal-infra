import axios from 'axios';
import { ONE_SECOND } from 'constants';

export default class ApiClient {

  constructor(baseURL, token, host) {
    this.baseURL = baseURL;
    this.token = token;
    this.host = host;
  }

  newFolder(parent, name) {
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