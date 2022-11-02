import React from 'react';

class Messages extends React.Component {

  constructor(props) {
    super(props);
    this.state = {
      messages: null
    };
  }

  componentDidMount() {
    const response = this.getList();
    response.then(data => {
      this.setState({ messages: data });
      console.log(data);
    });
  }

  getList = async (e) => {
    const response = await axios.post('/list_messages',
      JSON.stringify({
        user: this.props.userName,
        password: this.props.password,
        mailbox: this.props.mailbox
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
    const mailbox_list = JSON.stringify(this.state.mailboxes)
    return (
      <>
        <div>Messages in {this.props.mailbox}</div>
        <div>{message_list}</div>
      </>
    );
  }
}

export default Messages;