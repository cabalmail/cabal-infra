import React from 'react';
import ApiClient from '../../ApiClient';

/**
 * Fetches folders for current users and displays them
 */

class Folders extends React.Component {

  constructor(props) {
    super(props);
    this.state = {
      folders: []
    };
    this.api = new ApiClient(this.props.api_url, this.props.token, this.props.host);
  }

  componentDidMount() {
    const response = this.api.getFolderList();
    response.then(data => {
      this.setState({ ...this.state, folders: data.data });
    }).catch(e => {
      this.props.setMessage("Unable to fetch folders.", true);
      console.log(e);
    });
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