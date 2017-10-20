{-# LANGUAGE FlexibleContexts, MultiParamTypeClasses #-}

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

import           Control.Monad.Base          (MonadBase)
import           Control.Monad.Catch         (throwM)
import           Control.Monad.IO.Class      (liftIO)
import           Control.Monad.Trans.Control (MonadBaseControl)
import qualified Data.ByteString             as B
import           Data.ByteString.Streaming   (ByteString)
import qualified Data.ByteString.Streaming   as SB
import           Data.Maybe                  (fromMaybe)
import           System.Exit                 (ExitCode(..))
import           System.IO                   (hClose)
import           System.Process              (CreateProcess, proc)

--------------------------------------------------------------------------------

-- | The representation of specifying command-line arguments to GPG.
data GPGArgs hd = GPGArgs
  { argFunc :: !(Args -> CreateProcess)
  , homeDir :: !hd
  }

type Args = [String]

withGPG :: (Withable w)
           => Maybe FilePath
              -- ^ The path to the executable to use.  If not
              --   specified, will try and find a command called @gpg2@
              --   on the path.
           -> w (GPGArgs ())
withGPG mPath = return (GPGArgs (proc (fromMaybe "gpg2" mPath)) ())

runGPGWith :: Args -> GPGArgs hd -> CreateProcess
runGPGWith args = ($args) . argFunc

runGPG :: GPGArgs hd -> CreateProcess
runGPG = runGPGWith []

withArgs :: (Withable w) => (Args -> Args) -> GPGArgs hd -> w (GPGArgs hd)
withArgs f ga = liftAction (return (ga { argFunc = argFunc ga . f}))

-- | 'Nothing' means \"use temporary directory\".
setHomeDirectory :: (Withable w) => Maybe FilePath -> GPGArgs hd -> w (GPGArgs FilePath)
setHomeDirectory mdir ga = do
  dir <- maybe (withSystemTempDirectory "streaming-process-gpg.") return mdir
  return (ga { argFunc = argFunc ga . (["--homedir", dir] ++)
             , homeDir = dir
             })

data Key m = KeyFile !FilePath
           | KeyRaw  !(ByteString m ())

newtype KeyFile = KF { getKey :: FilePath }
  deriving (Eq, Show, Read)

withKey :: (Withable w) => Key (WithMonad w) -> GPGArgs FilePath -> w KeyFile
withKey key ga = do
  -- TODO: if a file, does it need to be copied into the specified
  -- directory?
  keyCnts <- case key of
               KeyFile fl -> withBinaryFileContents fl
               KeyRaw rk  -> return rk
  fl <- writeCnts keyCnts
  liftActionIO (importer (runGPGWith ["--import", fl] ga))
  return (KF fl)
  where
    -- This is to avoid the extra Handle leaking out
    writeCnts :: (Withable v) => ByteString (WithMonad v) () -> v FilePath
    writeCnts bs = do
      (fl, h) <- withTempFile (homeDir ga) "import.key"
      liftAction (SBC.hPut h bs >> liftIO (hClose h))
      return fl

    importer :: CreateProcess -> IO ()
    importer cp = withCreateProcess cp $ \_ _ _ ph -> do
      ec <- waitForProcess ph
      case ec of
        ExitSuccess   -> return ()
        ExitFailure _ -> throwM (ProcessExitedUnsuccessfully cp ec)

data GPGAction = Encrypt | Decrypt
  deriving (Eq, Ord, Show, Read, Bounded, Enum)

-- gpg :: (Withable w, MonadBaseControl IO (WithMonad w), MonadBase IO n)
--        => GPGAction -> Key (WithMonad w) -> ByteString (WithMonad w) i
--        -> w (StdOutErr n ())
-- gpg = undefined
