import React from 'react';

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

  onChange = (e) => {
    e.preventDefault();
    this.setState({text: e.target.value});
  }

  render() {
    return (
      <div className="composer-wrapper">
        <div className="composer-toolbar">
          <span className="composer-toolbar-style">
            <select className="composer-toolbar-style-select">
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
          </span>
          <span className="composer-toolbar-bold">B</span>
          <span className="composer-toolbar-italic">I</span>
          <span className="composer-toolbar-underline">U</span>
          <span className="composer-toolbar-strikethrough">S</span>
          <span className="composer-toolbar-linebreak">BR</span>
          <span className="composer-toolbar-incmargin">⇥</span>
          <span className="composer-toolbar-decmargin">⇤</span>
        </div>
        <textarea
          rows={10}
          cols={120}
          value={this.state.text}
          defaultValue={this.props.quotedText}
          className="composer-text"
          onChange={this.onChange}
        />
      </div>
    );
  }
}

export default Composer;