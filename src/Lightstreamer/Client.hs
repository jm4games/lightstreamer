module Lightstreamer.Client where

import Network.HTTP (sendHTTP)
import Network.HTTP.Base (RequestMethod(POST), Response(..), mkRequest)
import Network.Stream (ConnError(..))
import Network.TCP (HandleStream, socketConnection)
import Network.URI (URI(..))

import qualified Data.ByteString as BS

import qualified Network.Socket as S

data StreamRequest = StreamRequest
    { srAdapterSet :: BS.ByteString
    , srConnectionMode :: Either KeepAliveMode PollingMode
    , srContentLength :: Maybe Int
    , srHost :: String 
    , srPassword :: BS.ByteString
    , srPath :: String
    , srPort :: Int
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
    } deriving Show

data StreamConnection = StreamConnection
    { streamInfo :: StreamInfo
    }

newStreamConnection :: StreamRequest -> IO (Either String StreamInfo)
newStreamConnection req = do 
    addrInfos <- S.getAddrInfo (Just addrInfo) (Just $ srHost req) (Just . show $ srPort req)
    case addrInfos of
      [] -> return $ Left "Failed to get host address information"
      (a:_) -> do
          sock <- S.socket (S.addrFamily a) S.Stream S.defaultProtocol
          S.connect sock (S.addrAddress a)
          conn <- socketConnection (srHost req) (srPort req) sock :: IO (HandleStream BS.ByteString)
          result <- sendHTTP conn (mkRequest POST reqUri)
          case result of
            Left x -> return $
              case x of
                ErrorReset -> Left "Connection Reset."
                ErrorClosed -> Left "Connection Closed."
                ErrorParse err -> Left err
                ErrorMisc err -> Left err
            Right res -> 
              case rspCode res of
                (2,0,_) -> do
                    putStrLn "Connected!"
                    putStrLn (show res) 
                    return $ Right StreamInfo {}
                _ -> return . Left $ rspReason res
    where 
        addrInfo = S.defaultHints { S.addrFamily = S.AF_UNSPEC, S.addrSocketType = S.Stream }
        reqUri = URI
            { uriScheme = "http:"
            , uriAuthority = Nothing
            , uriPath = "/lightstreamer/create_session.txt"
            , uriQuery = "?LS_op2=create&LS_cause=new.api&LS_polling=true&LS_polling_millis=0&LS_idle_millis=0&LS_cid=pcYgxn8m8%20feOojyA1S681l3g2.pz478mEb&LS_adapter_set=DynaGrid"
            , uriFragment = ""
            }

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
