{-# LANGUAGE BangPatterns, FlexibleContexts, MultiParamTypeClasses,
             NamedFieldPuns, OverloadedStrings, RecordWildCards #-}

{- |
   Module      : Streaming.Process
   Description : Run system process with support for Streams
   Copyright   : (c) Ivan Lazar Miljenovic
   License     : MIT
   Maintainer  : Ivan.Miljenovic@gmail.com

   Run system commands in a streaming fashion.

   These functions are typically written to be used in a
   continuation-passing style to allow for proper finalisation.  The
   type signatures are designed so as to allow them to be used with
   @ContT@ from "Control.Monad.Trans.Cont" or - if you will be running
   it all directly in IO with no other transformers on the stack - the
   <http://hackage.haskell.org/package/managed managed> package.

   These functions will all throw 'ProcessExitedUnsuccessfully' if the
   process\/command itself fails.

 -}
module Streaming.Process
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
  , withStreamProcess
  , withStreamCommand
  , withProcessHandles
  , processInput
  , withProcessOutput
    -- * Interleaved stdout and stderr
  , StdOutErr
  , getStreamingOutputsN
    -- * Re-exports
  , module Data.Streaming.Process
  , IOMode(..)
  ) where

import qualified Data.ByteString                    as B
import           Data.ByteString.Streaming          (ByteString)
import qualified Data.ByteString.Streaming          as SB
import           Data.ByteString.Streaming.Internal (defaultChunkSize)
import           Streaming                          (hoist)
import qualified Streaming.Prelude                  as S

import Control.Concurrent.Async.Lifted (Concurrently(..), async,
                                        waitEitherCancel)
import Control.Monad.Base              (liftBase)
import Control.Monad.Catch             (MonadMask, bracket, finally,
                                        onException, throwM)
import Control.Monad.IO.Class          (MonadIO, liftIO)
import Control.Monad.Trans.Class       (lift)
import Control.Monad.Trans.Control     (MonadBaseControl)
import Data.Streaming.Process
import System.Exit                     (ExitCode(..))
import System.IO                       (Handle, IOMode(..), hClose,
                                        openBinaryFile)
import System.Process                  (CreateProcess(..), shell)

--------------------------------------------------------------------------------

-- | Feeds the provided data into the specified process, then
--   concurrently streams stdout and stderr into the provided
--   continuation.
--
--   Note that the monad used in the 'StdOutErr' argument to the
--   continuation can be different from the final result, as it's up
--   to the caller to make sure the result is reached.
withStreamingProcess :: (MonadBaseControl IO m, MonadIO m, MonadMask m
                        , MonadBaseControl IO n)
                        => CreateProcess -> ByteString m v
                        -> (StdOutErr n () -> m r) -> m r
withStreamingProcess cp inp = withStreamProcess cp
                              . flip (withProcessHandles inp)

-- | As with 'withStreamingProcess', but run the specified command in
--   a shell.
withStreamingCommand :: (MonadBaseControl IO m, MonadIO m, MonadMask m
                        , MonadBaseControl IO n)
                        => String -> ByteString m v
                        -> (StdOutErr n () -> m r) -> m r
withStreamingCommand = withStreamingProcess . shell

-- | Feed input into a process with no expected output.
streamInput :: (MonadIO m, MonadMask m) => CreateProcess
               -> ByteString m r -> m r
streamInput cp = withStreamProcess cp . flip processInput

-- | As with 'streamInput' but run the specified command in a shell.
streamInputCommand :: (MonadIO m, MonadMask m) => String
                      -> ByteString m r -> m r
streamInputCommand = streamInput . shell

-- | Obtain the output of a process with no input (ignoring error
--   output).
withStreamingOutput :: (MonadIO n, MonadIO m, MonadMask m)
                       => CreateProcess
                       -> (ByteString n () -> m r) -> m r
withStreamingOutput cp = withStreamProcess cp . flip withProcessOutput

-- | As with 'withStreamingOutput' but run the specified command in a
--  shell.
withStreamingOutputCommand :: (MonadIO n, MonadIO m, MonadMask m)
                              => String
                              -> (ByteString n () -> m r) -> m r
withStreamingOutputCommand = withStreamingOutput . shell

--------------------------------------------------------------------------------

-- | Feeds the provided data into the input handle, then concurrently
--   streams stdout and stderr into the provided continuation.
--
--   Note that the monad used in the 'StdOutErr' argument to the
--   continuation can be different from the final result, as it's up
--   to the caller to make sure the result is reached.
withProcessHandles :: (MonadBaseControl IO m, MonadIO m, MonadMask m, MonadBaseControl IO n)
                      => ByteString m v -> StreamProcess Handle Handle Handle
                      -> (StdOutErr n () -> m r) -> m r
withProcessHandles inp sp@StreamProcess{..} f =
  runConcurrently (flip const <$> Concurrently withIn
                              <*> Concurrently withOutErr)
  `finally` liftIO closeOutErr
  where
    withIn = SB.hPut toStdin inp `finally` liftIO (hClose toStdin)

    withOutErr = f (getStreamingOutputsN defaultChunkSize sp)

    closeOutErr = hClose fromStdout >> hClose fromStderr

-- | Stream input into a process, ignoring any output.
processInput :: (MonadIO m, MonadMask m)
                => StreamProcess Handle ClosedStream ClosedStream
                -> ByteString m r -> m r
processInput StreamProcess{toStdin} inp =
  SB.hPut toStdin inp `finally` liftIO (hClose toStdin)

-- | Read the output from a process, ignoring stdin and stderr.
withProcessOutput :: (MonadIO n, MonadIO m, MonadMask m)
                     => StreamProcess ClosedStream Handle ClosedStream
                     -> (ByteString n () -> m r) -> m r
withProcessOutput StreamProcess{fromStdout} f =
  f (SB.hGet fromStdout defaultChunkSize) `finally` liftIO (hClose fromStdout)

--------------------------------------------------------------------------------

-- | Represents the input and outputs for a streaming process.
data StreamProcess stdin stdout stderr = StreamProcess
  { toStdin    :: !stdin
  , fromStdout :: !stdout
  , fromStderr :: !stderr
  } deriving (Eq, Show)

-- | Switch the two outputs.  Useful for example if using
--   'withStreamProcess' and 'withProcessHandles' but wanting to deal
--   with any potential output from stderr before stdout.
switchOutputs :: StreamProcess stdin stdout stderr
                 -> StreamProcess stdin stderr stdout
switchOutputs sp@StreamProcess{fromStdout, fromStderr}
  = sp { fromStdout = fromStderr
       , fromStderr = fromStdout
       }

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
                     , MonadIO m, MonadMask m)
                     => CreateProcess
                     -> (StreamProcess stdin stdout stderr -> m r) -> m r
withStreamProcess cp f = do
  (stdin, stdout, stderr, sph) <- streamingProcess cp
  r <- f (StreamProcess stdin stdout stderr)
         `onException` terminateStreamingProcess sph
  ec <- waitForStreamingProcess sph `finally` closeStreamingProcessHandle sph
  case ec of
    ExitSuccess   -> return r
    ExitFailure _ -> throwM (ProcessExitedUnsuccessfully cp ec)

-- | A variant of 'withStreamProcess' that runs the provided
--   command in a shell.
withStreamCommand :: (InputSource stdin, OutputSink stdout, OutputSink stderr
                     , MonadIO m, MonadMask m)
                     => String
                     -> (StreamProcess stdin stdout stderr -> m r) -> m r
withStreamCommand = withStreamProcess . shell

terminateStreamingProcess :: (MonadIO m) => StreamingProcessHandle -> m ()
terminateStreamingProcess = liftIO . terminateProcess . streamingProcessHandleRaw

--------------------------------------------------------------------------------

-- | A representation of the concurrent streaming of both @stdout@ and
--   @stderr@ (contrast to 'SB.hGet').
--
--   Note that if for example you wish to completely discard stderr,
--   you can do so with @'hoist' 'SB.effects'@ (or just process the
--   stdout, then run 'SB.effects' at the end to discard the stderr).
type StdOutErr m r = ByteString (ByteString m) r

-- | Get both stdout and stderr concurrently.
--
--   Chunks are guaranteed to be no larger than the size specified,
--   but may be smaller to improve responsiveness and avoid blocking.
getStreamingOutputsN :: (MonadBaseControl IO m) => Int
                        -> StreamProcess stdin Handle Handle
                        -> StdOutErr m ()
getStreamingOutputsN n _ | n <= 0 = return ()
getStreamingOutputsN n StreamProcess{fromStdout, fromStderr} =
  SB.fromChunks . hoist SB.fromChunks . S.partitionEithers $ loopBoth
  where
    -- Will block until /something/ is available; may have length < n
    getOut = liftBase (B.hGetSome fromStdout n)
    getErr = liftBase (B.hGetSome fromStderr n)

    loopBoth = do !res <- lift (do getOutA <- async getOut
                                   getErrA <- async getErr
                                   waitEitherCancel getOutA getErrA)
                  -- As soon as either one
                  -- returns empty, then
                  -- focus on the other.
                  case res of
                    Left  "" -> loopWith Right getErr
                    Right "" -> loopWith Left  getOut
                    _        -> S.yield res >> loopBoth

    loopWith f get = go
      where
        go = do b <- lift get
                if B.null b
                   then return ()
                   else S.yield (f b) >> go
