import React from 'react';

class Request extends React.Component {
  render() {
    return (
      <div className="request">
        <h1>Request</h1>
        <div>{this.props.userName}</div>
        <div>{this.props.token}</div>
      </div>
      );
  }
}

export default Request;