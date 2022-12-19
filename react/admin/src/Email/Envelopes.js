import React from 'react';
import axios from 'axios';

class Envelopes extends React.Component {

  constructor(props) {
    super(props);
    this.state = {
      envelopes: [],
      selected: null
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
        folder: this.props.folder,
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
    this.setState({...this.state,selected:e.target.id});
  }

  render() {
    const message_list = this.props.message_ids.map(id => {
      if (id.toString() in this.state.envelopes) {
        var message = this.state.envelopes[id];
        var flags = message.flags.map(d => {return d.replace("\\","")}).join(" ");
        var selected = this.state.selected === id.toString() ? "selected" : "";
        return (
          <li className={`message-row ${flags} ${selected}`}>
            <div className="message-line-1">
              <div className="message-field message-from">{message.from[0]}</div>
              <div className="message-field message-date">{message.date}</div>
            </div>
            <div className="message-field message-subject">
              <input type="checkbox" id={id} onChange={this.props.handleCheck} />
              <label htmlFor={id}><span className="checked">☑︎</span><span className="unchecked">□</label>&nbsp;
              {flags.match(/Seen/) ? '✉️ ' : '🔵 '}
              {flags.match(/Flagged/) ? '🚩 ' : ''}
              {flags.match(/Answered/) ? '⤶ ' : ''}
              {message.struct[1] === "mixed" ? '📎 ' : ''}
              <span id={id} onClick={this.handleClick}>{message.subject}</span>
            </div>
          </li>
        );
      }
      return (
        <li className="message-row loading">
          <div className="message-line-1">
            <div className="message-field message-from">&nbsp;</div>
            <div className="message-field message-date">&nbsp;</div>
          </div>
          <div className="message-field message-subject">&nbsp;</div>
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