import React from 'react';
import './Email.css';

class Email extends React.Component {

  constructor(props) {
    super(props);
    this.state = {
      filter: "",
      addresses: []
    };
  }

  render() {
    return <div>Email</div>;
  }
}

export default Email;