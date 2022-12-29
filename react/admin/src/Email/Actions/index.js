import React from 'react';
import ApiClient from '../../ApiClient';
import './Actions.css';

class Actions extends React.Component {

  constructor(props) {
    super(props);
    this.api = new ApiClient(this.props.api_url, this.props.token, this.props.host);
  }

  handleActionButtonClick = (e) => {
    e.stopPropagation();
    if (!this.props.selected_messages.length && !this.props.selected_message) {
      this.props.setMessage("Please select at least one message first.", true);
      return;
    } 
    var action = e.target.id;
    if (e.target.tagName !== 'BUTTON') {
      action = e.target.parentElement.id;
    }
    switch (action) {
      case "delete":
        this.api.moveMessages(
          this.props.folder,
          "Deleted Items",
          this.props.selected_messages,
          this.props.order,
          this.props.field
        );
        break;
      case "move":
        this.props.setMessage("Moving messages isn't implamented yet.", true);
        break;
      case READ.css:
        this.api.setFlag(
          this.props.folder,
          READ.imap,
          READ.op,
          this.props.selected_messages,
          this.props.order,
          this.props.field
        ).then(this.props.callback).catch(this.props.catchback);
        break;
      case UNREAD.css:
        this.api.setFlag(
          this.props.folder,
          UNREAD.imap,
          UNREAD.op,
          this.props.selected_messages,
          this.props.order,
          this.props.field
        ).then(this.props.callback).catch(this.props.catchback);
        break;
      case FLAGGED.css:
        this.api.setFlag(
          this.props.folder,
          FLAGGED.imap,
          FLAGGED.op,
          this.props.selected_messages,
          this.props.order,
          this.props.field
        ).then(this.props.callback).catch(this.props.catchback);
        break;
      case UNFLAGGED.css:
        this.api.setFlag(
          this.props.folder,
          UNFLAGGED.imap,
          UNFLAGGED.op,
          this.props.selected_messages,
          this.props.order,
          this.props.field
        ).then(this.props.callback).catch(this.props.catchback);
        break;
      default:
        console.log(`"${action}" clicked`);
    }
  }

  render() {
    return (
      <div className={`filters filters-buttons ${selected}`}>
        <span className="filter filter-actions">
          <button
            value="delete"
            id="delete"
            name="delete"
            className="action delete"
            title="Delete"
            onClick={this.handleActionButtonClick}
          >🗑️<span className="wide-screen"> Delete</span></button>
          <button
            value="move"
            id="move"
            name="move"
            className="action move"
            title="Move to..."
            onClick={this.handleActionButtonClick}
          >📨<span className="wide-screen"> Move to...</span></button>
          <button
            value={READ.css}
            id={READ.css}
            name={READ.css}
            className={`action ${READ.css}`}
            title={READ.description}
            onClick={this.handleActionButtonClick}
          >{READ.icon}<span className="wide-screen"> {READ.description}</span></button>
          <button
            value={UNREAD.css}
            id={UNREAD.css}
            name={UNREAD.css}
            className={`action ${UNREAD.css}`}
            title={UNREAD.description}
            onClick={this.handleActionButtonClick}
          >{UNREAD.icon}<span className="wide-screen"> {UNREAD.description}</span></button>
          <button
            value={FLAGGED.css}
            id={FLAGGED.css}
            name={FLAGGED.css}
            className={`action ${FLAGGED.css}`}
            title={FLAGGED.description}
            onClick={this.handleActionButtonClick}
          >{FLAGGED.icon}<span className="wide-screen"> {FLAGGED.description}</span></button>
            <button
            value={UNFLAGGED.css}
            id={UNFLAGGED.css}
            name={UNFLAGGED.css}
            className={`action ${UNFLAGGED.css}`}
            title={UNFLAGGED.description}
            onClick={this.handleActionButtonClick}
          >{UNFLAGGED.icon}<span className="wide-screen"> {UNFLAGGED.description}</span></button>
        </span>
      </div>
    );
  }
}

export default Actions;