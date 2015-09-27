{-# LANGUAGE OverloadedStrings, RankNTypes #-}

module Lightstreamer.Client
    ( OK
    , StreamContext(info, threadId)
    , changeConstraints
    , destroySession 
    , newStreamConnection
    , reconfigureSubscription
    , requestRebind
    , sendMessage
    , subscribe
    ) where

import Control.Exception (try, throwIO)
import Control.Concurrent (ThreadId, myThreadId)
import Control.Concurrent.MVar (newEmptyMVar, takeMVar)

import Data.Functor ((<$>))
import Data.Attoparsec.ByteString.Char8 (endOfLine)
import Data.ByteString (ByteString)
import Data.ByteString.Char8 (pack, unpack)
import Data.Conduit (Consumer)

import Lightstreamer.Error
import Lightstreamer.Http
import Lightstreamer.Request
import Lightstreamer.Streaming

import qualified Data.Attoparsec.ByteString as AB

data StreamContext = StreamContext
    { info :: StreamInfo
    , threadId :: ThreadId
    }

data OK = OK

newStreamConnection :: StreamHandler h
                    => ConnectionSettings
                    -> StreamRequest
                    -> h 
                    -> IO (Either LsError StreamContext)
newStreamConnection settings req handler = do 
    varInfo <- newEmptyMVar
    establishStreamConnection 
        settings 
        Nothing 
        req
        (streamCorrupted handler) 
        (streamConsumer varInfo st)
        (\tId -> takeMVar varInfo >>= \val -> return $ StreamContext val tId)
    where 
        st = StreamState { streamHandler = handler, rebindSession = rebind }
        rebind sId = do
            tId <- myThreadId
            result <- establishStreamConnection
                        settings
                        (Just tId)
                        (mkBindRequest sId req)
                        (streamCorrupted handler)
                        (streamContinuationConsumer sId st)
                        (\_ -> return ())
            case result of
              Left err -> throwIO . StreamException $
                case err of
                 LsError _ msg -> msg 
                 ConnectionError msg -> msg
                 ErrorPage msg -> msg
                 HttpError _ msg -> msg
                 Unexpected msg -> msg
              _ -> return ()

establishStreamConnection :: RequestConverter r
                          => ConnectionSettings 
                          -> Maybe ThreadId
                          -> r
                          -> (String -> IO ())
                          -> (IO () -> Consumer [ByteString] IO ())
                          -> (ThreadId -> IO a)
                          -> IO (Either LsError a)
establishStreamConnection settings tId req errHandle consumer resHandle = do
    result <- try action
    case result of
      Left err -> return . Left . ConnectionError $ showException err
      Right x -> return x
    where 
        action = do
            conn <- newConnection settings
            sendHttpRequest conn req
            response <- readStreamedResponse conn tId (errHandle . unpack) (consumer $ closeConnection conn)
            case response of
              Left err -> return . Left $ ConnectionError err
              Right res ->
                if resStatusCode res /= 200 then
                  return . Left $ HttpError (resStatusCode res) (resReason res)
                else
                  case resBody res of
                    ContentBody b ->
                       return . Left . either (Unexpected . pack) id $ AB.parseOnly errorParser b
                    StreamingBody newId -> Right <$> resHandle newId 
                    _ -> return . Left $ Unexpected "new stream response."

subscribe :: ConnectionSettings -> SubscriptionRequest -> IO (Either LsError OK)
subscribe = withSimpleRequest

withSimpleRequest :: RequestConverter r
                  => ConnectionSettings
                  -> r
                  -> IO (Either LsError OK)
withSimpleRequest settings req = do
    conn <- newConnection settings
    result <- try $ either (Left . ConnectionError) doAction <$> simpleHttpRequest conn req
    closeConnection conn
    case result of
      Left err -> return . Left . ConnectionError $ showException err
      Right x -> return x
    where doAction res = 
            if resStatusCode res /= 200 then
                Left $ HttpError (resStatusCode res) (resReason res)
            else
                case resBody res of
                  ContentBody b -> parseSimpleResponse b
                  _ -> Left $ Unexpected "response"

parseSimpleResponse :: ByteString -> Either LsError OK 
parseSimpleResponse = either (Left . Unexpected . pack) id . AB.parseOnly resParser 
    where 
        resParser = AB.choice [Right <$> okParser, Left <$> errorParser]
        okParser = do
            _ <- AB.string "OK"
            endOfLine
            return OK

reconfigureSubscription :: ConnectionSettings -> ReconfigureRequest -> IO (Either LsError OK)
reconfigureSubscription = withSimpleRequest

changeConstraints :: ConnectionSettings -> ConstraintsRequest -> IO (Either LsError OK)
changeConstraints = withSimpleRequest 

requestRebind :: ConnectionSettings -> ByteString -> IO (Either LsError OK)
requestRebind settings = withSimpleRequest settings . RebindRequest 

destroySession :: ConnectionSettings -> ByteString -> IO (Either LsError OK)
destroySession settings = withSimpleRequest settings . DestroyRequest

sendMessage :: ConnectionSettings -> ByteString -> ByteString -> Either String OK
sendMessage = undefined
