import React from 'react';
import axios from 'axios';
import DOMPurify from 'dompurify';

class RichMessage extends React.Component {

  constructor(props) {
    super(props);
    this.state = {
      invert: false
    }
  }

  formatHtml(data) {
    var html = DOMPurify.sanitize(data);
    return html;
  }

  fetchImage = async (cid) => {
    const response = await axios.post('/fetch_inline_image',
      JSON.stringify({
        user: this.props.userName,
        password: this.props.password,
        mailbox: this.props.mailbox,
        host: this.props.host,
        id: this.props.envelope.id,
        index: "<" + cid + ">"
      }),
      {
        baseURL: this.props.api_url,
        headers: {
          'Authorization': this.props.token
        },
        timeout: 90000
      }
    );
    return response;
  }

  loadImage(cid, img) {
    response = fetchImage(cid);
    response.then(data => {
      console.log(data);
      img.src = data.data.data.url;
    });
  }

  componentDidMount() {
    const imgs = document.getElementById("message_html").getElementsByTagName("img");
    console.log(imgs);
    for (var i = 0; i < imgs.length; i++) {
      if (var cid = imgs[i].src.match(/^cid:([^"]*)/)[1]) {
        console.log(cid);
        this.loadImage(cid, imgs[i]);
      }
    }
  }

  toggleBackground = (e) => {
    e.preventDefault();
    this.setState({invert: !this.state.invert})
  }

  render() {
    return (
      <div className={`message message_html ${this.state.invert ? "inverted" : ""}`}>
        <button className="invert" onClick={this.toggleBackground}>◐</button>
        <div
          id="message_html"
          className={this.state.invert ? "inverted" : ""}
          dangerouslySetInnerHTML={{__html: this.props.body}}
        />
      </div>
    );
  }
}

export default RichMessage;
