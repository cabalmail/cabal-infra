import React from 'react';
import ApiClient from '../ApiClient';
import { IMMUTABLE_FOLDERS } from '../constants';
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

  handleSubmit = (e) => {
    e.preventDefault();
    console.log("Form not implemeted yet.");
  }

  handleNewClick = (e) => {
    console.log("New subfolder clicked");
  }

  handleChange = (e) => {
    this.setState({...this.state, new_folder: e.target.value});
  }

  render() {
    // TODO: handle nexted arrays
    const folder_list = this.state.folders.map(item => {
      const buttons = item in IMMUTABLE_FOLDERS ? (
        <>
          <button
            className="folder_button new_subfolder"
            onClick={this.handleNewClick}
            title="New subfolder"
          >📁</button>
          <button
            className="folder_button delete_folder"
            onClick={this.handleDelClick}
            title="Delete folder"
          >🗑️</button>
        </>
      ) : "";
      return (
        <li className="folder" id={item}>
          <span className="folder_name">{item}</span>
          {buttons}
        </li>
      );
    });
    return (
      <div className="folders">
        <form onSubmit={this.handleSubmit} className="new_folder">
          <input
            type="text"
            id="new_folder"
            name="new_folder"
            className="new_folder"
            value={this.state.new_folder}
            onChange={this.handleChange}
          />
          <button className="new_folder">New Folder</button>
        </form>
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