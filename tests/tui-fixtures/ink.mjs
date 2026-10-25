import React, { useState } from 'react';
import { render, Text, useInput, useApp } from 'ink';

function Fixture() {
  const [text, setText] = useState('VERTEX_FRAMEWORK_READY');
  const { exit } = useApp();
  useInput((input, key) => {
    if (input === 'q' || (key.ctrl && input === 'c')) exit();
    else setText(`VERTEX_FRAMEWORK_INPUT ${input}`);
  });
  return React.createElement(Text, { color: '#5599ff', underline: true }, `${text}\n界 é 👩‍💻`);
}
render(React.createElement(Fixture));
