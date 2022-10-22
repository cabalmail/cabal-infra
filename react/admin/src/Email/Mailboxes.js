import React from 'react';

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
      this.setState({ mailboxes: data });
    });
  }

  getList = async (e) => {
    const response = await axios.post('/list_mailboxes', {
      baseURL: this.props.api_url,
      headers: {
        'Authorization': this.props.token
      },
      timeout: 10000,
      params: {
        user: this.props.userName,
        password: this.props.password
      }
    });
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