NPM package
===========

This repository can be published to npm. The package publishes the built web assets under the `dist/` directory.

To build, pack and inspect locally:

    $ make dist
    $ npm pack

To publish:

    $ npm publish

Notes:
- The package's `prepare` script runs `make dist` so that `npm pack` and `npm publish` include the built files.
- The `dist/` directory contains `octave.js`, `octave.wasm` and the example `index.html`.
