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

  #history = {
    
    push: function (val) {
      this.setState({
        markdown: val,
        history: this.state.history.slice(0, this.state.history_index).push(val),
        history_index: this.state.history_index + 1
      });
    },

    undo: function () {
      if (this.state.history_index <= 0) {
        return this.state.markdown;
      }
      var newIndex = this.state.history_index - 1;
      this.setState({
        history_index: newIndex,
        markdown: this.#history[newIndex]
      });
      return this.state.markdown;
    },

    redo: function () {
      if (this.state.history_index + 1 > this.state.history.length) {
        return this.state.markdown;
      }
      var newIndex = this.state.history_index + 1;
      this.setState({
        history_index: newIndex,
        markdown: this.#history[newIndex]
      });
      return this.state.markdown;
    }
  }

  constructor(props) {
    super(props);
    this.state = {
      markdown: "",
      history: [],
      history_index: 0
    };
  }

  handleKeyDown = (e) => {
    console.log(e);
    var markdown = this.state.markdown;
    var newMarkdown = markdown;
    var start = e.target.selectionStart;
    var end = e.target.selectionEnd;
    var newCursorStart = start + 1;
    var newCursorEnd = newCursorStart;
    var preventCursorMove = false;
    switch (e.keyCode) {
      case 8: // backspace
        newMarkdown = markdown.substring(0, start - 1) + markdown.substring(end);
        preventCursorMove = true;
        break;
      case 9: // tab
        e.preventDefault();
        newMarkdown = markdown.substring(0, start) + e.key + markdown.substring(end);
        break;
      case 13: // enter
        e.preventDefault();
        if (e.shiftKey) { // line break without paragraph
          newMarkdown = markdown.substring(0, start) + "  \n" + markdown.substring(end);
          newCursorStart = start + 3;
          newCursorEnd = start + 3;
        } else {
          newMarkdown = markdown.substring(0, start) + "\n\n" + markdown.substring(end);
          newCursorStart = start + 2;
          newCursorEnd = start + 2;
        }
        break;
      case 16: // shift
        return;
      case 17: // control
        return;
      case 18: // alt/option
        return;
      case 37: // left arrow
        preventCursorMove = true;
        break;
      case 38: // up arrow
        preventCursorMove = true;
        break;
      case 39: // right arrow
        preventCursorMove = true;
        break;
      case 40: // down arrow
        preventCursorMove = true;
        break;
      case 66: // b
        // TODO: toggle on/off
        if (e.metaKey) {
          newMarkdown = markdown.substring(0, start) + '__' + markdown.substring(start, end) + '__' + markdown.substring(end);
          newCursorStart = start + 2;
          newCursorEnd = end + 2;
        } else {
          newMarkdown = markdown.substring(0, start) + e.key + markdown.substring(end);
        }
        break;
      case 73: // i
        // TODO: toggle on/off
        if (e.metaKey) {
          newMarkdown = markdown.substring(0, start) + '_' + markdown.substring(start, end) + '_' + markdown.substring(end);
          newCursorStart = start + 1;
          newCursorEnd = end + 1;
        } else {
          newMarkdown = markdown.substring(0, start) + e.key + markdown.substring(end);
        }
        break;
      case 83: // s
        // TODO: toggle on/off
        if (e.metaKey) {
          newMarkdown = markdown.substring(0, start) + '~~' + markdown.substring(start, end) + '~~' + markdown.substring(end);
          newCursorStart = start + 2;
          newCursorEnd = end + 2;
        } else {
          newMarkdown = markdown.substring(0, start) + e.key + markdown.substring(end);
        }
        break;
      case 91: // meta/command
        return;
      default:
        newMarkdown = markdown.substring(0, start) + e.key + markdown.substring(end);
        break;
    }
    this.#history.push(newMarkdown);
    if (!preventCursorMove) {
      setTimeout(() => {
        e.target.selectionStart = newCursorStart;
        e.target.selectionEnd = newCursorEnd;
      }, 10);
    }
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