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

-- TODO: use try catch on HTTP invokes and translate to LsError

newStreamConnection :: StreamHandler h
                    => ConnectionSettings
                    -> StreamRequest
                    -> h 
                    -> IO (Either LsError StreamConnection)
newStreamConnection settings req handler = doHttpRequest $ do 
    conn <- newConnection settings 
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
    where 
        retConnErr = return . Left . ConnectionError

doHttpRequest :: IO (Either LsError a) -> IO (Either LsError a)
doHttpRequest action = do
    result <- try action 
    case result of
      Left err -> return . Left . ConnectionError $ showException err
      Right x -> return x

data BindRequest = BindRequest
    { brConnectionMode :: Either KeepAliveMode PollingMode
    , brContentLenght :: Maybe Int
    , brReportInfo :: Maybe Bool
    , brRequestedMaxBandwidth :: Maybe Int
    , brSession :: BS.ByteString
    }

bindToSession :: BindRequest -> Either String StreamConnection
bindToSession = undefined

data ControlConnection = ControlConnection

data OK = OK

subscribe :: ConnectionSettings -> SubscriptionRequest -> IO (Either LsError OK)
subscribe settings req = withRequest settings req $ \res ->
    case resBody res of
      ContentBody b -> undefined
      _ -> Left $ HttpError "Unexpected response."

withRequest :: RequestConverter r
            => ConnectionSettings
            -> r
            -> (HttpResponse -> Either LsError OK) 
            -> IO (Either LsError OK)
withRequest settings req action = do
    conn <- newConnection settings
    result <- try $ simpleHttpRequest conn req >>= (return . either (Left . ConnectionError) action)
    closeConnection conn
    case result of
      Left err -> return . Left . ConnectionError $ showException err
      Right x -> return x

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
