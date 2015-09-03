module Lightstreamer.Client where

import qualified Data.ByteString as BS

data StreamRequest = StreamRequest
    { srAdapterSet :: BS.ByteString
    , srConnectionMode :: Either KeepAliveMode PollingMode
    , srContentLength :: Maybe Int
    , srPassword :: BS.ByteString
    , srRequestedMaxBandwidth :: Maybe Int
    , srReportInfo :: Maybe Bool
    , srUser :: BS.ByteString
    }

data KeepAliveMode = KeepAliveMode Int

data PollingMode = PollingMode
    { idelMillis :: Maybe Int
    , pollingMillis :: Int
    }

data StreamInfo = StreamInfo
    { controlLink :: Maybe BS.ByteString
    , keepAliveInMilli :: Int
    , maxBandwidth :: Int
    , preamble :: Maybe BS.ByteString
    , requestLimit :: Maybe Int
    , serverName :: Maybe BS.ByteString
    , sessionId :: BS.ByteString
    }

data StreamConnection = StreamConnection
    { streamInfo :: StreamInfo
    }

newStreamConnection :: StreamRequest -> Either String StreamConnection
newStreamConnection = undefined

data BindRequest = BindRequest
    { brConnectionMode :: Either KeepAliveMode PollingMode
    , brContentLenght :: Maybe Int
    , brReportInfo :: Maybe Bool
    , brRequestedMaxBandwidth :: Maybe Int
    , brSession :: BS.ByteString
    }

bindToSession :: BindRequest -> Either String StreamConnection
bindToSession = undefined

data ControlRequest = ControlRequest
    { crSession :: BS.ByteString
    , crTable :: BS.ByteString
    , crTableOperation :: TableOperation
    }

data TableOperation = TableAdd TableInfo 
                    | TableAddSilent TableInfo 
                    | TableStart TableInfo
                    | TableDelete

data TableInfo = TableInfo
    { tiDataAdapter :: Maybe BS.ByteString
    , tiId :: BS.ByteString
    , tiMode :: SubscriptionMode 
    , tiRequestedBufferSize :: Maybe Int
    , tiRequestedMaxFrequency :: Maybe UpdateFrequency
    , tiSchema :: BS.ByteString
    , tiSelector :: Maybe BS.ByteString
    , tiSnapshot :: Maybe Bool 
    }

data SubscriptionMode = Raw | Merge | Distinct | Command

data UpdateFrequency = Unfiltered | Frequency Double

data ControlConnection = ControlConnection

data OK = OK

newControlConnection :: ControlRequest -> Either String ControlConnection
newControlConnection = undefined

data ReconfigureRequest = ReconfigureRequest
    { rrRequestedMaxFrequency :: Maybe UpdateFrequency
    , rrSession :: BS.ByteString
    , rrTable :: BS.ByteString
    }

reconfigureSubscription :: ControlConnection -> ReconfigureRequest -> Either String OK
reconfigureSubscription = undefined

data ConstraintsRequest = ConstraintsRequest
    { orSession :: BS.ByteString
    , orRequestedMaxBandwith :: Maybe Int
    }

changeConstraints :: ControlConnection -> ConstraintsRequest -> Either String OK
changeConstraints = undefined

destroyControlConnection :: ControlConnection -> BS.ByteString -> Either String OK
destroyControlConnection = undefined

sendMessage :: StreamConnection -> BS.ByteString -> BS.ByteString -> Either String OK
sendMessage = undefined
