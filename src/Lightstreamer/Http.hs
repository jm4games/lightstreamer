{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

module Lightstreamer.Http
    ( HttpConnection
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

import Control.Monad.IO.Class (MonadIO)

import Data.ByteString.Char8 (readInt)
import Data.ByteString.Lazy (toStrict)
import Data.Conduit (Consumer, Producer, ($$+), ($$+-), await, closeResumableSource)
import Data.Conduit.Network (sourceSocket)
import Data.Functor ((<$>))
import Data.List (find)
import Data.Word8 (_colon, _space)

import Network.BufferType (buf_fromStr, bufferOps)
import Network.HTTP.Base (Request(rqBody))
import Network.TCP (HandleStream, socketConnection, writeBlock)

import qualified Data.ByteString as B
import qualified Data.Conduit.Binary as CB

import qualified Network.Socket as S

data HttpConnection = HttpConnection
    { connection :: HandleStream B.ByteString
    , socket :: S.Socket
    } 

data HttpHeader = HttpHeader B.ByteString B.ByteString

data HttpBody = StreamingBody | ContentBody B.ByteString | None

data HttpResponse = HttpResponse
    { resBody :: HttpBody 
    , resHeaders :: [HttpHeader]
    , resReason :: B.ByteString
    , resStatusCode :: Int
    }

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

httpConnectionProducer :: MonadIO m => HttpConnection -> Producer m B.ByteString
httpConnectionProducer (HttpConnection { socket = sock }) = sourceSocket sock

readHttpResponse :: Monad m
                 => Maybe HttpResponse 
                 -> Consumer B.ByteString m (Either B.ByteString HttpResponse)
readHttpResponse res = do
    maybeVal <- await
    case maybeVal of
      Nothing -> response 
      Just val ->
        if B.null val then response 
        else case res of
                Just a -> 
                  let header = uncurry HttpHeader $ B.breakByte _colon val 
                  in readHttpResponse $ Just a { resHeaders = header : resHeaders a } 

                Nothing ->
                  let top = B.split _space val
                  in case top of
                       [_, code, msg] -> readHttpResponse $ Just HttpResponse
                                            { resStatusCode = maybe 0 fst $ readInt code
                                            , resReason = msg
                                            , resHeaders = []
                                            , resBody = None
                                            }
                       _ -> return $ Left "Invalid HTTP response."
    where response = return $ maybe (Left "No response received.") Right res 

readStreamedResponse :: MonadIO m
                     => HttpConnection 
                     -> Consumer B.ByteString m () 
                     -> m (Either B.ByteString HttpResponse)
readStreamedResponse conn streamSink = do 
    (rSrc, result) <- httpConnectionProducer conn $$+ readHttpResponse Nothing
    case result of
      Left err -> closeResumableSource rSrc >> (return $ Left err)
      Right res -> 
        case find contentHeader $ resHeaders res of
          Just (HttpHeader _ val) -> do
              body <- rSrc $$+- (CB.take . maybe 0 fst $ readInt val)
              return $ Right res { resBody = ContentBody $ toStrict body } 
          Nothing -> undefined
    where
        contentHeader (HttpHeader "Content-Length" _) = True
        contentHeader _ = False

