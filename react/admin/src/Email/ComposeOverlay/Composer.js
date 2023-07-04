import React from 'react';
import './ComposeOverlay.css';

class Composer extends React.Component {

  // TODO:
  // - File upload
  // - - Inline Images
  // - - Attachments
  // - Bold __x__
  // - Italics _x_
  // - Strikethrough ~~x~~ 
  // - Paragraph
  // - Headings
  // - Ordered and unordered lists
  // - Links [x](htts://example.com/x)
  // - Block quotes > 

  constructor(props) {
    super(props);
    this.state = {
      markdown: "",
      cursor: 0
    };
  }

  handleKeyDown = (e) => {
    // e.preventDefault();
    console.log(e);
    var markdown = this.state.markdown;
    var start = e.target.selectionStart;
    var end = e.target.selectionEnd;
    switch (e.keyCode) {
      case 8: // backspace
        var newMarkdown = markdown.substring(0, start -1) + markdown.substring(end);
        break;
      case 9: // tab
        break;
      case 13: // enter
        var newMarkdown = markdown.substring(0, start) + "\n\n" + markdown.substring(end);
        break;
      case 16: // shift
        break;
      case 17: // control
        break;
      case 18: // option/alt
        break;
      case 37: // left arrow
        break;
      case 38: // up arrow
        break;
      case 39: // right arrow
        break;
      case 40: // down arrow
        break;
      case 91: // meta/command
        break;
      default:
        var newMarkdown = markdown.substring(0, start) + e.key + markdown.substring(end);
        break;
    }
    this.setState(
      {
        markdown: newMarkdown
      }
    );
    setTimeout(() => {
      e.target.selectionStart = start + 1;
      e.target.selectionEnd = start + 1;
    }, 10);
  }

  // handleKeyDown = (e) => {
  //   e.preventDefault();
  //   console.log(e);
  // }

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
          <button className="composer-toolbar-button composer-toolbar-strikethrough">S</button>
          <button className="composer-toolbar-button composer-toolbar-link">🔗</button>
        </div>
        <textarea
          value={this.state.markdown}
          className="composer-text"
          id="composer-text"
          name="composer-text"
          
          onKeyDown={this.handleKeyDown}
        />
      </div>
    );
  }
}

export default Composer;