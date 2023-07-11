import React from 'react';
import './ComposeOverlay.css';
import Preview from './Preview';
const STATE_KEY = 'composer-state';
const BODY_TEXT = 'Body Text';
const H1 = 'Header Level 1';
const H2 = 'Header Level 2';
const H3 = 'Header Level 3';
const H4 = 'Header Level 4';
const H5 = 'Header Level 5';
const H6 = 'Header Level 6';
const PRE = 'Monospace';
const BLOCK_QUOTE = 'Block Quote';
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
    this.state = JSON.parse(localStorage.getItem(STATE_KEY)) || {
      markdown: "",
      history: [""],
      history_index: 0,
      style: BODY_TEXT,
      preview: false
    };
  }

  setState(state) {
    console.log("Setting state");
    console.log(state.markdown);
    try {
      localStorage.setItem(STATE_KEY, JSON.stringify(state));
    } catch (e) {
      console.log(e);
    }
    super.setState(state);
  }

  historyPush(md) {
    var history = this.state.history.slice(0, this.state.history_index + 1);
    history.push(md);
    this.setState({
      ...this.state,
      markdown: md,
      history: history,
      history_index: this.state.history_index + 1
    });
  }

  historyReplace(md) {
    var history = this.state.history.slice(0, this.state.history_index + 1);
    history[this.state.history_index] = md;
    this.setState({
      ...this.state,
      markdown: md,
      history: history
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
      markdown: this.state.history[newIndex]
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
      markdown: this.state.history[newIndex]
    });
    return this.state.markdown;
  }

  handleKeyDown = (e) => {
    // TODO: 
    // - delete key
    // - delete and backspace with opt, ctl, and cmd
    // Update style dropdown as cursor lands in new line
    // if (e.keyCode < 48 || e.keyCode > 90) {
    //   console.log(e);
    // }
    var markdown = this.state.markdown;
    var newMarkdown = markdown;
    var start = e.target.selectionStart;
    var end = e.target.selectionEnd;
    var newCursorStart = start + 1;
    var newCursorEnd = end + 1;
    if ((e.keyCode >= 37 && e.keyCode <= 40)
        || (e.keyCode >= 16 && e.keyCode <= 18)
        || (e.keyCode === 91)
        || (e.keyCode === 92)) {
      // These keys don't alter the content
      console.log(e.keyCode);
      setTimeout(() => {
        var start = e.target.selectionStart;
        this.setStyle(markdown, start);
      }, 50);
      return;
    } else if (e.keyCode === 8) { // backspace
      e.preventDefault();
      newMarkdown = markdown.substring(0, start - 1) + markdown.substring(end);
      newCursorStart = start - 1;
      newCursorEnd = end - 1;
      this.historyReplace(newMarkdown);
    } else if (e.keyCode === 9) { // tab
      e.preventDefault();
      newMarkdown = markdown.substring(0, start) + "\t" + markdown.substring(end);
      this.historyReplace(newMarkdown);
    } else if (e.keyCode === 13) { // enter
      e.preventDefault();
      newMarkdown = markdown.substring(0, start) + "\n" + markdown.substring(end);
      this.historyReplace(newMarkdown);
    } else if (e.keyCode === 32) { // space
      e.preventDefault();
      newMarkdown = markdown.substring(0, start) + " " + markdown.substring(end);
      this.historyReplace(newMarkdown);
    } else {// normal letters, digits, and symbols
      if (e.metaKey) { // check for keyboard shortcuts
        switch (e.keyCode) {
          case 66: // b
            // TODO: toggle on/off
            e.preventDefault();
            newMarkdown = markdown.substring(0, start) + '__' + markdown.substring(start, end) + '__' + markdown.substring(end);
            newCursorStart = start + 2;
            newCursorEnd = end + 2;
            this.historyPush(newMarkdown);
            break;
          case 73: // i
            // TODO: toggle on/off
            e.preventDefault();
            newMarkdown = markdown.substring(0, start) + '_' + markdown.substring(start, end) + '_' + markdown.substring(end);
            this.historyPush(newMarkdown);
            break;
          case 75: // k
            e.preventDefault();
            newMarkdown = markdown.substring(0, start) + '[' + markdown.substring(start, end) + '](https://example.com)' + markdown.substring(end);
            this.historyPush(newMarkdown);
            break;
          case 83: // s
            // TODO: toggle on/off
            e.preventDefault();
            newMarkdown = markdown.substring(0, start) + '~~' + markdown.substring(start, end) + '~~' + markdown.substring(end);
            newCursorStart = start + 2;
            newCursorEnd = end + 2;
            this.historyPush(newMarkdown);
            break;
          case 90: // z
            e.preventDefault();
            if (e.shiftKey) {
              newMarkdown = this.historyRedo();
            } else {
              newMarkdown = this.historyUndo();
            }
            break;
          default:
            break;
        }
      } else {
        e.preventDefault();
        newMarkdown = markdown.substring(0, start) + e.key + markdown.substring(end);
        this.historyReplace(newMarkdown);
      }
    }
    e.target.value = newMarkdown;
    e.target.selectionStart = newCursorStart;
    e.target.selectionEnd = newCursorEnd;
    setTimeout(() => {
      this.setStyle(newMarkdown, newCursorStart);
    }, 500);
  }

  setStyle(md, cs) {
    var paragraphs = md.substring(0, cs).split("\n");
    var lastParagraph = paragraphs[paragraphs.length - 1];
    if (lastParagraph === "" || lastParagraph === null) {
      this.setState({...this.state,style:BODY_TEXT});
    } else if (lastParagraph.match(/^###### /)) {
      this.setState({...this.state,style:H6});
    } else if (lastParagraph.match(/^##### /)) {
      this.setState({...this.state,style:H5});
    } else if (lastParagraph.match(/^#### /)) {
      this.setState({...this.state,markdown:md,style:H4});
    } else if (lastParagraph.match(/^### /)) {
      this.setState({...this.state,style:H3});
    } else if (lastParagraph.match(/^## /)) {
      this.setState({...this.state,style:H2});
    } else if (lastParagraph.match(/^# /)) {
      this.setState({...this.state,style:H1});
    } else if (lastParagraph.match(/^> /)) {
      this.setState({...this.state,style:BLOCK_QUOTE});
    } else if (lastParagraph.match(/^ {4}/)) {
      this.setState({...this.state,style:PRE});
    } else {
      this.setState({...this.state,style:BODY_TEXT});
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

  render() {
    const previewClass = this.state.preview
                       ? "composer-wrapper composer-preview-preview"
                       : "composer-wrapper composer-preview-edit";
    return (
      <div className={previewClass}>
        <label htmlFor="composer-text">Message Body</label>
        <div id="composer-edit">
          <div className="composer-toolbar">
            <select
              id="composer-toolbar-style-select"
              className="composer-toolbar-style-select"
              value={this.state.style}
            >
              <option value={BODY_TEXT}>{BODY_TEXT}</option>
              <option value={H1}>{H1}</option>
              <option value={H2}>{H2}</option>
              <option value={H3}>{H3}</option>
              <option value={H4}>{H4}</option>
              <option value={H5}>{H5}</option>
              <option value={H6}>{H6}</option>
              <option value={BLOCK_QUOTE}>{BLOCK_QUOTE}</option>
              <option value={PRE}>{PRE}</option>
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
            defaultValue={this.state.markdown}
            className="composer-text"
            id="composer-text"
            name="composer-text"
            onKeyDown={this.handleKeyDown}
            onFocus={this.setStyle}
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