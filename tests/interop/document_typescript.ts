// Compiled TypeScript consumer/producer using the actual SDK declaration surface.
// SDK_MODULE is replaced with the explicit verified SDK path by the test runner.
import * as sdk from 'SDK_MODULE';
import type { Person } from 'SDK_MODULE';
declare function require(name: string): {readFileSync(fd: number, encoding: string): string};
declare const process: {argv: string[]};
const fs = require('node:fs');
// Compile-time smoke for absence and false in the canonical generated contract.
const typedFixture: Person = {id: 'fixture:typescript', dataset: 'interop-synthetic', dtype: 'person', schemaVersion: '0.10.1', deleted: false};
sdk.assertDocument(typedFixture);
for (const line of fs.readFileSync(0, 'utf8').trimEnd().split('\n')) {
  const value: unknown = sdk.parseJson(line);
  let result: unknown;
  try {
    result = process.argv[2] === 'emit' ? value : sdk.roundtrip(value);
    if (process.argv[2] === 'reject') result = {accepted: true};
  } catch (error) {
    if (process.argv[2] !== 'reject' || !(error instanceof Error) || error.name !== 'StarIntelValidationError') throw error;
    result = {accepted: false, error: String(error)};
  }
  console.log(sdk.stringifyJson(result));
}
