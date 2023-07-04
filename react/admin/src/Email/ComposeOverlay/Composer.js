import React from 'react';
import './ComposeOverlay.css';

class Composer extends React.Component {

  // TODO:
  // - File upload
  // - - Inline Images
  // - - Attachments
  // - Italics
  // - Underline
  // - Paragraph
  // - BR
  // - Headings
  // - Ordered and unordered lists
  // - Links
  // - Strikethrough
  // - Block quotes

  constructor(props) {
    super(props);
    this.state = {
      text: ""
    };
  }

  handleKeyPress = (e) => {
    e.preventDefault();
    document.getElementById("key-codes").innerHTML(`<p>${e.keyCode}</p>`)
    this.setState({text: e.target.value});
  }

  render() {
    return (
      <div className="composer-wrapper">
        <label htmlFor="composer-text">Message Body</label>
        <div className="composer-toolbar">
        <select id="composer-toolbar-style-select" className="composer-toolbar-style-select">
            <option value="body-text">Body Text</option>
            <option value="h1">Header Level 1</option>
            <option value="h2">Header Level 2</option>
            <option value="h2">Header Level 3</option>
            <option value="h2">Header Level 4</option>
            <option value="h2">Header Level 5</option>
            <option value="h2">Header Level 6</option>
            <option value="block-quote">Block Quote</option>
            <option value="pre">Monospace</option>
          </select>
          <button className="composer-toolbar-button composer-toolbar-bold">B</button>
          <button className="composer-toolbar-button composer-toolbar-italic">I</button>
          <button className="composer-toolbar-button composer-toolbar-underline">U</button>
          <button className="composer-toolbar-button composer-toolbar-strikethrough">S</button>
          <button className="composer-toolbar-button composer-toolbar-link">🔗</button>
        </div>
        <textarea
          value={this.state.text}
          defaultValue={this.props.quotedText}
          className="composer-text"
          id="composer-text"
          name="composer-text"
          onKeyPress={this.handleKeyPress}
        />
        <div id="key-codes"></div>
      </div>
    );
  }
}

export default Composer;