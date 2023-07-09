import React from 'react';
import './ComposeOverlay.css';
const STATE_KEY = 'composer-state';

class Composer extends React.Component {

  // TODO:
  // - File upload
  // - - Inline Images
  // - - Attachments
  // - Paragraph
  // - Headings
  // - Links [x](htts://example.com/x)
  // - Block quotes > 

  #history;

  constructor(props) {
    super(props);
    this.state = JSON.parse(localStorage.getItem(STATE_KEY)) || {
      markdown: "",
      history: [""],
      history_index: 0,
      preview: false
    };
    var that = this;
    this.#history = {
      supra: that,
      push: function (val) {
        var history = this.supra.state.history.slice(0, this.supra.state.history_index + 1);
        history.push(val);
        this.supra.setState({
          ...this.supra.state,
          markdown: val,
          history: history,
          history_index: this.supra.state.history_index + 1
        });
      },

      replace: function (val) {
        var history = this.supra.state.history.slice(0, this.supra.state.history_index + 1);
        history[this.supra.state.history_index] = val;
        this.supra.setState({
          ...this.supra.state,
          markdown: val,
          history: history
        });
      },

      undo: function () {
        if (this.supra.state.history_index <= 0) {
          return this.supra.state.markdown;
        }
        var newIndex = this.supra.state.history_index - 1;
        this.supra.setState({
          ...this.supra.state,
          history_index: newIndex,
          markdown: this.supra.state.history[newIndex]
        });
        return this.supra.state.markdown;
      },

      redo: function () {
        if (this.supra.state.history_index + 1 > this.supra.state.history.length) {
          return this.supra.state.markdown;
        }
        var newIndex = this.supra.state.history_index + 1;
        this.supra.setState({
          ...this.state,
          history_index: newIndex,
          markdown: this.supra.state.history[newIndex]
        });
        return this.supra.state.markdown;
      }
    }
  }

  setState(state) {
    try {
      localStorage.setItem(STATE_KEY, JSON.stringify(state));
    } catch (e) {
      console.log(e);
    }
    super.setState(state);
  }

  handleKeyDown = (e) => {
    if (e.keyCode < 48 || e.keyCode > 90) {
      console.log(e);
    }
    var markdown = this.state.markdown;
    var newMarkdown = markdown;
    var start = e.target.selectionStart;
    var end = e.target.selectionEnd;
    var newCursorStart = start + 1;
    var newCursorEnd = newCursorStart;
    var preventCursorMove = false;
    switch (e.keyCode) {
      // TODO: 
      // - delete key
      // - delete and backspace with opt, ctl, and cmd
      case 8: // backspace
        newMarkdown = markdown.substring(0, start - 1) + markdown.substring(end);
        this.#history.replace(newMarkdown);
        preventCursorMove = true;
        break;
      case 9: // tab
        e.preventDefault();
        newMarkdown = markdown.substring(0, start) + "\t" + markdown.substring(end);
        this.#history.push(newMarkdown);
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
        this.#history.push(newMarkdown);
        break;
      case 16: // shift
        return;
      case 17: // control
        return;
      case 18: // alt/option
        return;
      case 32: // space
        newMarkdown = markdown.substring(0, start) + e.key + markdown.substring(end);
        this.#history.push(newMarkdown);
        break;
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
      case 91: // meta/command
        preventCursorMove = true;
        break;
      default: // normal letters, digits, and symbols
        if (e.metaKey) { // check for keyboard shortcuts
          switch (e.keyCode) {
            case 66: // b
              // TODO: toggle on/off
              newMarkdown = markdown.substring(0, start) + '__' + markdown.substring(start, end) + '__' + markdown.substring(end);
              newCursorStart = start + 2;
              newCursorEnd = end + 2;
              this.#history.push(newMarkdown);
              break;
            case 73: // i
              // TODO: toggle on/off
              newMarkdown = markdown.substring(0, start) + '_' + markdown.substring(start, end) + '_' + markdown.substring(end);
              newCursorStart = start + 1;
              newCursorEnd = end + 1;
              this.#history.push(newMarkdown);
              break;
            case 75: // k
              newMarkdown = markdown.substring(0, start) + '[' + markdown.substring(start, end) + '](https://example.com)' + markdown.substring(end);
              newCursorStart = start + 1;
              newCursorEnd = end + 1;
              this.#history.push(newMarkdown);
              break;
            case 83: // s
              // TODO: toggle on/off
              newMarkdown = markdown.substring(0, start) + '~~' + markdown.substring(start, end) + '~~' + markdown.substring(end);
              newCursorStart = start + 2;
              newCursorEnd = end + 2;
              this.#history.push(newMarkdown);
              break;
            case 90: // z
              if (e.shiftKey) {
                this.#history.redo();
              } else {
                this.#history.undo();
              }
              preventCursorMove = true;
              break;
            default:
              break;
          }
        } else {
          newMarkdown = markdown.substring(0, start) + e.key + markdown.substring(end);
          this.#history.replace(newMarkdown);
        }
        break;
    }

    if (!preventCursorMove) {
      setTimeout(() => {
        e.target.selectionStart = newCursorStart;
        e.target.selectionEnd = newCursorEnd;
      }, 10);
    }
  }

  fireBold = (e) => {
    e.preventDefault();
    var ta = document.getElementById("composer-text");
    ta.focus();
    var message = {
      target: ta,
      keyCode: 66,
      key: "b",
      metaKey: true,
      shiftKey: false,
      preventDefault: function () {
        return true;
      }
    };
    return this.handleKeyDown(message);
  }

  fireItalic = (e) => {
    e.preventDefault();
    var ta = document.getElementById("composer-text");
    ta.focus();
    var message = {
      target: ta,
      keyCode: 73,
      key: "i",
      metaKey: true,
      shiftKey: false,
      preventDefault: function () {
        return true;
      }
    };
    return this.handleKeyDown(message);
  }

  fireLink = (e) => {
    e.preventDefault();
    var ta = document.getElementById("composer-text");
    ta.focus();
    var message = {
      target: ta,
      keyCode: 75,
      key: "k",
      metaKey: true,
      shiftKey: false,
      preventDefault: function () {
        return true;
      }
    };
    return this.handleKeyDown(message);
  }

  fireStrikethrough = (e) => {
    e.preventDefault();
    var ta = document.getElementById("composer-text");
    ta.focus();
    var message = {
      target: ta,
      keyCode: 83,
      key: "s",
      metaKey: true,
      shiftKey: false,
      preventDefault: function () {
        return true;
      }
    };
    return this.handleKeyDown(message);
  }

  fireUndo = (e) => {
    e.preventDefault();
    var ta = document.getElementById("composer-text");
    ta.focus();
    var message = {
      target: ta,
      keyCode: 90,
      key: "z",
      metaKey: true,
      shiftKey: false,
      preventDefault: function () {
        return true;
      }
    };
    return this.handleKeyDown(message);
  }

  fireRedo = (e) => {
    e.preventDefault();
    var ta = document.getElementById("composer-text");
    ta.focus();
    var message = {
      target: ta,
      keyCode: 90,
      key: "z",
      metaKey: true,
      shiftKey: true,
      preventDefault: function () {
        return true;
      }
    };
    return this.handleKeyDown(message);
  }

  showPreview = (e) => {
    e.preventDefault();
    this.setState({...this.state, preview: true});
  }

  showEdit = (e) => {
    e.preventDefault();
    this.setState({...this.state, preview: false});
  }

  renderPreview() {
    var html = this.state.markdown;
    // bold
    html = html.replace(/__(.*?)__/g, "<strong>$1</strong>");
    // italic
    html = html.replace(/_(.*?)_/g, "<em>$1</em>");
    // strikethrough
    html = html.replace(/~~(.*?)~~/g, "<span style=\"text-decoration:line-through\">$1</span>");
    // link
    html = html.replace(/\[(.*?)\]\((.*?)\)/g, "<a href=\"$2\">$1</a>");
    // line breaks
    html = html.replace(/  \n/g,"</ br>");
    // paragraphs
    html = html.replace(/^(.*?\S\S)$/g,"<p>$1</p>\n");
    html = html.replace(/\n(.*?\S\S)$/g,"<p>$1</p>\n");
    html = html.replace(/^(.*?\S\S)\n/g,"<p>$1</p>\n");
    html = html.replace(/\n(.*?\S\S)\n/g,"<p>$1</p>\n");
    // headers
    html = html.replace(/<p>###### *?(.*?)<\/p>/g,"<h6>$1</h6>");
    html = html.replace(/<p>##### *?(.*?)<\/p>/g,"<h5>$1</h5>");
    html = html.replace(/<p>#### *?(.*?)<\/p>/g,"<h4>$1</h4>");
    html = html.replace(/<p>### *?(.*?)<\/p>/g,"<h3>$1</h3>");
    html = html.replace(/<p>## *?(.*?)<\/p>/g,"<h2>$1</h2>");
    html = html.replace(/<p># *?(.*?)<\/p>/g,"<h1>$1</h1>");
    // block quotes
    // monospace
    return <div dangerouslySetInnerHTML={{__html: html}}></div>;
  }

  render() {
    const previewClass = this.state.preview
                       ? "composer-wrapper composer-preview-preview"
                       : "composer-wrapper composer-preview-edit";
    return (
      <div className={previewClass}>
        <label htmlFor="composer-text">Message Body</label>
        <div id="composer-edit">
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
            <button
              className="composer-toolbar-button composer-toolbar-bold"
              onClick={this.fireBold}
            >B</button>
            <button
              className="composer-toolbar-button composer-toolbar-italic"
              onClick={this.fireItalic}
            >I</button>
            <button
              className="composer-toolbar-button composer-toolbar-strikethrough"
              onClick={this.fireStrikethrough}
            >S</button>
            <button
              className="composer-toolbar-button composer-toolbar-link"
              onClick={this.fireLink}
            >🔗</button>
            <button
              className="composer-toolbar-button composer-toolbar-undo"
              onClick={this.fireUndo}
            >↺</button>
            <button
              className="composer-toolbar-button composer-toolbar-redo"
              onClick={this.fireRedo}
            >↻</button>
          </div>
          <textarea
            value={this.state.markdown}
            className="composer-text"
            id="composer-text"
            name="composer-text"
            onKeyDown={this.handleKeyDown}
          />
        </div>
        <div id="composer-preview">
          {this.renderPreview()}
        </div>
        <div className="composer-preview-toggle">
          <button
            className={`composer-preview-edit ${this.state.preview ? "not-active" : "active"}`}
            onClick={this.showEdit}
          >Edit</button>
          <button
            className={`composer-preview-preview ${this.state.preview ? "active" : "not-active"}`}
            onClick={this.showPreview}
          >Preview</button>
        </div>
      </div>
    );
  }
}

export default Composer;