{-# LANGUAGE BangPatterns, FlexibleContexts, MultiParamTypeClasses,
             OverloadedStrings #-}

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
import Control.Monad.Base              (MonadBase, liftBase)
import Control.Monad.Catch             (MonadMask, finally, onException)
import Control.Monad.IO.Class          (MonadIO)
import Control.Monad.Trans.Class       (lift)
import Control.Monad.Trans.Control     (MonadBaseControl)
import Data.Streaming.Process          (StreamingProcessHandle,
                                        streamingProcess,
                                        streamingProcessHandleRaw,
                                        terminateProcess,
                                        waitForStreamingProcess)
import System.Exit                     (ExitCode)
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

terminateStreamingProcess :: (MonadBase IO m) => StreamingProcessHandle -> m ()
terminateStreamingProcess = liftBase . terminateProcess . streamingProcessHandleRaw

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
