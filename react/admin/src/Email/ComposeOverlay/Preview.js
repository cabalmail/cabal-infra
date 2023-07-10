import React from 'react';
import './ComposeOverlay.css';
import DOMPurify from 'dompurify';
// const STATE_KEY = 'preview-state';

class Preview extends React.Component {
  render() {
    var html = DOMPurify.sanitize(this.props.markdown);
    // bold
    html = html.replace(/__(.*?)__/g, "<strong>$1</strong>");
    // italic
    html = html.replace(/_(.*?)_/g, "<em>$1</em>");
    // strikethrough
    html = html.replace(/~~(.*?)~~/g, "<span style=\"text-decoration:line-through\">$1</span>");
    // link
    html = html.replace(/\[(.*?)\]\((.*?)\)/g, "<a href=\"$2\">$1</a>");
    // paragraphs
    html = `<p>${html}</p>`;
    html = html.replace(/\n/g,"</p><p>");
    // headers
    html = html.replace(/<p>###### *(.*?)<\/p>/g,"<h6>$1</h6>");
    html = html.replace(/<p>##### *(.*?)<\/p>/g,"<h5>$1</h5>");
    html = html.replace(/<p>#### *(.*?)<\/p>/g,"<h4>$1</h4>");
    html = html.replace(/<p>### *(.*?)<\/p>/g,"<h3>$1</h3>");
    html = html.replace(/<p>## *(.*?)<\/p>/g,"<h2>$1</h2>");
    html = html.replace(/<p># *(.*?)<\/p>/g,"<h1>$1</h1>");
    // block quotes
    html = html.replace(/<p>> *?(.*?)<\/p>/g,"<h1>$1</h1>");
    // monospace
    html = html.replace(/<p> {4}(.*?)<\/p>/g,"<pre>$1</pre>");
    html = html.replace(/<\/pre><pre>/g,"\n");
    html = html.split("<pre>").map(s => {
      return s.replaceAll(/&(?=[^]*?<\/pre>)/g, "&amp;")
              .replaceAll(/<(?=[^]*?<\/pre>)/g, "&lt;")
              .replaceAll(/>(?=[^]*?<\/pre>)/g, "&gt;");
    }).join("<pre>");
    return <div dangerouslySetInnerHTML={{__html: html}}></div>;
  }
}

export default Preview;