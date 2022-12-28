import axios from 'axios';

export default class ApiClient {

  constructor(baseURL, token, host) {
    this.baseURL = baseURL;
    this.token = token;
    this.host = host;
  }

  fetchImage = (cid, folder, id, index, seen) => {
    const response = axios.get('/fetch_inline_image',
      {
        params: {
          folder: this.props.folder,
          host: this.host,
          id: this.props.id,
          index: "<" + cid + ">",
          seen: this.props.seen
        },
        baseURL: this.props.api_url,
        headers: {
          'Authorization': this.props.token
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