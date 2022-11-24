import React from 'react';
import axios from 'axios';

class Envelopes extends React.Component {

  constructor(props) {
    super(props);
    this.state = {
      envelopes: [],
    };
  }

  componentDidMount() {
    const response = this.getList();
    response.then(data => {
      this.setState({
        envelopes: data.data.data.envelopes
      });
      console.log(this.state.envelopes);
    });
  }

  componentDidUpdate(prevProps, prevState) {
    if (this.props.message_ids !== prevProps.message_ids) {
      const response = this.getList();
      response.then(data => {
        this.setState({
          envelopes: data.data.data.envelopes
        });
      });
      console.log(this.state.envelopes);
    }
  }

  getList = async (e) => {
    const response = await axios.post('/list_envelopes',
      JSON.stringify({
        user: this.props.userName,
        password: this.props.password,
        mailbox: this.props.mailbox,
        ids: this.props.message_ids
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

  handleClick = (e) => {
    e.preventDefault();
    console.log(this.state.envelops[e.target.value]);
    this.props.showOverlay(this.state.envelopes[e.target.value]);
  }

  render() {
    const message_list = this.props.message_ids.map(id => {
      if (id.toString() in this.state.envelopes) {
        var message = this.state.envelopes[id];
        return (
          <li key={id} className={`message-row ${message.flags.map(d => {return d.replace("\\","")}).join(" ")}`} >
            <span className="message-date">{message.date}</span>
            <span className="message-from">{message.from[0]}</span>
            <button
              className="message-subject"
              onClick={this.handleClick}
              value={id}
            >{message.subject}</button>
          </li>
        );
      }
      return (
        <li key={id} className="message-row loading">
          <span className="message-date"></span>
          <span className="message-from"></span>
          <span className="message-subject"></span>
        </li>
      );
    });
    return (
      <>
        {message_list}
      </>
    );
  }
}

export default Envelopes;