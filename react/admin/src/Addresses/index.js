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

  toggleRequest = () => {
    this.setState({showRequest: !this.state.showRequest})
  }

  render() {
    return (
      <>
        <button onClick={this.toggleRequest}>+ {this.state.showRequest ? ">" : "∨"}</button>
        <Request
          token={this.props.token}
          password={this.props.password}
          userName={this.props.userName}
          domains={this.props.domains}
          api_url={this.props.api_url}
          setMessage={this.props.setMessage}
          showRequest={this.state.showRequest}
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