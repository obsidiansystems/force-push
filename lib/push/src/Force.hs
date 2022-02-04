{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TemplateHaskell #-}

module Force (forcePush) where

import Obelisk.CliApp
-- import Obelisk.CliApp.Process

import Obelisk.App
import Obelisk.Command
import Obelisk.Command.Nix

import Control.Monad.Log (Severity(..))
import Control.Monad.Catch (MonadMask, mask, onException)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Concurrent
import Control.Lens

import Control.Monad.Error.Class (MonadError)

import Data.Default (def)

import qualified Data.Map as Map

import System.Which (staticWhich)
import System.FilePath.Posix ((</>))

-- type MonadForce m = (HasObelisk m MonadIO m, MonadMask m, CliLog m, MonadError ObeliskError m, HasCliConfig ObeliskError m)

rsyncPath :: FilePath
rsyncPath = $(staticWhich "rsync")

sshPath :: FilePath
sshPath = $(staticWhich "ssh")

forcePush :: IO ()
forcePush = do
  -- cfg <- newCliConfig Informational False False (const ("Dank", 1))
  cfg <- mkObeliskConfig
  runObelisk cfg deployPush

deployPush :: MonadObelisk m => m ()
deployPush = do
  let deployPath = "../../default.nix"
  -- TODO(skylar): Version from thunk
  [buildResult] <- withSpinner "Building production assets" $ fmap lines $ nixCmd $ NixCmd_Build $ def
    & nixCmdConfig_target .~ Target
      { _target_path = Just deployPath
      , _target_attr = Just "force-bridge-ui.build"
      , _target_expr = Nothing
      }
    & nixBuildConfig_outLink .~ OutLink_None
  [serverResult] <- withSpinner "Building system" $ fmap lines $ nixCmd $ NixCmd_Build $ def
    & nixCmdConfig_target .~ Target
      { _target_path = Just deployPath
      , _target_attr = Just "server.system"
      , _target_expr = Nothing
      }
    & nixBuildConfig_outLink .~ OutLink_None
  let host = "force-bridge.dev.obsidian.systems"
      sshOpts = []
  withSpinner "Uploading closures" $ do
    callProcess'
      -- TODO(skylar): Do we need sshopts here?
      -- (Map.fromList [("NIX_SSHOPTS"), unwords sshOpts])
      mempty
      "nix-copy-closure" ["-v", "--to", "--use-substitutes", "root@" <> host, "--gzip", serverResult]
  withSpinner "Uploading files" $ do
    callProcessAndLogOutput (Notice, Warning) $
      proc rsyncPath
           [ "-e " <> sshPath <> " " <> unwords sshOpts
           , "-qarvz"
           , buildResult </> "build"
           , "root@" <> host <> ":/var/lib/backend"
           ]
  withSpinner "Switching to new configuration" $ do
    callProcessAndLogOutput (Notice, Warning) $
      proc sshPath $ sshOpts <>
        [ "root@" <> host
        , unwords
            -- Note that we don't want to $(staticWhich "nix-env") here, because this is executing on a remote machine
            [ "nix-env -p /nix/var/nix/profiles/system --set " <> serverResult
            , "&&"
            , "/nix/var/nix/profiles/system/bin/switch-to-configuration switch"
            ]
        ]
  where
    callProcess' envMap cmd args = do
      let p = setEnvOverride (envMap <>) $ setDelegateCtlc True $ proc cmd args
      callProcessAndLogOutput (Notice, Notice) p
