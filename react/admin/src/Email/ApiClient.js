import axios from 'axios';

export default class ApiClient {

  constructor(baseURL, token) {
    this.baseURL = baseURL;
    this.token = token;
  }

  getMessage(folder, host, id, seen) {
    const response = axios.get('/fetch_message',
      {
        params: {
          folder: folder,
          host: host,
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
  
  getAttachment(a, folder, host, id, seen) {
    const response = axios.get('/fetch_attachment',
      {
        params: {
          folder: folder,
          host: host,
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
  
  getAttachments(folder, host, id, seen) {
    const response = axios.get('/list_attachments',
      {
        params: {
          folder: folder,
          host: host,
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