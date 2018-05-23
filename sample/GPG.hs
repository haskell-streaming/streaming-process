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

import           Data.ByteString.Streaming       (ByteString)
import qualified Data.ByteString.Streaming.Char8 as SBC
import qualified Streaming                       as S
import qualified Streaming.Prelude               as S
import           Streaming.With.Lifted

import           Control.Exception           (Exception(..), mapException)
import           Control.Monad.Base          (MonadBase)
import           Control.Monad.Catch         (MonadThrow, throwM)
import           Control.Monad.IO.Class      (liftIO)
import           Control.Monad.Trans.Control (MonadBaseControl)
import qualified Data.ByteString.Char8       as B
import           Data.Maybe                  (fromMaybe)
import           Data.Typeable               (Typeable)
import           System.Directory            (findExecutable)
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

withGPG :: (Withable w, MonadThrow (WithMonad w))
           => Maybe FilePath
              -- ^ The path to the executable to use.  If not
              --   specified, will try and find a command called @gpg2@
              --   on the path.
           -> w (GPGArgs ())
withGPG mPath = do
  mexe <- liftActionIO (findExecutable path)
  maybe (liftThrow (CantFindGPG path)) (return . ga) mexe
  where
    path = fromMaybe "gpg2" mPath

    ga exe = GPGArgs
               { argFunc = proc exe . ("--batch":)
               , homeDir = ()
               }

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
  fl <- case key of
          KeyFile fl -> return fl
          KeyRaw  rk -> writeCnts rk
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
    importer cp = mapException ErrorRunningGPG
                  . withCreateProcess cp $ \_ _ _ ph -> do
      ec <- waitForProcess ph
      case ec of
        ExitSuccess   -> return ()
        ExitFailure _ -> throwM (ProcessExitedUnsuccessfully cp ec)

newtype KeyID = KeyID { getKeyID :: B.ByteString }

withKeyID :: (Withable w) => KeyFile -> GPGArgs FilePath -> w KeyID
withKeyID kf ga = do
  -- Unfortunately, we have to rely on gpg "doing the right thing" and
  -- guessing what we want to do, namely give information about the
  -- keyfile.
  let cp = runGPGWith ["--with-colons", getKey kf] ga
  out <- mapException ErrorRunningGPG (withStreamingOutput cp)
  liftActionIO (parseID out)
  where
    parseID :: (MonadThrow m) => ByteString m () -> m KeyID
    parseID bs = do
      eln1 <- S.inspect (SBC.lines bs)
      -- We want the 5th column.
      case eln1 of
        Left _    -> throwM (KeyNotFound kf)
        Right ln1 ->
          (maybe (throwM (KeyNotFound kf)) (return . KeyID) =<<)
          -- We want the 5th column.
          . S.head_
          . S.drop 4
          . S.mapped SBC.toStrict
          . SBC.split ':'
          $ ln1

encrypt :: (Withable w, MonadBaseControl IO (WithMonad w), MonadBase IO n)
           => GPGArgs FilePath -> KeyID -> ByteString (WithMonad w) r
           -> w (StdOutErr n ())
encrypt ga key = mapException ErrorRunningGPG . withStreamingProcess cp
  where
    -- Key value should be hex
    cp = runGPGWith ["--encrypt", "--recipient", B.unpack (getKeyID key)] ga

decrypt :: (Withable w, MonadBaseControl IO (WithMonad w), MonadBase IO n)
           => GPGArgs FilePath -> ByteString (WithMonad w) r
           -> w (StdOutErr n ())
decrypt ga = mapException ErrorRunningGPG .  withStreamingProcess cp
  where
    -- Key value should be hex
    cp = runGPGWith ["--decrypt"] ga

data GPGAction = Encrypt | Decrypt
  deriving (Eq, Ord, Show, Read, Bounded, Enum)

gpg :: (Withable w, MonadBaseControl IO (WithMonad w), MonadBase IO n)
       => GPGAction -> Key (WithMonad w) -> ByteString (WithMonad w) i
       -> w (StdOutErr n ())
gpg act key inp = do
  ga0  <- withGPG Nothing
  gahd <- setHomeDirectory Nothing ga0
  kf   <- withKey key gahd
  case act of
    Encrypt -> do
      kid <- withKeyID kf gahd
      encrypt gahd kid inp
    Decrypt -> decrypt gahd inp

generate4096RSAKey :: (Withable w) => FilePath -> w ()
generate4096RSAKey fp = do
  ga0 <- withGPG Nothing
  gahd <- setHomeDirectory Nothing ga0
  return ()
  where
    params = unlines
      [ "Key-Type: RSA"
      , "Key-Length: 4096"
      , "Key-Usage: encrypt"
      , "%no-ask-passphrase"
      , "Expire-Date: 0"
      ]

data GPGException
  = CantFindGPG FilePath
  | KeyNotFound KeyFile
  | ErrorRunningGPG ProcessExitedUnsuccessfully
  deriving (Show, Typeable)

instance Exception GPGException where
  displayException ex =
    case ex of
      CantFindGPG pth     -> "Cannot find expected GPG executable: " ++ pth
      KeyNotFound kf      -> "Cannot find the identifier for the specified KeyFile: " ++ getKey kf
      ErrorRunningGPG peu -> "Error running gpg:\n" ++ displayException peu
