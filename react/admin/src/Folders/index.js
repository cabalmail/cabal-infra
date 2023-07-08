import React from 'react';
import ApiClient from '../ApiClient';
import { PERMANENT_FOLDERS } from '../constants';
import './Folders.css';

/**
 * Fetches folders for current users and displays them
 */

class Folders extends React.Component {

  constructor(props) {
    super(props);
    this.state = {
      folders: [],
      new_folder: ''
    };
    this.api = new ApiClient(this.props.api_url, this.props.token, this.props.host);
  }

  componentDidMount() {
    const response = this.api.getFolderList();
    response.then(data => {
      localStorage.setItem("folder_list", JSON.stringify(data));
      this.setState({ ...this.state, folders: data.data });
    }).catch(e => {
      console.log(e);
    });
  }

  setFolder = (e) => {
    e.preventDefault();
    this.props.setFolder(e.target.value);
  }

  handleNewClick = (e) => {
    if (this.state.new_folder === "") {
      this.props.setMessage("Please enter a name in the input box.", true);
      return;
    }
    if (this.state.new_folder.includes(".") || this.state.new_folder.includes("/")) {
      this.props.setMessage("Folder names must not contain '.' or '/'.")
    }
    this.api.newFolder(
      e.target.dataset.parent,
      this.state.new_folder
    ).then(data => {
      this.setState({ ...this.state, folders: data.data });
    }).catch(e => {
      this.props.setMessage("Unable to create folder.", true);
      console.log(e);
    });
  }

  handleDelClick = (e) => {
    this.api.deleteFolder(
      e.target.dataset.folder,
    ).then(data => {
      this.setState({ ...this.state, folders: data.data });
    }).catch(e => {
      this.props.setMessage("Unable to delete folder.", true);
      console.log(e);
    });
  }

  handleChange = (e) => {
    this.setState({...this.state, new_folder: e.target.value});
  }

  render() {
    // TODO: handle nexted arrays
    const folder_list = this.state.folders.map(item => {
      if (item === "INBOX") {
        return false;
      }
      const deleteButton = PERMANENT_FOLDERS.includes(item) ? null : (
        <>
          <button
            className="folder_button delete_folder"
            data-folder={item}
            onClick={this.handleDelClick}
            title={`Delete ${item}`}
          >🗑️</button>
        </>
      );
      return (
        <li className="folder" id={item}>
          <span className="folder_name">{item}</span>
          <button
            className="folder_button new_subfolder"
            data-parent={item}
            onClick={this.handleNewClick}
            title={`New subfolder of ${item}`}
          >📁</button>
          {deleteButton}
        </li>
      );
    });
    return (
      <div className="folders">
        <div className="new_folder">
          <input
            type="text"
            id="new_folder"
            name="new_folder"
            className="new_folder"
            value={this.state.new_folder}
            onChange={this.handleChange}
          />
          <button
            className="new_folder"
            data-parent=""
            onClick={this.handleNewClick}
          >New Top-level Folder</button>
        </div>
        <hr />
        <div id="count">Found: {this.state.folders.length} folders</div>
        <ul className="folder_list">
          {folder_list}
        </ul>
      </div>
    );
  }
}

export default Folders;