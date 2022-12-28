import axios from 'axios';

export class ApiClient {

  getMessage = (folder, host, id, seen, baseURL, token) => {
    const response = axios.get('/fetch_message',
      {
        params: {
          folder: folder,
          host: host,
          id: id,
          seen: seen
        },
        baseURL: baseURL,
        headers: {
          'Authorization': token
        },
        timeout: 20000
      }
    );
    return response;
  };
  
  getAttachment = (a, folder, host, id, seen, baseURL, token) => {
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
        baseURL: baseURL,
        headers: {
          'Authorization': token
        },
        timeout: 90000
      }
    );
    return response;
  };
  
  getAttachments = (folder, host, id, seen, baseURL, token) => {
    const response = axios.get('/list_attachments',
      {
        params: {
          folder: folder,
          host: host,
          id: id,
          seen: seen
        },
        baseURL: baseURL,
        headers: {
          'Authorization': token
        },
        timeout: 20000
      }
    );
    return response;
  };
}