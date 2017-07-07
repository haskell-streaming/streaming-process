{- |
   Module      : Streaming.Process.GPG
   Description : Example library usage by wrapping up GPG
   Copyright   : Ivan Lazar Miljenovic
   License     : MIT
   Maintainer  : Ivan.Miljenovic@gmail.com

   As an example of using this library, this module provides functions
   to allow you to use the <https://gnupg.org/ GNU Privacy Guard>
   @gpg@ tool (specifically, version @>= 2.1@).

   This uses the 'Withable' class from @streaming-with@ and the
   definitions found within "Streaming.Process.Lifted".

 -}
module Streaming.Process.GPG where

import Streaming.Process.Lifted

import Streaming.With.Lifted

import qualified Data.ByteString as B
import           Data.Maybe      (fromMaybe)
import           System.Process  (CreateProcess, proc)

--------------------------------------------------------------------------------

-- | The representation of specifying command-line arguments to GPG.
type GPGArgs = Args -> CreateProcess

type Args = [String]

withGPG :: (Withable w)
           => Maybe FilePath
              -- ^ The path to the executable to use.  If not
              --   specified, will try and find a command called @gpg2@
              --   on the path.
           -> w GPGArgs
withGPG mPath = liftWith ($ proc (fromMaybe "gpg2" mPath))

withArgs :: (Withable w) => (Args -> Args) -> GPGArgs -> w GPGArgs
withArgs argFunc ga = liftWith ($ (ga . argFunc))

withHomeDirectory :: (Withable w) => FilePath -> GPGArgs -> w GPGArgs
withHomeDirectory dir = withArgs (["--homedir", dir] ++)

withTemporaryHomeDirectory :: (Withable w) => GPGArgs -> w GPGArgs
withTemporaryHomeDirectory args =
  withSystemTempDirectory "streaming-process-gpg." >>= flip withHomeDirectory args
