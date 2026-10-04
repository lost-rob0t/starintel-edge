// Independent Node process: actual SDK lossless parser, validator and codec.
const fs = require('node:fs');
const sdk = require(process.env.INTEROP_JS_SDK + '/src/canonical.js');
for (const line of fs.readFileSync(0, 'utf8').trimEnd().split('\n')) {
  const value = sdk.parseJson(line);
  let result;
  try {
    result = process.argv[2] === 'emit' ? value : sdk.roundtrip(value);
    if (process.argv[2] === 'reject') result = {accepted: true};
  } catch (error) {
    if (process.argv[2] !== 'reject' || error.name !== 'StarIntelValidationError') throw error;
    result = {accepted: false, error: error.message};
  }
  console.log(sdk.stringifyJson(result));
}
