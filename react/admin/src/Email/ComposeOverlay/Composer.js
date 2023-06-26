import React from 'react';

class Composer extends React.Component {

  // constructor(props) {
  //   super(props);
  //   this.state = {};
  // }

  render() {
    return (
      <div className="composer-wrapper">
        <textarea className="composer-text">{this.props.quotedText}</textarea>
      </div>
    );
  }
}

export default Composer;