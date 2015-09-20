{-# LANGUAGE OverloadedStrings, RankNTypes #-}

module Lightstreamer.Streaming
    ( StreamInfo(..)
    , StreamHandler(..)
    , streamConsumer
    ) where

import Control.Concurrent.MVar (MVar, putMVar)
import Control.Monad.IO.Class (liftIO)

import Data.Attoparsec.ByteString (Parser, parseOnly, skipMany, string, takeTill)
import Data.Attoparsec.ByteString.Char8 (endOfLine, isEndOfLine
                                        , decimal, double, option)
import Data.ByteString (ByteString)
import Data.Conduit (Consumer, await)
import Data.Functor ((<$>))

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

-- TODO: handle completion of mvar is stream is corrupted before getting stream info

streamConsumer :: StreamHandler h => MVar StreamInfo -> h -> Consumer [ByteString] IO () 
streamConsumer varInfo handler = 
    await >>= maybe (liftIO $ putStrLn "No initial stream input ") consumeInfo
    where
        consumeInfo [] = streamConsumer varInfo handler
        consumeInfo (x:xs) =
            either 
                (liftIO . streamCorrupted handler) 
                (\i -> do
                   liftIO $ putMVar varInfo i >> streamOpened handler i
                   consumeValues xs)
                (parseOnly streamInfoParser x)
        loopConsume = await >>= maybe (return ()) consumeValues
        consumeValues [] = loopConsume 
        consumeValues values = liftIO (streamData handler values) >> loopConsume

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
