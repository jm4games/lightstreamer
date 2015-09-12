{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

module Lightstreamer.Http
    ( HttpConnection
    , HttpBody(..)
    , HttpException(..)
    , HttpHeader(..)
    , HttpResponse
        ( resBody
        , resHeaders
        , resReason
        , resStatusCode
        )
    , newHttpConnection
    , readStreamedResponse
    , sendHttpRequest
    ) where

import Control.Concurrent (ThreadId, forkIO)
import Control.Exception (Exception, throwIO)
import Control.Monad (unless)
import Control.Monad.IO.Class (MonadIO(..))

import Data.ByteString.Char8 (readInt)
import Data.ByteString.Lazy (toStrict)
import Data.ByteString.Lex.Integral (readHexadecimal)
import Data.Conduit (Consumer, Conduit, Producer, ($$+), ($$+-), ($=+), await, leftover, yield)
import Data.Conduit.Network (sourceSocket)
import Data.Functor ((<$>))
import Data.List (find)
import Data.Typeable (Typeable)

import Debug.Trace (trace)

import Network.BufferType (buf_fromStr, bufferOps)
import Network.HTTP.Base (Request(rqBody))
import Network.TCP (HandleStream, socketConnection, writeBlock)

import qualified Data.ByteString as B
import qualified Data.Conduit.Binary as CB
import qualified Data.Word8 as W

import qualified Network.Socket as S

data HttpConnection = HttpConnection
    { connection :: HandleStream B.ByteString
    , socket :: S.Socket
    } 

data HttpException = HttpException B.ByteString deriving (Show, Typeable)

instance Exception HttpException where
    
data HttpHeader = HttpHeader B.ByteString B.ByteString deriving Show

data HttpBody = StreamingBody ThreadId | ContentBody B.ByteString | None deriving Show

data HttpResponse = HttpResponse
    { resBody :: HttpBody 
    , resHeaders :: [HttpHeader]
    , resReason :: B.ByteString
    , resStatusCode :: Int
    } deriving Show

newHttpConnection :: String -> Int -> IO (Either B.ByteString HttpConnection)
newHttpConnection host port = do
    addrInfos <- S.getAddrInfo (Just addrInfo) (Just host) (Just $ show port)
    case addrInfos of
      [] -> return $ Left "Failed to get host address information"
      (a:_) -> do
          sock <- S.socket (S.addrFamily a) S.Stream S.defaultProtocol
          S.connect sock (S.addrAddress a)
          Right . flip HttpConnection sock <$> socketConnection host port sock
    where addrInfo = S.defaultHints { S.addrFamily = S.AF_UNSPEC, S.addrSocketType = S.Stream }

sendHttpRequest :: HttpConnection -> Request B.ByteString -> IO ()
sendHttpRequest (HttpConnection { connection = conn }) req = do
    _ <- writeBlock conn (buf_fromStr bufferOps $ show req)
    _ <- writeBlock conn (rqBody req)
    return ()

httpConnectionProducer :: HttpConnection -> Producer IO B.ByteString
httpConnectionProducer (HttpConnection { socket = sock }) = sourceSocket sock

readStreamedResponse :: HttpConnection 
                     -> Consumer [B.ByteString] IO () 
                     -> IO (Either B.ByteString HttpResponse)
readStreamedResponse conn streamSink = do 
    (rSrc, res) <- httpConnectionProducer conn $$+ readHttpHeader
    --putStrLn "Response:"
    --print res
    case find contentHeader $ resHeaders res of
      Just (HttpHeader "Content-Length" val) -> do
        body <- rSrc $$+- (CB.take . maybe 0 fst $ readInt val)
        return $ Right res { resBody = ContentBody $ toStrict body } 
      
      Just (HttpHeader "Transfer-Encoding" _) -> do
        tId <- forkIO (rSrc $=+ chunkConduit B.empty $$+- streamSink)
        return $ Right res { resBody = StreamingBody tId }
      _ -> 
        throwIO $ HttpException "Could not determine body type of response."
                
    where
        contentHeader (HttpHeader "Content-Length" _) = True
        contentHeader (HttpHeader "Transfer-Encoding" _) = True
        contentHeader _ = False

readHttpHeader :: Consumer B.ByteString IO HttpResponse
readHttpHeader = loop [] Nothing 
    where
        loop acc res = await >>= maybe (complete acc res) (build acc res)
        
        complete [rest] (Just res) = do
            leftover rest
            return res
        complete _ (Just _) = liftIO . throwIO $ HttpException "Unexpected response."
        complete _ Nothing = liftIO . throwIO $ HttpException "No response provided."
        
        -- builds header collection
        -- @acc - collection of partial buffers that will be combined upon a new line char
        -- @res - Http Response being built
        -- @more - buffer from most recent await 
        build acc res more = 
            case B.uncons p2 of
              -- dropping \r
              Just (_, rest) 
                | B.null p1 -> complete [B.drop 1 rest] res
                | otherwise -> 
                  case parse (B.concat . reverse $ p1:acc) res of
                    Left err -> liftIO . throwIO $ HttpException err 
                    Right res' -> build [] res' $ B.drop 1 rest -- drop 1 = \n

              Nothing -> loop (p1:acc) res
            where 
                (p1, p2) = B.breakByte W._cr more  
                parse bytes Nothing = 
                    let top = B.split W._space bytes
                    in case top of
                         [_, code, msg] -> Right $ Just HttpResponse
                                              { resStatusCode = maybe 0 fst $ readInt code
                                              , resReason = msg
                                              , resHeaders = []
                                              , resBody = None
                                              }
                         _ -> Left "Invalid HTTP response."
                parse bytes (Just a) =
                    let header = let (name, value) = B.breakByte W._colon bytes
                                 in HttpHeader name (B.dropWhile (==W._space) $ B.drop 1 value) 
                    in Right $ Just a { resHeaders = header : resHeaders a } 

chunkConduit :: B.ByteString -> Conduit B.ByteString IO [B.ByteString]
chunkConduit partial = await >>= maybe (return ()) build
    where
        build
            | partial /= B.empty = yieldChunks . B.append partial 
            | otherwise = yieldChunks
        yieldChunks bytes =
            case readChunks bytes of
              Left err -> liftIO . throwIO $ HttpException err 
              Right (chunks, rest) -> do
                yield chunks
                chunkConduit rest

readChunks :: B.ByteString -> Either B.ByteString ([B.ByteString], B.ByteString)
readChunks = loop [] 
    where 
        loop acc buf 
            | buf == B.empty = retRight acc B.empty
            | otherwise = 
                 if p1 == B.empty then Left "Invalid chunk stream."
                 else case octToDec p1 of
                        Left err -> Left err
                        Right 0 -> retRight acc B.empty
                        Right size -> 
                          if B.length p2 > size then
                            let (chunk, rest) = B.splitAt size $ B.drop 2 p2
                            in loop (chunk:acc) $ B.drop 2 rest
                          else retRight acc buf 
                where (p1, p2) = B.breakByte W._cr buf
        retRight acc rest = Right (reverse acc, rest)
        octToDec = 
            maybe (Left "Invalid hexidecimal number.") (Right . fst) . readHexadecimal
