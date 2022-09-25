import React from 'react';
import ImapClient from 'emailjs-imap-client'
import './Email.css';

class Email extends React.Component {

  constructor(props) {
    super(props);
    this.state = {
      label: "INBOX",
      mailboxes: {}
    };
    this.imap = new ImapClient(
      "imap." + this.props.control_domain,
      993,
      {
        auth: {
          user: this.props.userName,
          pass: this.props.password
        },
        useSecureTransport: true
      }
    );
  }

  getMailboxes() {
    this.imap.listMailboxes
    .then((mailboxes) => {
      this.setState({ mailboxes: mailboxes });
      console.log(mailboxes);
    })
    .catch((e) => {
      console.log("Couldn't get mailboxes.");
      console.log(e);
    });
  }

  componentDidMount() {
    this.imap.connect()
    .then(() => {
      getMailboxes();
    })
    .catch((e) => {
      console.log("Couldn't connect or authorize.");
      console.log(e);
    });
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