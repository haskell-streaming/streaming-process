{-# LANGUAGE FlexibleContexts, MultiParamTypeClasses, TypeFamilies #-}

{- |
   Module      : Streaming.Process.Lifted
   Description : Lifted variants of "Streaming.Process"
   Copyright   : (c) Ivan Lazar Miljenovic
   License     : MIT
   Maintainer  : Ivan.Miljenovic@gmail.com

   This module defines variants of those in "Streaming.Process" for
   use with the 'Withable' class, found in the @streaming-with@
   package.

   __WARNING:__ If using this module, you will need to have
   @ghc-options -threaded@ in your @.cabal@ file otherwise it will
   likely hang!

   These functions will all throw 'ProcessExitedUnsuccessfully' if the
   process\/command itself fails.

 -}
module Streaming.Process.Lifted
  ( -- * High level functions
    withStreamingProcess
  , withStreamingCommand
  , streamInput
  , streamInputCommand
  , withStreamingOutput
  , withStreamingOutputCommand
    -- * Lower level
  , StreamProcess(..)
  , switchOutputs
  , WithStream
  , WithStream'
  , withStream
  , SupplyStream
  , supplyStream
  , withStreamProcess
  , withStreamCommand
  , withProcessHandles
  , processInput
  , withProcessOutput
    -- * Interleaved stdout and stderr
  , StdOutErr
  , withStreamOutputs
    -- * Re-exports
    -- $reexports
  , module Data.Streaming.Process
  , concurrently
  ) where

import           Streaming.Process (StdOutErr, StreamProcess(..), SupplyStream,
                                    WithStream, WithStream', switchOutputs)
import qualified Streaming.Process as SP

import Data.ByteString.Streaming (ByteString)
import Streaming.With.Lifted     (Withable(..))

import Control.Concurrent.Async.Lifted (concurrently)
import Control.Monad.Base              (MonadBase)
import Control.Monad.IO.Class          (MonadIO)
import Control.Monad.Trans.Control     (MonadBaseControl)
import Data.Streaming.Process
import System.Process                  (shell)

--------------------------------------------------------------------------------

-- | Feeds the provided data into the specified process, then
--   concurrently streams stdout and stderr into the provided
--   continuation.
--
--   Note that the monad used in the 'StdOutErr' argument to the
--   continuation can be different from the final result, as it's up
--   to the caller to make sure the result is reached.
withStreamingProcess :: ( Withable w, MonadBaseControl IO (WithMonad w)
                        , MonadBase IO n)
                        => CreateProcess -> ByteString (WithMonad w) v
                        -> w (StdOutErr n ())
withStreamingProcess cp inp = liftWith (SP.withStreamingProcess cp inp)

-- | As with 'withStreamingProcess', but run the specified command in
--   a shell.
withStreamingCommand :: ( Withable w, MonadBaseControl IO (WithMonad w)
                        , MonadBase IO n)
                        => String -> ByteString (WithMonad w) v
                        -> w (StdOutErr n ())
withStreamingCommand = withStreamingProcess . shell

-- | Feed input into a process with no expected output.
streamInput :: (Withable w) => CreateProcess
               -> ByteString (WithMonad w) r -> w r
streamInput cp inp = liftAction (SP.streamInput cp inp)

-- | As with 'streamInput' but run the specified command in a shell.
streamInputCommand :: (Withable w) => String
                      -> ByteString (WithMonad w) r -> w r
streamInputCommand = streamInput . shell

-- | Obtain the output of a process with no input (ignoring error
--   output).
withStreamingOutput :: (Withable w, MonadIO n)
                       => CreateProcess
                       -> w (ByteString n ())
withStreamingOutput cp = liftWith (SP.withStreamingOutput cp)

-- | As with 'withStreamingOutput' but run the specified command in a
--  shell.
withStreamingOutputCommand :: (Withable w, MonadIO n)
                              => String
                              -> w (ByteString n ())
withStreamingOutputCommand = withStreamingOutput . shell

--------------------------------------------------------------------------------

-- | Feeds the provided data into the input handle, then concurrently
--   streams stdout and stderr into the provided continuation.
--
--   Note that the monad used in the 'StdOutErr' argument to the
--   continuation can be different from the final result, as it's up
--   to the caller to make sure the result is reached.
withProcessHandles :: (Withable w, m ~ WithMonad w, MonadBaseControl IO m, MonadBase IO n)
                      => ByteString m v
                      -> StreamProcess (SupplyStream m)
                                       (WithStream' m)
                                       (WithStream' m)
                      -> w (StdOutErr n ())
withProcessHandles inp sp = liftWith (SP.withProcessHandles inp sp)

-- | Stream input into a process, ignoring any output.
processInput :: (Withable w)
                => StreamProcess (SupplyStream (WithMonad w)) ClosedStream ClosedStream
                -> ByteString (WithMonad w) r -> w r
processInput sp inp = liftAction (SP.processInput sp inp)

-- | Read the output from a process, ignoring stdin and stderr.
withProcessOutput :: (Withable w, MonadIO n)
                     => StreamProcess ClosedStream (WithStream n (WithMonad w)) ClosedStream
                     -> w (ByteString n ())
withProcessOutput sp = liftWith (SP.withProcessOutput sp)

--------------------------------------------------------------------------------

-- | A variant of 'withCheckedProcess' that will on an exception kill
--   the child process and attempt to perform cleanup (though you
--   should also attempt to do so in your own code).
--
--   Will throw 'ProcessExitedUnsuccessfully' on a non-successful exit code.
--
--   Compared to @withCheckedProcessCleanup@ from @conduit-extra@,
--   this has the three parameters grouped into 'StreamProcess' to
--   make it more of a continuation.
withStreamProcess :: (InputSource stdin, OutputSink stdout, OutputSink stderr
                     , Withable w)
                     => CreateProcess -> w (StreamProcess stdin stdout stderr)
withStreamProcess cp = liftWith (SP.withStreamProcess cp)

-- | A variant of 'withStreamProcess' that runs the provided
--   command in a shell.
withStreamCommand :: (InputSource stdin, OutputSink stdout, OutputSink stderr
                     , Withable w)
                     => String -> w (StreamProcess stdin stdout stderr)
withStreamCommand = withStreamProcess . shell

--------------------------------------------------------------------------------

-- | Get both stdout and stderr concurrently.
withStreamOutputs :: ( Withable w, m ~ WithMonad w, MonadBaseControl IO m
                     , MonadBase IO n)
                     => StreamProcess stdin (WithStream' m) (WithStream' m)
                     -> w (StdOutErr n ())
withStreamOutputs sp = liftWith (SP.withStreamOutputs sp)

--------------------------------------------------------------------------------

supplyStream :: (Withable w) => SupplyStream (WithMonad w)
                -> ByteString (WithMonad w) r -> w r
supplyStream ss inp = liftAction (SP.supplyStream ss inp)

withStream :: (Withable w) => WithStream n (WithMonad w) -> w (ByteString n ())
withStream ws = liftWith (SP.withStream ws)

--------------------------------------------------------------------------------

{- $reexports

All of "Data.Streaming.Process" is available for you to use.

The 'concurrently' function will probably be useful if manually
handling process inputs and outputs.

-}
