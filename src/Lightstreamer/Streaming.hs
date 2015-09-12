{-# LANGUAGE OverloadedStrings #-}

module Lightstreamer.Streaming where

import Control.Monad (forM_)
import Control.Monad.IO.Class (liftIO)

import Data.Attoparsec.ByteString (Parser, parseOnly, many', string, takeTill)
import Data.Attoparsec.ByteString.Char8 (eitherP, endOfLine, isEndOfLine
                                        , decimal, double, option)
import Data.ByteString (ByteString)
import Data.Conduit (Consumer, await)
import Data.Functor ((<$>))

import Lightstreamer.Error

data StreamInfo = StreamInfo
    { controlLink :: Maybe ByteString
    , keepAliveInMilli :: !Int
    , maxBandwidth :: !Double
    , preamble :: [ByteString]
    , requestLimit :: Maybe Int
    , serverName :: Maybe ByteString
    , sessionId :: !ByteString
    } deriving Show

data StreamConnection = StreamConnection
    { streamInfo :: StreamInfo
    }

streamConsumer :: Consumer [ByteString] IO () 
streamConsumer = 
    await >>= maybe (liftIO $ putStrLn "No initial stream input ") consumeInfo
    where
        consumeInfo [] = streamConsumer
        consumeInfo (x:xs) = do
            let info = parseOnly streamInfoParser x
            liftIO $ putStrLn "Stream Info:"
            liftIO $ print info
            consumeValues xs
        loopConsume = await >>= maybe (return ()) consumeValues
        consumeValues [] = loopConsume 
        consumeValues values = liftIO (forM_ values print) >> loopConsume

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
    pre <- many' $ parseTxtField "Preamble:"
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
