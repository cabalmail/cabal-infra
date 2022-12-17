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
        ...this.state,
        envelopes: data.data.envelopes
      });
    }).catch( e => {
      this.props.setMessage("Unable to fetch envelopes.");
      console.log(e);
    });
  }

  componentDidUpdate(prevProps, prevState) {
    if (this.props.message_ids !== prevProps.message_ids) {
      const response = this.getList();
      response.then(data => {
        this.setState({
          ...this.state,
          envelopes: data.data.envelopes
        });
      }).catch( e => {
        this.props.setMessage("Unable to fetch envelopes.");
        console.log(e);
      });
    }
  }

  getList = async (e) => {
    const response = await axios.post('/list_envelopes',
      JSON.stringify({
        user: this.props.userName,
        password: this.props.password,
        host: this.props.host,
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
    this.props.showOverlay(this.state.envelopes[e.target.id]);
  }

  render() {
    const message_list = this.props.message_ids.map(id => {
      if (id.toString() in this.state.envelopes) {
        var message = this.state.envelopes[id];
        return (
          <li key={id} className={`message-row ${message.flags.map(d => {return d.replace("\\","")}).join(" ")}`} >
            <div className="message-line-1">
              <div className="message-from">{message.from[0]}</div>
              <div className="message-date">{message.date}</div>
            </div>
            <div
              id={id}
              className="message-subject"
              onClick={this.handleClick}
            ><checkbox id={id} /> {message.subject}</div>
          </li>
        );
      }
      return (
        <li key={id} className="message-row loading">
          <div className="message-line-1">
            <div className="message-from">&nbsp;</div>
            <div className="message-date">&nbsp;</div>
          </div>
          <div className="message-subject">&nbsp;</div>
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