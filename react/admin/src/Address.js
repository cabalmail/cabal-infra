import React from 'react';

class Address extends React.Component {

  copy = () => {
    navigator.clipboard.writeText(this.props.address);
    this.props.setMessage(`The address ${this.props.address} has been copied to your clipboard.`);
  }

  render() {
    return (
      <li
        className="address"
        onClick={this.copy}
      >{this.props.address}</li>
    );
  }

}

export default Address;