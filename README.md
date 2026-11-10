# GNU Coreutils for FreeBASIC

This repository contains an experimental FreeBASIC port of GNU Coreutils 9.12.
It keeps the translated FreeBASIC candidate sources, ABI support, converter,
and regression tests. Coreutils' original implementation sources are not
included. The upstream test suites are retained in `tests/` and
`gnulib-tests/`.

The checked-in files under `fb_port/generated-context/` are the current
production translation set: 498 FreeBASIC source candidates and their type
includes, plus a portable source map. They are generated from Coreutils C with
C2FB, but are useful project source and audit inputs, so they are versioned.
Older experimental outputs and build logs are not part of the repository.

This is still a hybrid port. The generated FreeBASIC objects replace selected
Coreutils objects, while the tested command set links against Coreutils C
support libraries. It is not yet a standalone, all-FreeBASIC replacement for
GNU Coreutils. See [the port status](fb_port/STATUS.md) for the last recorded
audit and test results.

## Build and verify

Install Python 3, GNU Make, GCC, and FreeBASIC. Keep a separate GNU Coreutils
9.12 source checkout available for the reference build and test harness:

```sh
export COREUTILS_SOURCE=/path/to/coreutils-9.12
export COREUTILS_FBC=/path/to/fbc

python3 fb_port/port.py reference --jobs=8
python3 fb_port/port.py reference-tests --jobs=8
python3 fb_port/port.py translate --contexts --jobs=8
python3 fb_port/port.py audit --contexts
python3 fb_port/check.py
```

The converter source is vendored under `fb_port/tools/c2fb`; the driver builds
it when needed. `COREUTILS_C2FB_TOOLS` can select another C2FB checkout.
`COREUTILS_FBC_SOURCE` is only needed for `python3 fb_port/port.py compiler`,
which builds an isolated FreeBASIC compiler. Set `COREUTILS_FBC_INCLUDE` or
`COREUTILS_FBC_RUNTIME_LIBDIR` if your FreeBASIC installation uses nonstandard
paths.

See [fb_port/README](fb_port/README) for workflow details. Generated build
files, logs, and temporary audit outputs are written under `fb_port/build/`
and `fb_port/logs/`.

## Licensing and attribution

The Coreutils-derived work and retained upstream tests are covered by the GNU
General Public License, version 3 or later; see [COPYING](COPYING). The
vendored C2FB converter carries its own copy of the same license under
`fb_port/tools/c2fb/LICENSE`.
