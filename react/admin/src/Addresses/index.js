import React from 'react';
import List from './List';
import Request from './Request';
import './Addresses.css'

class Addresses extends React.Component {

  constructor(props) {
    super(props);
    this.state = {
      showRequest: false
    };
  }

  toggleRequest = () => {
    this.setState({...this.state, showRequest: !this.state.showRequest})
  }

  render() {
    return (
      <>
        <button
          onClick={this.toggleRequest}
          className="toggleRequest"
        >New Address {this.state.showRequest ? "∨" : ">"}</button>
        <Request
          token={this.props.token}
          domains={this.props.domains}
          api_url={this.props.api_url}
          setMessage={this.props.setMessage}
          showRequest={this.state.showRequest}
          host={this.props.host}
        />
        <hr />
        <List
          token={this.props.token}
          domains={this.props.domains}
          api_url={this.props.api_url}
          setMessage={this.props.setMessage}
          host={this.props.host}
        />
      </>
    );
  }
}

export default Addresses;