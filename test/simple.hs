{-# LANGUAGE OverloadedStrings #-}

{- |
   Module      : Main
   Description : Simple process testing
   Copyright   : (c) Ivan Lazar Miljenovic
   License     : MIT
   Maintainer  : Ivan.Miljenovic@gmail.com

   This will probably only run on *nix systems.

 -}
module Main (main) where

import Streaming.Process

import qualified Data.ByteString.Lazy      as LB
import           Data.ByteString.Streaming (ByteString)
import qualified Data.ByteString.Streaming as B
import           Streaming                 (Of(..))

import Test.Hspec                (describe, hspec)
import Test.Hspec.QuickCheck     (prop)
import Test.QuickCheck           (Property, ioProperty)
import Test.QuickCheck.Instances ()

import Control.Monad.Morph (hoist)

--------------------------------------------------------------------------------

main :: IO ()
main = hspec $
  describe "cat" $ do
    prop "stdout only" prop_cat
    prop "stdout and stderr" prop_catBoth

-- Use lazy bytestrings to avoid issues with it being chunked
-- differently.
--
-- But don't take them as arguments
prop_cat :: LB.ByteString -> Property
prop_cat bs = ioProperty (noStdErr "cat" (B.fromLazy bs) (fmap (bs==) . B.toLazy_))

prop_catBoth :: LB.ByteString -> Property
prop_catBoth bs = ioProperty $
  withStreamingCommand "cat | tee /dev/stderr" (B.fromLazy bs) $
    fmap (uncurry' ((&&) . isSame))
    . B.toLazy
    . fmap isSame
    . B.toLazy_
  where
    isSame = (bs==)

noStdErr :: String -> ByteString IO r -> (ByteString IO () -> IO v) -> IO v
noStdErr cmd inp f = withStreamCommand cmd $ \(StreamProcess stdin stdout ClosedStream) ->
  snd <$> concurrently (supplyStream stdin inp) (withStream stdout f)

uncurry' :: (a -> b -> c) -> Of a b -> c
uncurry' f (a :> b) = f a b
