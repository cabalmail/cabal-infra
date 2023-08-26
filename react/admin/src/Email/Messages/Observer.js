import React from 'react';
import { InView } from 'react-intersection-observer';

const Observer = (props) => {
  const onChange = (inView, entry) => {
    props.pageLoader([props.page]);
  }
  return (
    <InView
      onChange={onChange}
      triggerOnce={false}
    >{({ inView, ref, entry }) => (
      <div ref={ref}></div>
    )}</InView>
  );
}

export default Observer;