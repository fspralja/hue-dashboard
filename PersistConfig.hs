
{-# LANGUAGE   LambdaCase
             , TemplateHaskell
             , RecordWildCards
             , OverloadedStrings
             , ScopedTypeVariables
             , FlexibleInstances
             , TypeSynonymInstances
             , GeneralizedNewtypeDeriving #-}

module PersistConfig ( configFilePath
                     , PersistConfig(..)
                     , UserData(..)
                     , defaultUserData
                     , pcBridgeIP
                     , pcBridgeUserID
                     , pcUserData
                     , pcScenes
                     , pcSchedules
                     , Scene
                     , SceneName
                     , Schedule(..)
                     , ScheduleName
                     , udVisibleGroupNames
                     , defaultPersistConfig
                     , loadConfig
                     , storeConfig
                     ) where

import Control.Monad
import Control.Lens hiding ((.=))
import Control.Monad.IO.Class
import qualified Data.Yaml as Y
import Data.Aeson
import qualified Data.HashMap.Strict as HM
import qualified Data.HashSet as HS
import Data.Monoid
import Data.Coerce

import Util
import Trace
import HueJSON
import Data.Time.Clock

-- Configuration and user data which we persist in a file

configFilePath :: FilePath
configFilePath = "./config.yaml" -- TODO: Maybe use ~/.hue-dashboard for this?

type UserDataMap = HM.HashMap CookieUserID UserData

-- A scene is a list of light IDs and a map of light state names to values
type Scene     = [(LightID, (HM.HashMap String Value))]
type SceneName = String
type SceneMap  = HM.HashMap SceneName Scene

-- Schedules
data Schedule = Schedule { _sHour   :: !Int
                         , _sMinute :: !Int
                         , _sScene  :: !SceneName
                         , _sDays   :: ![Bool]
                         } deriving (Eq, Show)
type ScheduleName = String
type ScheduleMap  = HM.HashMap ScheduleName Schedule

defaultSchedule :: Schedule
defaultSchedule = Schedule 16 30 "SceneName" (replicate 7 True)

instance FromJSON Schedule where
    parseJSON (Object o) =
        Schedule <$> o .:? "_sHour"   .!= _sHour   defaultSchedule
                 <*> o .:? "_sMinute" .!= _sMinute defaultSchedule
                 <*> o .:? "_sScene"  .!= _sScene  defaultSchedule
                 <*> o .:? "_sDays"   .!= _sDays   defaultSchedule
    parseJSON _ = mzero

instance ToJSON Schedule where
   toJSON Schedule { .. } =
      object [ "_sHour"   .= _sHour
             , "_sMinute" .= _sMinute
             , "_sScene"  .= _sScene
             , "_sDays"   .= _sDays
             ]

-- The newtype wrappers for the various string types give us problems with missing JSON
-- instances, just use coerce to safely reuse the ones we already got for plain String
instance FromJSON (HM.HashMap CookieUserID UserData) where
    parseJSON v = (\(a :: HM.HashMap String UserData) -> coerce a) <$> parseJSON v
instance ToJSON (HM.HashMap CookieUserID UserData) where
    toJSON v = toJSON (coerce v :: HM.HashMap String UserData)

data PersistConfig = PersistConfig
    { _pcBridgeIP     :: !IPAddress    -- IP address of the bridge
    , _pcBridgeUserID :: !BridgeUserID -- Hue bridge user ID for
    , _pcUserData     :: !UserDataMap  -- User ID cookie to user data
    , _pcScenes       :: !SceneMap     -- Scene name to scene settings
    , _pcSchedules    :: !ScheduleMap  -- Schedule name to schedule parameters
    } deriving (Show, Eq)

defaultPersistConfig :: PersistConfig
defaultPersistConfig = PersistConfig (IPAddress "") (BridgeUserID "") HM.empty HM.empty HM.empty

instance FromJSON PersistConfig where
    parseJSON (Object o) =
      PersistConfig <$> o .:? "_pcBridgeIP"  .!= _pcBridgeIP     defaultPersistConfig
                    <*> o .:? "_pcUserID"    .!= _pcBridgeUserID defaultPersistConfig
                    <*> o .:? "_pcUserData"  .!= _pcUserData     defaultPersistConfig
                    <*> o .:? "_pcScenes"    .!= _pcScenes       defaultPersistConfig
                    <*> o .:? "_pcSchedules" .!= _pcSchedules    defaultPersistConfig
    parseJSON _ = mzero

instance ToJSON PersistConfig where
   toJSON PersistConfig { .. }  =
       object [ "_pcBridgeIP"  .= _pcBridgeIP
              , "_pcUserID"    .= _pcBridgeUserID
              , "_pcUserData"  .= _pcUserData
              , "_pcScenes"    .= _pcScenes
              , "_pcSchedules" .= _pcSchedules
              ]

data UserData = UserData
    { _udVisibleGroupNames :: !(HS.HashSet GroupName) -- Groups which are not hidden / collapsed
    } deriving (Show, Eq)

defaultUserData :: UserData
defaultUserData = UserData HS.empty

instance FromJSON UserData where
    parseJSON (Object o) =
        UserData <$> o .:? "_udVisibleGroupNames" .!= _udVisibleGroupNames defaultUserData
    parseJSON _ = mzero

instance ToJSON UserData where
   toJSON UserData { .. }  =
      object [ "_udVisibleGroupNames" .= _udVisibleGroupNames
             ]

makeLenses ''Schedule
makeLenses ''UserData
makeLenses ''PersistConfig

-- Load / store / create persistent configuration

loadConfig :: MonadIO m => FilePath -> m (Maybe PersistConfig)
loadConfig fn = do
    -- Try to load persistent configuration into the state
    traceS TLInfo $ "Loading persistent configuration from'" <> fn <> "'"
    (liftIO $ Y.decodeFileEither fn) >>= \case
        Left e    -> do traceS TLError $
                         "Can't load configuration: " <> (Y.prettyPrintParseException e)
                        traceS TLInfo "Proceeding without prior configuration data"
                        return Nothing
        Right cfg -> do traceS TLInfo $ "Configuration (truncated): " <> (take 2048 $ show cfg)
                        return $ Just cfg

storeConfig :: MonadIO m => FilePath -> PersistConfig -> m ()
storeConfig fn cfg =
    liftIO $ Y.encodeFile fn cfg

