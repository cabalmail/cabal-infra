import React from 'react';

class Composer extends React.Component {

  constructor(props) {
    super(props);
    this.state = {
      text = ""
    };
  }

  onChange = (e) => {
    e.preventDefault();
    this.setState({text: e.target.value});
  }

  render() {
    return (
      <div className="composer-wrapper">
        <textarea
          rows=40
          cols=120
          value={this.state.text}
          defaultValue={this.props.quotedText}
          className="composer-text"
          onChange={this.onChange}
        />
      </div>
    );
  }
}

export default Composer;