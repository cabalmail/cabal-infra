import React from 'react';
import axios from 'axios';

/**
 * Fetches folders for current users and displays them
 */

class Folders extends React.Component {

  constructor(props) {
    super(props);
    this.state = {
      folders: []
    };
  }

  componentDidMount() {
    const response = this.getList();
    response.then(data => {
      this.setState({ ...this.state, folders: data.data });
    }).catch(e => {
      this.props.setMessage("Unable to fetch folders.", true);
      console.log(e);
    });
  }

  getList = (e) => {
    const response = axios.get('/list_folders', {
      params: {
        host: this.props.host
      },
      baseURL: this.props.api_url,
      headers: {
        'Authorization': this.props.token
      },
      timeout: 10000
    });
    return response;
  }

  setFolder = (e) => {
    e.preventDefault();
    this.props.setFolder(e.target.value);
  }

  render() {
    // TODO: handle nexted arrays
    const folder_list = this.state.folders.map(item => {
      return (
        <option value={item}>{item}</option>
      );
    });
    return (
      <div>
        <span className="filter filter-folder">
          <label htmlFor="folder">Folder:</label>
          <select
            name="folder"
            onChange={this.setFolder}
            value={this.props.folder}
            className="selectFolder"
          >
          {folder_list}
          </select>
        </span>
      </div>
    );
  }
}

export default Folders;