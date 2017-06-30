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

import qualified Data.ByteString.Lazy            as LB
import           Data.ByteString.Streaming       (ByteString)
import qualified Data.ByteString.Streaming       as B
import qualified Data.ByteString.Streaming.Char8 as CB
import           Streaming                       (Of(..))
import qualified Streaming                       as S
import qualified Streaming.Prelude               as S

import Test.Hspec                (describe, hspec)
import Test.Hspec.QuickCheck     (prop)
import Test.QuickCheck           (Arbitrary(..), Positive(..), Property,
                                  ioProperty)
import Test.QuickCheck.Instances ()

import Control.Monad.Morph (hoist)

--------------------------------------------------------------------------------

main :: IO ()
main = hspec $ do
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

test :: LB.ByteString -> IO Bool
test bs =
  withStreamingCommand "ghc -e \"getContents >>= \\inp -> putStr inp >> System.IO.hPutStr System.IO.stderr inp\"" (B.fromLazy bs) $
--    CB.putStrLn . CB.putStrLn
    fmap (uncurry' ((&&) . isSame))
    . (>>= (\v -> print v >> return v))
    . B.toLazy
    . fmap isSame
    . (>>= (\v -> S.liftIO (print v) >> return v))
    . B.toLazy_
  where
    isSame = (bs==)

noStdErr :: String -> ByteString IO r -> (ByteString IO () -> IO v) -> IO v
noStdErr cmd inp f = withStreamingCommand cmd inp (f . hoist B.effects)

uncurry' :: (a -> b -> c) -> Of a b -> c
uncurry' f (a :> b) = f a b
