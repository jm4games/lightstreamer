{-# LANGUAGE OverloadedStrings #-}

module Lightstreamer.Client where

import Control.Monad.Trans.State.Lazy (evalState, modify, get)

import Data.Attoparsec.ByteString.Char8 (endOfLine, isEndOfLine, decimal, double)
import Data.Functor ((<$>))

import Lightstreamer.Http

import Network.BufferType (buf_fromStr, bufferOps)
import Network.HTTP (sendHTTP)
import Network.HTTP.Base (RequestMethod(POST), Response(..), Request(rqHeaders, rqBody)
                         , defaultNormalizeRequestOptions, mkRequest, normalizeRequest)
import Network.HTTP.Headers (HeaderName(HdrHost), mkHeader)
import Network.Stream (ConnError(..))
import Network.TCP (HandleStream, socketConnection, writeBlock)
import Network.URI (URI(..))

import qualified Data.Attoparsec.ByteString as AB
import qualified Data.ByteString as BS

import qualified Network.Socket as S

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

data StreamInfo = StreamInfo
    { controlLink :: Maybe BS.ByteString
    , keepAliveInMilli :: !Int
    , maxBandwidth :: !Double
    , preamble :: Maybe BS.ByteString
    , requestLimit :: Maybe Int
    , serverName :: Maybe BS.ByteString
    , sessionId :: !BS.ByteString
    } deriving Show

data StreamConnection = StreamConnection
    { streamInfo :: StreamInfo
    }

data LsError = LsError Int BS.ByteString | ConnectionError String deriving Show

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

newStreamConnection :: StreamRequest -> IO (Either LsError StreamInfo)
newStreamConnection req = do 
    addrInfos <- S.getAddrInfo (Just addrInfo) (Just $ srHost req) (Just . show $ srPort req)
    case addrInfos of
      [] -> retConnErr "Failed to get host address information"
      (a:_) -> do
          sock <- S.socket (S.addrFamily a) S.Stream S.defaultProtocol
          S.connect sock (S.addrAddress a)
          conn <- socketConnection (srHost req) (srPort req) sock :: IO (HandleStream BS.ByteString)
          mySendHTTP conn request
          result <- sendHTTP conn request 
          case result of
            Left x -> retConnErr $ 
              case x of
                ErrorReset -> "Connection Reset."
                ErrorClosed -> "Connection Closed."
                ErrorParse err -> err
                ErrorMisc err -> err
            Right res -> 
              case rspCode res of
                (2,0,_) -> do
                    putStrLn "Connected!"
                    print res 
                    print (rspBody res)
                    case AB.parseOnly streamInfoParser (rspBody res) of
                      Left err -> retConnErr err
                      Right x -> return x
                _ -> retConnErr $ rspReason res
    where 
        addrInfo = S.defaultHints { S.addrFamily = S.AF_UNSPEC, S.addrSocketType = S.Stream }
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

mySendHTTP :: HandleStream BS.ByteString -> Request BS.ByteString -> IO ()
mySendHTTP stream req = do
    _ <- writeBlock stream (buf_fromStr bufferOps $ show req)
    _ <- writeBlock stream (rqBody req)
    return ()

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

streamInfoParser :: AB.Parser (Either LsError StreamInfo)
streamInfoParser = AB.eitherP streamInfoErrParser streamInfoOkParser

streamInfoOkParser :: AB.Parser StreamInfo
streamInfoOkParser = do
    _ <- AB.string "OK"
    endOfLine
    sId <- parseTxtField "SessionId:"
    ctrlLink <- parseOptional $ parseTxtField "ControlAddress:"
    keep <- parseIntField "KeepaliveMillis:"
    maxB <- parseDblField "MaxBandwidth:"
    reqLimit <- parseOptional $ parseIntField "RequestLimit:"
    srv <- parseOptional $ parseTxtField "ServerName:"
    pre <- parseOptional $ parseTxtField "Preamble:"
    endOfLine
    return StreamInfo
        { controlLink = ctrlLink
        , keepAliveInMilli = keep
        , maxBandwidth = maxB
        , preamble = pre
        , requestLimit = reqLimit
        , serverName = srv
        , sessionId = sId
        }
    where 
        parseTxtField name = do
            _ <- AB.string name
            txt <- AB.takeTill isEndOfLine
            endOfLine
            return txt
        parseIntField name = do
            _ <- AB.string name
            val <- decimal
            endOfLine
            return val
        parseDblField name = do
            _ <- AB.string name
            val <- double
            endOfLine
            return val

parseOptional :: AB.Parser a -> AB.Parser (Maybe a)
parseOptional = AB.option Nothing . (<$>) Just

streamInfoErrParser :: AB.Parser LsError
streamInfoErrParser = do
    _ <- AB.string "ERROR"
    endOfLine
    errCode <- decimal
    endOfLine
    msg <- AB.takeTill isEndOfLine
    endOfLine
    return $ LsError errCode msg

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
