{-# LANGUAGE OverloadedStrings, RankNTypes, DeriveDataTypeable #-}

module Lightstreamer.Streaming
    ( MessageFailure(..)
    , MessageInfo(..)
    , OverflowInfo(..)
    , SnapshotInfo(..)
    , StreamException(..)
    , StreamHandler(..)
    , StreamInfo(..)
    , StreamItem(..)
    , StreamState(..)
    , TableEntry(..)
    , streamConsumer
    , streamContinuationConsumer
    ) where

import Control.Concurrent.MVar (MVar, putMVar)
import Control.Exception (Exception, throwIO)
import Control.Monad.IO.Class (liftIO)

import Data.Attoparsec.ByteString.Char8 (endOfLine, isEndOfLine , decimal, double, option)
import Data.ByteString (ByteString)
import Data.Conduit (Consumer, await)
import Data.Functor ((<$>))
import Data.Typeable (Typeable)

import qualified Data.Attoparsec.ByteString as AB
import qualified Data.Word8 as W

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

    streamData :: h -> [StreamItem] -> IO ()
    
    streamOpened :: h -> StreamInfo -> IO ()
    streamOpened _ _ = return ()

data StreamException = StreamException ByteString deriving (Show, Typeable)

instance Exception StreamException

data StreamState h = StreamState
    { rebindSession :: ByteString -> IO ()
    , streamHandler :: h
    }

data StreamItem = End
                | EndSnapshot SnapshotInfo
                | EndWithCause Int ByteString
                | Loop 
                | Message MessageInfo
                | ParseError String
                | Probe 
                | Overflow OverflowInfo
                | Undefined ByteString
                | Update TableEntry 
                deriving (Show, Eq)

data SnapshotInfo = SnapshotInfo
    { siItem :: ByteString
    , siTable :: ByteString
    } deriving (Show, Eq)

data TableEntry = TableEntry
    { teItem :: ByteString
    , teName :: ByteString
    , teValues :: [ByteString]
    } deriving (Show, Eq)

data OverflowInfo = OverflowInfo
    { ofItem :: ByteString
    , ofOverflowSize :: Int
    , ofTable :: ByteString
    } deriving (Show, Eq)

data MessageInfo = MessageInfo
    { miProgressiveNumber :: Int
    , miSequenceId :: ByteString
    , miFailure :: Maybe MessageFailure
    } deriving (Show, Eq)

data MessageFailure = MessageFailure
    { mfErrorCode :: Int
    , mfErrorMessage :: ByteString
    } deriving (Show, Eq)

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
                (AB.parseOnly streamInfoParser x)

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
        consumeValues = processValues . filter (Probe /=) . map parseData
            where parseData = either ParseError id . AB.parseOnly streamDataParser
        processValues [] = loopConsume
        processValues values = 
            if last values == Loop then
                liftIO $ streamD (init values) >> cc >> rebindSession st sId
            else
                liftIO (streamD values) >> loopConsume

streamInfoParser :: AB.Parser StreamInfo
streamInfoParser = do
    _ <- AB.string "OK"
    endOfLine
    sId <- parseTxtField "SessionId:"
    ctrlLink <- parseOptional $ parseTxtField "ControlAddress:"
    keep <- parseIntField "KeepaliveMillis:"
    maxB <- parseDblField "MaxBandwidth:"
    reqLimit <- parseOptional $ parseIntField "RequestLimit:"
    srv <- parseOptional $ parseTxtField "ServerName:"
    AB.skipMany $ parseTxtField "Preamble:"
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
parseOptional = option Nothing . (<$>) Just

streamDataParser :: AB.Parser StreamItem
streamDataParser =
    AB.choice [tableBasedParser, probeParser, loopParser, msgParser, endParser, undefinedParser]
    where
        comma = (W._comma ==)

        tableBasedParser = do
            table <- AB.takeTill comma 
            AB.skip comma
            item <- AB.takeTill (\x -> bar x || comma x)
            nxt <- AB.peekWord8'
            if nxt == W._bar then do
                AB.skip bar
                values <- AB.takeTill (\x -> bar x || isEndOfLine x) `AB.sepBy` AB.word8 W._bar
                endOfLine
                return . Update $ TableEntry
                    { teItem = item
                    , teName = table
                    , teValues = values
                    }
            else
                AB.skip comma >> AB.choice [endSnapParser table item, overflowParser table item]
            where
                bar = (W._bar==)
                endSnapParser tbl item = 
                    AB.string "EOS" >> endOfLine >> 
                      (return . EndSnapshot $ SnapshotInfo { siItem = item, siTable = tbl })
                overflowParser tbl item = do
                    _ <- AB.string "OV"
                    size <- decimal
                    endOfLine
                    return . Overflow $ OverflowInfo
                        { ofItem = item
                        , ofOverflowSize = size
                        , ofTable = tbl
                        }

        undefinedParser = do
            val <- AB.takeTill isEndOfLine 
            endOfLine
            return $ Undefined val

        msgParser = do
            _ <- AB.string "MSG"
            AB.skip comma
            seqId <- AB.takeTill comma
            AB.skip comma
            prog <- decimal
            AB.skip comma
            let msgInfo = MessageInfo 
                    { miSequenceId = seqId
                    , miProgressiveNumber = prog
                    , miFailure = Nothing
                    }
            Message <$> AB.choice [doneParser msgInfo, errParser msgInfo]
            where
                doneParser = (AB.string "DONE" >> endOfLine >>) . return
                errParser nfo = do
                    _ <- AB.string "ERR"
                    AB.skip comma
                    code <- decimal
                    msg <- AB.takeTill isEndOfLine
                    endOfLine
                    return nfo 
                        { miFailure = Just MessageFailure 
                            {  mfErrorCode = code
                            , mfErrorMessage = msg 
                            } 
                        }

        loopParser = AB.string "LOOP" >> endOfLine >> return Loop
        probeParser = AB.string "PROBE" >> endOfLine >> return Probe
        endParser = AB.string "END" >> AB.choice [causeParser, endOfLine >> return End]
            where 
                causeParser = do
                    _ <- AB.string " "
                    code <- decimal
                    AB.skipWhile (W._space==)
                    endOfLine
                    return $ EndWithCause code (errMsg code) 
                errMsg 7  = "Licensed maximum number of sessions reached."
                errMsg 8  = "Configured maximum number of sessions reached."
                errMsg 31 = "The session was closed by the administrator through a\
                            \ \"destroy\" request."
                errMsg 32 = "The session was closed by the administrator through JMX."
                errMsg 33 = errMsg 34
                errMsg 34 = "An unexpected error occurred on the Server while the\
                            \ session was in activity."
                errMsg 35 = "The Metadata Adapter does not allow more than one session\
                            \ for the current user and has requested the closure of the\
                            \ current session upon opening of a new session for the\
                            \ same user by some client."
                errMsg 40 = "A manual rebind to the same session has been performed by\
                            \ some client."
                errMsg 48 = "The maximum session duration configured on the Server has\
                            \ been reached. This is only meant as a way to refresh the\
                            \ session (for instance, to force a different association\
                            \ in a clustering scenario), hence the client should\
                            \ recover by opening a new session immediately."
                errMsg _ = "Error message not available."
