import React from 'react';
import axios from 'axios';
import DOMPurify from 'dompurify';

class RichMessage extends React.Component {

  constructor(props) {
    super(props);
    this.state = {
      invert: false,
      body: this.props.body.replace(/src="http/g, 'src="disabled-http'),
      imagesLoaded: false,
      hasRemoteImages: false
    }
  }

  componentDidMount() {
    if (this.state.body !== this.props.body) {
      this.setState({hasRemoteImages: true});
    }
    const imgs = document.getElementById("message_html").getElementsByTagName("img");
    for (var i = 0; i < imgs.length; i++) {
      var results = imgs[i].src.match(/^cid:([^"]*)/);
      if (results !== null) {
        this.loadImage(results[1], imgs[i]);
      }
    }
  }

  fetchImage = async (cid) => {
    const response = await axios.post('/fetch_inline_image',
      JSON.stringify({
        user: this.props.userName,
        password: this.props.password,
        mailbox: this.props.mailbox,
        host: this.props.host,
        id: this.props.id,
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
    var response = this.fetchImage(cid);
    response.then(data => {
      img.src = data.data.data.url;
    }).catch(e => {
      this.props.setMessage("Unable to load inline image.");
      console.log(e);
    });
  }

  loadRemoteImages() {
    console.log(this.props.body);
    this.setState({
      body: this.props.body,
      imagesLoaded: true
    });
  }

  toggleBackground = (e) => {
    e.preventDefault();
    this.setState({invert: !this.state.invert})
  }

  render() {
    return (
      <div className={`message message_html ${this.state.invert ? "inverted" : ""}`}>
        <button className="invert" onClick={this.toggleBackground}>◐</button>
        <button
          className={`load ${this.state.hasRemoteImages && !this.state.imagesLoaded ? "" : "hidden"}`}
          onClick={this.loadRemoteImages}
        >⇩</button>
        <div
          id="message_html"
          className={this.state.invert ? "inverted" : ""}
          dangerouslySetInnerHTML={{__html: DOMPurify.sanitize(this.state.body)}}
        />
      </div>
    );
  }
}

export default RichMessage;
