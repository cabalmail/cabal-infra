import React from 'react';
import List from './List';
import Request from './Request';

class Addresses extends React.Component {

  render() {
    return (
      <>
        <Request 
          token={this.props.token}
          password={this.props.password}
          userName={this.props.userName}
          api_url={this.props.api_url}
          setMessage={this.props.setMessage}
        />
        <List 
          token={this.props.token}
          password={this.props.password}
          userName={this.props.userName}
          api_url={this.props.api_url}
          setMessage={this.props.setMessage}
        />
      </>
    );
  }
}

export default Addresses;