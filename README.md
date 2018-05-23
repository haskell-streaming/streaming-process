streaming-process
=================

[![Hackage](https://img.shields.io/hackage/v/streaming-process.svg)](https://hackage.haskell.org/package/streaming-process) [![Build Status](https://travis-ci.org/haskell-streaming/streaming-process.svg)](https://travis-ci.org/haskell-streaming/streaming-process)

Run a process, streaming data in or out.

A lot of configuration options are available to fine-tune which inputs
and outputs are streamed.

This uses [streaming-with] to handle resource management, and
[streaming-concurrency] for handling both `stdout` and `stderr`
together.

As such, code is typically run in a continuation-passing-style.  You
may wish to use the `Streaming.Process.Lifted` module if you have many
of these nested.

[streaming-with]: http://hackage.haskell.org/package/streaming-with
[streaming-concurrency]: http://hackage.haskell.org/package/streaming-concurrency

Exceptions
----------

The functions in this library will all throw
`ProcessExitedUnsuccessfully` if the process/command itself fails.

WARNING
-------

If using this module, you will need to have:

```cabal
ghc-options -threaded
```

in the executable section of your `.cabal` file, otherwise your code
will likely hang!
