{-# LANGUAGE OverloadedStrings #-}

module Lightstreamer.StreamConnection where

import Data.Attoparsec.ByteString (Parser, string, takeTill)
import Data.Attoparsec.ByteString.Char8 (eitherP, endOfLine, isEndOfLine
                                        , decimal, double, option)
import Data.ByteString (ByteString)
import Data.Conduit (Consumer)
import Data.Functor ((<$>))

import Lightstreamer.Error

data StreamInfo = StreamInfo
    { controlLink :: Maybe ByteString
    , keepAliveInMilli :: !Int
    , maxBandwidth :: !Double
    , preamble :: Maybe ByteString
    , requestLimit :: Maybe Int
    , serverName :: Maybe ByteString
    , sessionId :: !ByteString
    } deriving Show

data StreamConnection = StreamConnection
    { streamInfo :: StreamInfo
    }

streamingInfoConsumer :: Consumer ByteString m (Either LsError StreamInfo)
streamingInfoConsumer = undefined

streamInfoResposneParser :: Parser (Either LsError StreamInfo)
streamInfoResposneParser = eitherP errorParser streamInfoParser

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
