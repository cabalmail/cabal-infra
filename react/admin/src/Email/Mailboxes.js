import React from 'react';
import axios from 'axios';

/**
 * Fetches mailboxes for current users and displays them
 */

class Mailboxes extends React.Component {

  constructor(props) {
    super(props);
    this.state = {
      mailboxes: ""
    };
  }

  componentDidMount() {
    const response = this.getList();
    response.then(data => {
      this.setState({ mailboxes: JSON.stringify(data) });
      console.log(data);
    });
  }

  getList = async (e) => {
    const response = await axios.post('/list_mailboxes',
      JSON.stringify({
        user: this.props.userName,
        password: this.props.password
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

  render() {
    return (
      <>
        <div>Mailboxes</div>
        <div>{this.state.mailboxes}</div>
      </>
    );
  }
}

export default Mailboxes;