{-# LANGUAGE OverloadedStrings #-}

module Lightstreamer.Client where

import Control.Exception (try)

import Data.ByteString.Char8 (pack, unpack)

import Lightstreamer.Error (LsError(..), errorParser, showException)
import Lightstreamer.Http
import Lightstreamer.Request
import Lightstreamer.Streaming

import qualified Data.Attoparsec.ByteString as AB
import qualified Data.ByteString as BS

data StreamConnection = StreamConnection
    { httpConnection :: Connection
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

newStreamConnection :: StreamHandler h
                    => StreamRequest
                    -> h 
                    -> IO (Either LsError StreamConnection)
newStreamConnection req handler = do 
    result <- try $ do
      conn <- newHttpConnection (srHost req) (srPort req)
      sendHttpRequest conn req 
      response <- readStreamedResponse conn (streamCorrupted handler . unpack) $ 
                    streamConsumer handler
      case response of
          Left err -> retConnErr err
          Right res ->
            if resStatusCode res /= 200 then
               return . Left $ HttpError (resReason res) 
            else
                case resBody res of
                  ContentBody b -> 
                    return . Left . either (HttpError . pack) id $ AB.parseOnly errorParser b
                  StreamingBody _ ->
                    return . Right $ StreamConnection
                        { httpConnection = conn
                        } 
                  _ -> return . Left $ HttpError "Unexpected response."
    case result of
      Left err -> retConnErr $ showException err
      Right x -> return x 
    where 
        retConnErr = return . Left . ConnectionError

closeStreamConnection :: StreamConnection -> IO ()
closeStreamConnection (StreamConnection { httpConnection = conn }) =
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
