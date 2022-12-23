import React from 'react';
import axios from 'axios';
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

  handleSubmit = (e) => {
    e.preventDefault();
    console.log("Form not implemeted yet.");
  }

  handleNewClick = (e) => {
    console.log("New subfolder clicked");
  }

  handleChange = (e) => {
    this.setState({...this.state, e.target.value});
  }

  render() {
    // TODO: handle nexted arrays
    const folder_list = this.state.folders.map(item => {
      return (
        <li className="folder" id={item}>
          <span className="folder_name">{item}</span>
          <button
            className="new_subfolder"
            onClick={this.handleNewClick}
            title="New subfolder"
          >⊕</button>
          <button
            className="delete_folder"
            onClick={this.handleDelClick}
            title="Delete folder"
          >⊖</button>
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
        <ul className="folder_list">
          {folder_list}
        </ul>
      </div>
    );
  }
}

export default Folders;