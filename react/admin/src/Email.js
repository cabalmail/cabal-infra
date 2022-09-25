import React from 'react';
import ImapClient from 'emailjs-imap-client'
import './Email.css';

class Email extends React.Component {

  constructor(props) {
    super(props);
    this.state = {
      label: "INBOX"
    };
  }

  componentDidMount() {
    // const response = this.getList();
    // response.then(data => {
    //   this.setState({ addresses: data.data.Items.sort(
    //     (a,b) => {
    //       if (a.address > b.address) {
    //         return 1;
    //       } else if (a.address < b.address) {
    //         return -1;
    //       }
    //       return 0;
    //     }
    //   ) });
    // });
  }

  render() {
    return <div>Email</div>;
  }
}

export default Email;