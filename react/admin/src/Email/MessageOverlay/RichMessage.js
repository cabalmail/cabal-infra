import React from 'react';
import ApiClient from '../ApiClient';
import DOMPurify from 'dompurify';

class RichMessage extends React.Component {

  constructor(props) {
    super(props);
    const body = this.props.body.replace(/src="http/g, 'src="disabled-http');
    this.state = {
      render: "normal",
      body: body,
      imagesLoaded: false,
      hasRemoteImages: false
    }
    this.api = new ApiClient(this.props.api_url, this.props.token, this.props.host);
  }

  componentDidMount() {
    if (this.state.body !== this.props.body) {
      this.setState({...this.state, hasRemoteImages: true});
    }
    const imgs = document.getElementById("message_html").getElementsByTagName("img");
    for (var i = 0; i < imgs.length; i++) {
      var results = imgs[i].src.match(/^cid:([^"]*)/);
      if (results !== null) {
        this.loadImage(results[1], imgs[i]);
      }
    }
  }

  loadImage(cid, img) {
    var response = this.fetchImage(
      cid,
      this.props.folder,
      this.props.id,
      this.props.seen
    );
    response.then(data => {
      img.src = data.data.url;
    }).catch(e => {
      this.props.setMessage("Unable to load inline image.", true);
      console.log(e);
    });
  }

  loadRemoteImages = () => {
    this.setState({
      ...this.state,
      body: this.props.body,
      imagesLoaded: true
    });
  }

  rotateBackground = (e) => {
    e.preventDefault();
    switch (this.state.render) {
      case "inverted":
        this.setState({...this.state, render: "normal"});
        break;
      case "forced":
        this.setState({...this.state, render: "inverted"});
        break;
      case "normal":
        this.setState({...this.state, render: "forced"});
        break;
      default:
        this.setState({...this.state, render: "normal"});
    }
  }

  render() {
    return (
      <div className={`message message_html ${this.state.render}`}>
        <div class="buttons">
          <button
            className="invert"
            onClick={this.rotateBackground}
            title="Invert background (useful when the text color is too close to the default background color)"
          >◐</button>
          <button
            className={`load ${this.state.hasRemoteImages && !this.state.imagesLoaded ? "" : "hidden"}`}
            onClick={this.loadRemoteImages}
            title="Download remote images (could allow third parties to track your interactions with this message)"
          >⇩</button>
          <div
            id="message_html"
            className={this.state.render}
            dangerouslySetInnerHTML={{__html: DOMPurify.sanitize(this.state.body)}}
          />
        </div>
      </div>
    );
  }
}

export default RichMessage;
