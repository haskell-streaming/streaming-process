{-# LANGUAGE FlexibleContexts, MultiParamTypeClasses, OverloadedStrings #-}

{- |
   Module      : Streaming.Process
   Description : Run system process with support for Streams
   Copyright   : (c) Ivan Lazar Miljenovic
   License     : MIT
   Maintainer  : Ivan.Miljenovic@gmail.com



 -}
module Streaming.Process where

import qualified Data.ByteString                    as B
import           Data.ByteString.Streaming          (ByteString)
import qualified Data.ByteString.Streaming          as SB
import           Data.ByteString.Streaming.Internal (defaultChunkSize)
import           Streaming
import qualified Streaming.Prelude                  as S

import Control.Concurrent.Async.Lifted (Concurrently(..), async,
                                        waitEitherCancel)
import Control.Monad.Base              (MonadBase, liftBase)
import Control.Monad.Catch             (MonadMask, finally, onException)
import Control.Monad.Trans.Class       (lift)
import Control.Monad.Trans.Control     (MonadBaseControl)
import Data.Streaming.Process
import System.Exit                     (ExitCode)
import System.IO                       (Handle, hClose)
import System.Process                  (CreateProcess(..), StdStream(..), shell)

--------------------------------------------------------------------------------

streamProcess :: (MonadIO m, MonadBaseControl IO m, MonadMask m)
                 => CreateProcess -> ByteString m r -> ByteString (ByteString m) (r, ExitCode)
streamProcess cp inp = do (inH, outH, errH, sph) <- streamingProcess cp
                          (r, out) <- lift2 (runConcurrently ((,) <$> Concurrently (withIn inH)
                                                                  <*> Concurrently (withOut outH errH))
                                             `finally` (liftBase (hClose outH >> hClose errH))
                                             `onException` terminateStreamingProcess sph)
                          ec <- waitForStreamingProcess sph
                          (r, ec) <$ out
  where
    -- withIn :: Handle -> m r
    withIn inH = SB.hPut inH inp `finally` liftBase (hClose inH)

    -- withOut :: Handle -> Handle -> m (ByteString (ByteString m) ())
    withOut outH errH = return (getBothBN defaultChunkSize outH errH)

    -- lift2 :: (Monad n) => n a -> ByteString (ByteString n) a
    lift2 = hoist lift . lift

streamCmd :: (MonadIO m, MonadBaseControl IO m, MonadMask m)
             => String -> ByteString m r -> ByteString (ByteString m) (r, ExitCode)
streamCmd = streamProcess . shell

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

    loopBoth = do res <- lift (do getA1 <- async get1
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
