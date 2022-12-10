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
    const regex = /src="cid:([^"]*)/ig;
    html.replaceAll(regex, 'onerror="console.log($1)"');
    return html;
  }

  componentDidMount() {
    const imgs = document.getElementById("message_html").getElementsByTagName("img");
    console.log(imgs);
    for (var i = 0; i < imgs.length; i++) {
      if (imgs[i].src.match(/^cid:/)) {
        console.log(imgs[i].src);
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
          dangerouslySetInnerHTML={{__html: this.props.message_body_html}}
        />
      </div>
    );
  }
}

export default RichMessage;
