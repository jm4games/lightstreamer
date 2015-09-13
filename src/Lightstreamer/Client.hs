{-# LANGUAGE OverloadedStrings #-}

module Lightstreamer.Client where

import Control.Concurrent.Async (Async, cancel)
import Control.Monad.Trans.State.Lazy (evalState, modify, get)

import Data.ByteString.Char8 (pack)

import Lightstreamer.Error (LsError(..), errorParser)
import Lightstreamer.Http
import Lightstreamer.Streaming

import Network.HTTP.Base (RequestMethod(POST), Request(rqHeaders)
                         , defaultNormalizeRequestOptions, mkRequest, normalizeRequest)
import Network.HTTP.Headers (HeaderName(HdrHost), mkHeader)
import Network.URI (URI(..))

import qualified Data.Attoparsec.ByteString as AB
import qualified Data.ByteString as BS

data StreamRequest = StreamRequest
    { srAdapterSet :: String 
    , srConnectionMode :: Either KeepAliveMode PollingMode
    , srContentLength :: Maybe Int
    , srHost :: String 
    , srPassword :: Maybe String 
    , srPort :: Int
    , srRequestedMaxBandwidth :: Maybe Double
    , srReportInfo :: Maybe Bool
    , srUser ::  Maybe String 
    }

data KeepAliveMode = KeepAliveMode Int

data PollingMode = PollingMode
    { idelMillis :: Maybe Int
    , pollingMillis :: Int
    }

data StreamConnection = StreamConnection
    { httpConnection :: HttpConnection
    , streamAsync :: Async ()
    }

defaultStreamRequest :: String -> String -> Int -> StreamRequest
defaultStreamRequest adapter host port = StreamRequest
    { srAdapterSet = adapter
    , srConnectionMode = Left $ KeepAliveMode 600
    , srContentLength = Nothing
    , srHost = host
    , srPassword = Nothing
    , srPort = port
    , srRequestedMaxBandwidth = Nothing
    , srReportInfo = Nothing
    , srUser = Nothing 
    }

-- TODO: use try catch on HTTP invokes and translate to LsError

newStreamConnection :: StreamRequest -> IO (Either LsError StreamConnection)
newStreamConnection req = do 
    result <- newHttpConnection (srHost req) (srPort req)
    case result of
      Left err -> retConnErr err
      Right conn -> do
        sendHttpRequest conn request
        response <- readStreamedResponse conn streamConsumer 
        case response of
          Left err -> retConnErr err
          Right res ->
            if resStatusCode res /= 200 then
               return . Left $ HttpError (resReason res) 
            else
                case resBody res of
                  ContentBody b -> 
                    return . Left . either (HttpError . pack) id $ AB.parseOnly errorParser b
                  StreamingBody a ->
                    return . Right $ StreamConnection
                        { httpConnection = conn
                        , streamAsync = a
                        } 
                  _ -> return . Left $ HttpError "Unexpected response." 
    where 
        headers = [mkHeader HdrHost $ srHost req]
        request = normalizeRequest defaultNormalizeRequestOptions $ 
                    (mkRequest POST reqUri) { rqHeaders = headers }
        reqUri = URI
            { uriScheme = ""
            , uriAuthority = Nothing
            , uriPath = "/lightstreamer/create_session.txt"
            , uriQuery = buildStreamQueryString req 
            , uriFragment = ""
            }
        retConnErr = return . Left . ConnectionError

buildStreamQueryString :: StreamRequest -> String
buildStreamQueryString sr = flip evalState initial $ do
    appendM ("&LS_user=" ++) $ srUser sr
    appendM ("&LS_password=" ++) $ srPassword sr
    case srConnectionMode sr of
      Left (KeepAliveMode x) -> append $ "&LS_keepalive_millis=" ++ show x
      Right y -> append $ "&LS_polling=true&LS_polling_millis=" ++ show (pollingMillis y) ++
                          "&LS_idle_millis" ++ show (idelMillis y)
    appendM ((++) "&LS_content_length" . show) $ srContentLength sr
    appendM ((++) "&LS_report_info" . show) $ srReportInfo sr
    appendM ((++) "&LS_requested_max_bandwith=" . show) $ srRequestedMaxBandwidth sr
    append "?"
    get
    where
        initial = "&LS_op2=create&LS_cid=mgQkwtwdysogQz2BJ4Ji%20kOj2Bg&LS_adapter_set=" ++ srAdapterSet sr 
        append val = modify (\s -> val ++ s)
        appendM f = maybe (return ()) (append . f)

closeStreamConnection :: StreamConnection -> IO ()
closeStreamConnection (StreamConnection { httpConnection = conn, streamAsync = a }) = do
    cancel a
    closeHttpConnection conn

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
