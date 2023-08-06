import React from 'react';
import ApiClient from '../../../ApiClient';
import { FOLDER_LIST } from '../../../constants';

/**
 * Fetches folders for current users and displays them in the email filter context
 */

class Folders extends React.Component {

  constructor(props) {
    super(props);
    this.state = {
      folders: [],
      subscribed_folders: []
    };
    this.api = new ApiClient(this.props.api_url, this.props.token, this.props.host);
  }

  componentDidMount() {
    const response = this.api.getFolderList();
    response.then(data => {
      try {
        localStorage.setItem(FOLDER_LIST, JSON.stringify(data));
      } catch (e) {
        console.log(e);
      }
      this.setState({ ...this.state, folders: data.data.folders, subscribed_folders: data.data.sub_folders });
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
    const sub_folder_list = this.state.subscribed_folders.map(item => {
      return (
        <option value={item}>{item}</option>
      );
    });
    const folder_list = this.state.folders.filter(item => {
      return this.state.folders.indexOf(item) === -1;
    }).map(item => {
      return (
        <option value={item}>{item}</option>
      );
    });
    return (
      <div className="filter-folder">
        <span className="filter filter-folder">
          <label htmlFor="folder">{this.props.label}:</label>
          <select
            name="folder"
            onChange={this.setFolder}
            value={this.props.folder}
            className="selectFolder"
          >
            <option value="INBOX">INBOX</option>
            <optgroup label="Subscribed Folders">
              {sub_folder_list}
            </optgroup>
            <optgroup label="Other Folders">
              {folder_list}
            </optgroup>
          </select>
        </span>
      </div>
    );
  }
}

export default Folders;