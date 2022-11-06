import React from 'react';
import Axios from 'axios';

class Envelopes extends React.Component {

  constructor(props) {
    super(props);
  }

  componentDidMount() {
    const response = this.getList();
    response.then(data => {
      this.setState({
        envelopes: data.data.data.envelopes
      });
    });
  }

  getList = async (e) => {
    const response = await axios.post('/list_envelopes',
      JSON.stringify({
        user: this.props.userName,
        password: this.props.password,
        mailbox: this.props.mailbox,
        ids: this.props.ids
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

