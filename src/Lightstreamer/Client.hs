{-# LANGUAGE OverloadedStrings #-}

module Lightstreamer.Client where

import Control.Exception (try)
import Control.Concurrent (ThreadId)
import Control.Concurrent.MVar (newEmptyMVar, takeMVar)

import Data.Functor ((<$>))
import Data.Attoparsec.ByteString.Char8 (endOfLine)
import Data.ByteString.Char8 (pack, unpack)

import Lightstreamer.Error (LsError(..), errorParser, showException)
import Lightstreamer.Http
import Lightstreamer.Request
import Lightstreamer.Streaming

import qualified Data.Attoparsec.ByteString as AB
import qualified Data.ByteString as BS

data StreamContext = StreamContext
    { info :: StreamInfo
    , threadId :: ThreadId
    }

-- TODO: use try catch on HTTP invokes and translate to LsError

newStreamConnection :: StreamHandler h
                    => ConnectionSettings
                    -> StreamRequest
                    -> h 
                    -> IO (Either LsError StreamContext)
newStreamConnection settings req handler = doHttpRequest $ do 
    conn <- newConnection settings 
    varInfo <- newEmptyMVar
    sendHttpRequest conn req 
    response <- readStreamedResponse conn (streamCorrupted handler . unpack) $ 
                  streamConsumer varInfo handler
    case response of
        Left err -> retConnErr err
        Right res ->
          if resStatusCode res /= 200 then
             return . Left $ HttpError (resStatusCode res) (resReason res)
          else
              case resBody res of
                ContentBody b -> 
                  return . Left . either (Unexpected . pack) id $ AB.parseOnly errorParser b
                StreamingBody tId -> do
                  valInfo <- takeMVar varInfo
                  return . Right $ StreamContext valInfo tId
                _ -> return . Left $ Unexpected "Unexpected response."
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

bindToSession :: BindRequest -> Either String StreamContext
bindToSession = undefined

data ControlConnection = ControlConnection

data OK = OK

subscribe :: ConnectionSettings -> SubscriptionRequest -> IO (Either LsError OK)
subscribe settings req = withRequest settings req $ \body ->
    case body of
      ContentBody b -> parseSimpleResponse b 
      _ -> Left $ Unexpected "Unexpected response."

withRequest :: RequestConverter r
            => ConnectionSettings
            -> r
            -> (HttpBody -> Either LsError OK) 
            -> IO (Either LsError OK)
withRequest settings req action = do
    conn <- newConnection settings
    result <- try $ either (Left . ConnectionError) doAction <$> simpleHttpRequest conn req
    closeConnection conn
    case result of
      Left err -> return . Left . ConnectionError $ showException err
      Right x -> return x
    where doAction res = 
            if resStatusCode res /= 200 then
                Left $ HttpError (resStatusCode res) (resReason res)
            else action $ resBody res

parseSimpleResponse :: BS.ByteString -> Either LsError OK 
parseSimpleResponse = either (Left . Unexpected . pack) id . AB.parseOnly resParser 
    where 
        resParser = AB.eitherP errorParser okParser
        okParser = do
            _ <- AB.string "OK"
            endOfLine
            return OK

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

sendMessage :: ConnectionSettings -> BS.ByteString -> BS.ByteString -> Either String OK
sendMessage = undefined
