import React from 'react';
import axios from 'axios';

/**
 * Fetches mailboxes for current users and displays them
 */

class Mailboxes extends React.Component {

  constructor(props) {
    super(props);
    this.state = {
      mailboxes: []
    };
  }

  componentDidMount() {
    const response = this.getList();
    response.then(data => {
      this.setState({ ...this.state, mailboxes: data.data });
    }).catch(e => {
      this.props.setMessage("Unable to fetch mailboxes.");
      console.log(e);
    });
  }

  getList = async (e) => {
    const response = await axios.post('/list_mailboxes',
      JSON.stringify({
        user: this.props.userName,
        password: this.props.password,
        host: this.props.host
      }),
      {
        baseURL: this.props.api_url,
        headers: {
          'Authorization': this.props.token
        },
        timeout: 10000
      }
    );
    return response;
  }

  setMailbox = (e) => {
    e.preventDefault();
    this.props.setMailbox(e.target.value);
  }

  render() {
    // TODO: handle nexted arrays
    const mailbox_list = this.state.mailboxes.map(item => {
      return (
        <option value={item}>{item}</option>
      );
    });
    return (
      <div>
        <label htmlFor="mailbox">Folder:</label>
        <select
          name="mailbox"
          onChange={this.setMailbox}
          value={this.props.mailbox}
          className="selectMailbox"
        >
        {mailbox_list}
        </select>
      </div>
    );
  }
}

export default Mailboxes;