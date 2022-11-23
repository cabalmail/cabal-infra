import React from 'react';
import List from './List';
import Request from './Request';

class Addresses extends React.Component {

  constructor(props) {
    super(props);
    this.state = {
      showRequest: false
    };
  }

  toggleRequest() {
    this.setState({showRequest: !this.state.showRequest})
  }

  render() {
    return (
      <>
        <button onClick={this.toggleRequest}>+</button>
        <Request 
          className={`request ${this.state.showRequest ? "visible" : "hidden"}`}
          token={this.props.token}
          password={this.props.password}
          userName={this.props.userName}
          domains={this.props.domains}
          api_url={this.props.api_url}
          setMessage={this.props.setMessage}
        />
        <hr />
        <List 
          token={this.props.token}
          password={this.props.password}
          userName={this.props.userName}
          domains={this.props.domains}
          api_url={this.props.api_url}
          setMessage={this.props.setMessage}
        />
      </>
    );
  }
}

export default Addresses;