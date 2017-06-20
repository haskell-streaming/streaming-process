{-# LANGUAGE BangPatterns, FlexibleContexts, MultiParamTypeClasses,
             NamedFieldPuns, OverloadedStrings, RecordWildCards #-}

{- |
   Module      : Streaming.Process
   Description : Run system process with support for Streams
   Copyright   : (c) Ivan Lazar Miljenovic
   License     : MIT
   Maintainer  : Ivan.Miljenovic@gmail.com

   Run system commands in a streaming fashion.

 -}
module Streaming.Process
  ( StdOutErr
  , withStreamProcess
  , withStreamCmd
  ) where

import qualified Data.ByteString                    as B
import           Data.ByteString.Streaming          (ByteString)
import qualified Data.ByteString.Streaming          as SB
import           Data.ByteString.Streaming.Internal (defaultChunkSize)
import           Streaming                          (Of, Stream, hoist)
import qualified Streaming.Prelude                  as S

import Control.Concurrent.Async.Lifted (Concurrently(..), async,
                                        waitEitherCancel)
import Control.Monad.Base              (liftBase)
import Control.Monad.Catch             (MonadMask, finally, onException, throwM)
import Control.Monad.IO.Class          (MonadIO)
import Control.Monad.Trans.Class       (lift)
import Control.Monad.Trans.Control     (MonadBaseControl)
import Data.Streaming.Process
import System.Exit                     (ExitCode(..))
import System.IO                       (Handle, hClose)
import System.Process                  (CreateProcess(..), shell)

--------------------------------------------------------------------------------

-- | A representation of the concurrent streaming of both @stdout@ and
--   @stderr@.
type StdOutErr m r = ByteString (ByteString m) r

-- | Run a process, feeding the provided stream to it and providing
--   both the @stdout@ and @stderr@ to the callback.
--
--   Ideally, this function would just return the resultant
--   'ByteString'; however, it isn't possible to ensure that the
--   handles are successfully closed upon termination in that case.
withStreamProcess :: (MonadIO m, MonadBaseControl IO m, MonadMask m)
                     => CreateProcess -> ByteString m r
                     -> (StdOutErr m () -> m v) -> m ((r, v), ExitCode)
withStreamProcess cp inp f =
  do (inH, outH, errH, sph) <- streamingProcess cp
     res <- runConcurrently ((,) <$> Concurrently (withIn inH)
                                 <*> Concurrently (withOut outH errH))
            `finally` (liftBase (hClose outH >> hClose errH))
            `onException` terminateStreamingProcess sph
     ec <- waitForStreamingProcess sph
     return (res, ec)
  where
    -- withIn :: Handle -> m r
    withIn inH = SB.hPut inH inp `finally` liftBase (hClose inH)

    -- withOut :: Handle -> Handle -> m v
    withOut outH errH = f (getBothBN defaultChunkSize outH errH)

-- | A variant of 'withStreamProcess' that runs the provided command
--   in a shell.
withStreamCmd :: (MonadIO m, MonadBaseControl IO m, MonadMask m)
                  => String -> ByteString m r
                  -> (StdOutErr m () -> m v) -> m ((r, v), ExitCode)
withStreamCmd = withStreamProcess . shell

--------------------------------------------------------------------------------

-- | Feeds the provided data into the input handle, then concurrently
--   streams stdout and stderr into the provided continuation.
--
--   Note that the monad used in the 'StdOutErr' argument to the
--   continuation can be different from the final result, as it's up
--   to the caller to make sure the result is reached.
streamProcessHandles :: (MonadBaseControl IO m, MonadIO m, MonadMask m, MonadBaseControl IO n)
                        => ByteString m v -> ProcessStreams Handle Handle Handle
                        -> (StdOutErr n () -> m r) -> m r
streamProcessHandles inp ProcessStreams{..} f =
  runConcurrently (flip const <$> Concurrently withIn
                              <*> Concurrently withOutErr)
  `finally` liftIO closeOutErr
  where
    withIn = SB.hPut stdinSource inp `finally` liftIO (hClose stdinSource)

    withOutErr = f (getBothBN defaultChunkSize stdoutSink stderrSink)

    closeOutErr = hClose stdoutSink >> hClose stderrSink

-- | Stream input into a process, ignoring any output.
streamInput :: (MonadIO m, MonadMask m)
               => ProcessStreams Handle ClosedStream ClosedStream
               -> ByteString m r -> m r
streamInput ProcessStreams{stdinSource} inp =
  SB.hPut stdinSource inp `finally` liftIO (hClose stdinSource)

-- | Read the output from a process, ignoring stdin and stderr.
streamOutput :: (MonadIO n, MonadIO m, MonadMask m)
                => ProcessStreams ClosedStream Handle ClosedStream
                -> (ByteString n () -> m r) -> m r
streamOutput ProcessStreams{stdoutSink} f =
  f (SB.hGet stdoutSink defaultChunkSize) `finally` liftIO (hClose stdoutSink)

--------------------------------------------------------------------------------

data ProcessStreams stdin stdout stderr = ProcessStreams
  { stdinSource :: !stdin
  , stdoutSink  :: !stdout
  , stderrSink  :: !stderr
  } deriving (Eq, Show)

-- | A variant of 'withCheckedProcess' that will on an exception kill
--   the child process and attempt to perform cleanup (though you
--   should also attempt to do so in your own code).
--
--   Will throw 'ProcessExitedUnsuccessfully' on a non-successful exit code.
--
--   Compared to @withCheckedProcessCleanup@ from @conduit-extra@,
--   this has the types arranged so as to suit 'managed'.
withStreamingProcess :: (InputSource stdin, OutputSink stdout, OutputSink stderr
                        , MonadIO m, MonadMask m)
                        => CreateProcess
                        -> (ProcessStreams stdin stdout stderr -> m r) -> m r
withStreamingProcess cp f = do
  (stdin, stdout, stderr, sph) <- streamingProcess cp
  r <- f (ProcessStreams stdin stdout stderr)
         `onException` terminateStreamingProcess sph
  ec <- waitForStreamingProcess sph `finally` closeStreamingProcessHandle sph
  case ec of
    ExitSuccess   -> return r
    ExitFailure _ -> throwM (ProcessExitedUnsuccessfully cp ec)

terminateStreamingProcess :: (MonadIO m) => StreamingProcessHandle -> m ()
terminateStreamingProcess = liftIO . terminateProcess . streamingProcessHandleRaw

--------------------------------------------------------------------------------

getBothBN :: (MonadBaseControl IO m) => Int -> Handle -> Handle -> ByteString (ByteString m) ()
getBothBN n h1 h2 = SB.fromChunks . hoist SB.fromChunks . S.partitionEithers
                    $ getBothN n h1 h2

getBothN :: (MonadBaseControl IO m) => Int -> Handle -> Handle
            -> Stream (Of (Either B.ByteString B.ByteString)) m ()
getBothN n h1 h2 | n > 0 = loopBoth
  where
    -- Will block until /something/ is available; may have length < n
    get1 = liftBase (B.hGetSome h1 n)
    get2 = liftBase (B.hGetSome h2 n)

    loopBoth = do !res <- lift (do getA1 <- async get1
                                   getA2 <- async get2
                                   waitEitherCancel getA1 getA2)
                  -- As soon as either one
                  -- returns empty, then
                  -- focus on the other.
                  case res of
                    Left  "" -> loopWith Right get2
                    Right "" -> loopWith Left  get1
                    _        -> S.yield res >> loopBoth

    loopWith f get = go
      where
        go = do b <- lift get
                if B.null b
                   then return ()
                   else S.yield (f b) >> go

getBothN _ _ _ = return ()
