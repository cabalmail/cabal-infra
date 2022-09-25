import React from 'react';
import './Email.css';

class Email extends React.Component {

  constructor(props) {
    super(props);
    this.state = {
      label: "INBOX"
    };
  }

  render() {
    return <div>Email</div>;
  }
}

export default Email;