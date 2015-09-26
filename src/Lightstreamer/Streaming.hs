{-# LANGUAGE OverloadedStrings, RankNTypes, DeriveDataTypeable #-}

module Lightstreamer.Streaming
    ( StreamException(..)
    , StreamInfo(..)
    , StreamHandler(..)
    , StreamState(..)
    , streamConsumer
    , streamContinuationConsumer
    ) where

import Control.Concurrent.MVar (MVar, putMVar)
import Control.Exception (Exception, throwIO)
import Control.Monad.IO.Class (liftIO)

import Data.Attoparsec.ByteString (Parser, parseOnly, skipMany, string, takeTill)
import Data.Attoparsec.ByteString.Char8 (endOfLine, isEndOfLine
                                        , decimal, double, option)
import Data.ByteString (ByteString, isPrefixOf)
import Data.Conduit (Consumer, await)
import Data.Functor ((<$>))
import Data.Typeable (Typeable)

data StreamInfo = StreamInfo
    { controlLink :: Maybe ByteString
    , keepAliveInMilli :: !Int
    , maxBandwidth :: !Double
    , requestLimit :: Maybe Int
    , serverName :: Maybe ByteString
    , sessionId :: !ByteString
    } deriving Show

class StreamHandler h where 
    streamClosed :: h -> IO ()
    streamClosed _ = return ()

    streamCorrupted :: h -> String -> IO ()
    streamCorrupted _ _ = return ()

    streamData :: h -> [ByteString] -> IO ()
    
    streamOpened :: h -> StreamInfo -> IO ()
    streamOpened _ _ = return ()

data StreamException = StreamException ByteString deriving (Show, Typeable)

instance Exception StreamException

data StreamState h = StreamState
    { rebindSession :: ByteString -> IO ()
    , streamHandler :: h
    }

-- TODO: handle completion of mvar is stream is corrupted before getting stream info

type CloseConnection = IO ()

streamConsumer :: StreamHandler h 
               => MVar StreamInfo 
               -> StreamState h
               -> CloseConnection 
               -> Consumer [ByteString] IO () 
streamConsumer varInfo st cc = 
    await >>= maybe (liftIO . throwIO $ StreamException "No initial stream input ") consumeInfo
    where
        consumeInfo [] = streamConsumer varInfo st  cc
        consumeInfo (x:xs) =
            either 
                (liftIO . streamCorrupted (streamHandler st))
                (\i -> do
                   liftIO $ putMVar varInfo i >> streamOpened (streamHandler st) i
                   consumeDataValues (sessionId i) st cc xs)
                (parseOnly streamInfoParser x)
        

streamContinuationConsumer :: StreamHandler h 
                           => ByteString 
                           -> StreamState h 
                           -> CloseConnection
                           -> Consumer [ByteString] IO ()
streamContinuationConsumer sId st cc = consumeDataValues sId st cc []

consumeDataValues :: StreamHandler h 
                  => ByteString
                  -> StreamState h
                  -> CloseConnection
                  -> [ByteString] 
                  -> Consumer [ByteString] IO ()
consumeDataValues sId st cc = consumeValues
    where
        loopConsume = await >>= maybe (return ()) consumeValues
        streamD = streamData $ streamHandler st
        consumeValues [] = loopConsume 
        consumeValues values = 
            if "LOOP" `isPrefixOf` last values then
                liftIO $ streamD (init values) >> cc >> rebindSession st sId
            else
                liftIO (streamD values) >> loopConsume

streamInfoParser :: Parser StreamInfo
streamInfoParser = do
    _ <- string "OK"
    endOfLine
    sId <- parseTxtField "SessionId:"
    ctrlLink <- parseOptional $ parseTxtField "ControlAddress:"
    keep <- parseIntField "KeepaliveMillis:"
    maxB <- parseDblField "MaxBandwidth:"
    reqLimit <- parseOptional $ parseIntField "RequestLimit:"
    srv <- parseOptional $ parseTxtField "ServerName:"
    skipMany $ parseTxtField "Preamble:"
    endOfLine
    return StreamInfo
        { controlLink = ctrlLink
        , keepAliveInMilli = keep
        , maxBandwidth = maxB
        , requestLimit = reqLimit
        , serverName = srv
        , sessionId = sId
        }
    where 
        parseTxtField name = do
            _ <- string name
            txt <- takeTill isEndOfLine
            endOfLine
            return txt
        parseIntField name = do
            _ <- string name
            val <- decimal
            endOfLine
            return val
        parseDblField name = do
            _ <- string name
            val <- double
            endOfLine
            return val

parseOptional :: Parser a -> Parser (Maybe a)
parseOptional = option Nothing . (<$>) Just
