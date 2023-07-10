import React from 'react';
import './ComposeOverlay.css';
import Preview from './Preview';
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
  // - Monospace

  constructor(props) {
    super(props);
    this.scroll = 0;
    this.state = JSON.parse(localStorage.getItem(STATE_KEY)) || {
      markdown: "",
      history: [""],
      history_index: 0,
      preview: false,
      cursorStart: 0,
      cursorEnd: 0,
      state_changed_by_keystroke: false
    };
  }

  setState(state) {
    try {
      localStorage.setItem(STATE_KEY, JSON.stringify(state));
    } catch (e) {
      console.log(e);
    }
    super.setState(state);
  }

  shouldComponentUpdate(_nextProps, nextState) {
    return ! nextState.state_changed_by_keystroke;
  }

  componentDidUpdate(prevProps, prevState) {
    if (prevState.cursorStart !== this.state.cursorStart
        || prevState.cursorEnd !== this.state.cursorEnd) {
      setTimeout(() => {
        const ta = document.getElementById("composer-text");
        ta.selectionStart = this.state.cursorStart;
        ta.selectionEnd = this.state.cursorEnd;
        if (ta.value.length < this.state.cursorEnd + 60) {
          // Cursor is near the bottom of the textarea
          ta.scrollTop = 999999999;
        } else {
          ta.scrollTop =  this.scroll;
        }
      }, 20);
    }
  }

  historyPush(md, cs, ce) {
    var history = this.state.history.slice(0, this.state.history_index + 1);
    history.push(md);
    this.setState({
      ...this.state,
      markdown: md,
      history: history,
      history_index: this.state.history_index + 1,
      cursorStart: cs,
      cursorEnd: ce,
      state_changed_by_keystroke: true
    });
  }

  historyReplace(md, cs, ce) {
    var history = this.state.history.slice(0, this.state.history_index + 1);
    history[this.state.history_index] = md;
    this.setState({
      ...this.state,
      markdown: md,
      history: history,
      cursorStart: cs,
      cursorEnd: ce,
      state_changed_by_keystroke: true
    });
  }

  historyUndo() {
    if (this.state.history_index <= 0) {
      return this.state.markdown;
    }
    var newIndex = this.state.history_index - 1;
    this.setState({
      ...this.state,
      history_index: newIndex,
      markdown: this.state.history[newIndex],
      state_changed_by_keystroke: true
    });
    return this.state.markdown;
  }

  historyRedo() {
    if (this.state.history_index + 1 > this.state.history.length) {
      return this.state.markdown;
    }
    var newIndex = this.state.history_index + 1;
    this.setState({
      ...this.state,
      history_index: newIndex,
      markdown: this.state.history[newIndex],
      state_changed_by_keystroke: true
    });
    return this.state.markdown;
  }

  handleChange = (e) => {
    this.setState({
      ...this.state,
      markdown: e.target.value,
      state_changed_by_keystroke: false
    });
  }

  handleKeyDown = (e) => {
    // if (e.keyCode < 48 || e.keyCode > 90) {
    //   console.log(e);
    // }
    var markdown = this.state.markdown;
    var newMarkdown = markdown;
    var start = e.target.selectionStart;
    var end = e.target.selectionEnd;
    var newCursorStart = start;
    var newCursorEnd = end;
    this.scroll = e.target.scrollTop;
    switch (e.keyCode) {
      // TODO: 
      // - delete key
      // - delete and backspace with opt, ctl, and cmd
      // Update style dropdown as cursor lands in new line
      case 8: // backspace
        e.preventDefault();
        newMarkdown = markdown.substring(0, start - 1) + markdown.substring(end);
        newCursorStart = start - 1;
        newCursorEnd = start - 1;
        this.historyReplace(newMarkdown, newCursorStart, newCursorEnd);
        break;
      case 9: // tab
        e.preventDefault();
        newMarkdown = markdown.substring(0, start) + "\t" + markdown.substring(end);
        newCursorStart = start + 1;
        newCursorEnd = start + 1;
        this.historyPush(newMarkdown, newCursorStart, newCursorEnd);
        break;
      case 13: // enter
        e.preventDefault();
        newMarkdown = markdown.substring(0, start) + "\n" + markdown.substring(end);
        newCursorStart = start + 1;
        newCursorEnd = start + 1;
        this.historyPush(newMarkdown, newCursorStart, newCursorEnd);
        break;
      case 16: // shift
        break;
      case 17: // control
        break;
      case 18: // alt/option
        break;
      case 32: // space
        e.preventDefault();
        newMarkdown = markdown.substring(0, start) + " " + markdown.substring(end);
        newCursorStart = start + 1;
        newCursorEnd = start + 1;
        this.historyPush(newMarkdown, newCursorStart, newCursorEnd);
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
        return;
      default: // normal letters, digits, and symbols
        if (e.metaKey) { // check for keyboard shortcuts
          switch (e.keyCode) {
            case 66: // b
              // TODO: toggle on/off
              e.preventDefault();
              newMarkdown = markdown.substring(0, start) + '__' + markdown.substring(start, end) + '__' + markdown.substring(end);
              newCursorStart = start + 2;
              newCursorEnd = end + 2;
              this.historyPush(newMarkdown, newCursorStart, newCursorEnd);
              break;
            case 73: // i
              // TODO: toggle on/off
              e.preventDefault();
              newMarkdown = markdown.substring(0, start) + '_' + markdown.substring(start, end) + '_' + markdown.substring(end);
              newCursorStart = start + 1;
              newCursorEnd = end + 1;
              this.historyPush(newMarkdown, newCursorStart, newCursorEnd);
              break;
            case 75: // k
              e.preventDefault();
              newMarkdown = markdown.substring(0, start) + '[' + markdown.substring(start, end) + '](https://example.com)' + markdown.substring(end);
              newCursorStart = start + 1;
              newCursorEnd = end + 1;
              this.historyPush(newMarkdown, newCursorStart, newCursorEnd);
              break;
            case 83: // s
              // TODO: toggle on/off
              e.preventDefault();
              newMarkdown = markdown.substring(0, start) + '~~' + markdown.substring(start, end) + '~~' + markdown.substring(end);
              newCursorStart = start + 2;
              newCursorEnd = end + 2;
              this.historyPush(newMarkdown, newCursorStart, newCursorEnd);
              break;
            case 90: // z
              e.preventDefault();
              if (e.shiftKey) {
                this.historyRedo();
              } else {
                this.historyUndo();
              }
              break;
            default:
              break;
          }
        } else {
          e.preventDefault();
          newMarkdown = markdown.substring(0, start) + e.key + markdown.substring(end);
          newCursorStart = start + 1;
          newCursorEnd = start + 1;
          this.historyReplace(newMarkdown, newCursorStart, newCursorEnd);
        }
        break;
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
    this.setState({...this.state, preview: true, set_by_keystroke: false});
  }

  showEdit = (e) => {
    e.preventDefault();
    this.setState({...this.state, preview: false, set_by_keystroke: false});
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
            onChange={this.handleChange}
          />
        </div>
        <div id="composer-preview">
          <Preview markdown={this.state.markdown} />
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