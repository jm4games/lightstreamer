{-# LANGUAGE RankNTypes #-}

module Lightstreamer.Http
    ( HttpConnection
    , httpConnectionResumableSrc
    , newHttpConnection
    , sendHttpRequest
    ) where

import Control.Monad.IO.Class (MonadIO)

import Data.ByteString (ByteString)
import Data.Conduit (ResumableSource, newResumableSource)
import Data.Conduit.Network (sourceSocket)
import Data.Functor ((<$>))

import Network.BufferType (buf_fromStr, bufferOps)
import Network.HTTP.Base (Request(rqBody))
import Network.TCP (HandleStream, socketConnection, writeBlock)

import qualified Network.Socket as S

data HttpConnection = HttpConnection
    { connection :: HandleStream ByteString
    , socket :: S.Socket
    } 

newHttpConnection :: String -> Int -> IO (Either String HttpConnection)
newHttpConnection host port = do
    addrInfos <- S.getAddrInfo (Just addrInfo) (Just host) (Just $ show port)
    case addrInfos of
      [] -> return $ Left "Failed to get host address information"
      (a:_) -> do
          sock <- S.socket (S.addrFamily a) S.Stream S.defaultProtocol
          S.connect sock (S.addrAddress a)
          Right . flip HttpConnection sock <$> socketConnection host port sock
    where addrInfo = S.defaultHints { S.addrFamily = S.AF_UNSPEC, S.addrSocketType = S.Stream }

sendHttpRequest :: HttpConnection -> Request ByteString -> IO ()
sendHttpRequest (HttpConnection { connection = conn }) req = do
    _ <- writeBlock conn (buf_fromStr bufferOps $ show req)
    _ <- writeBlock conn (rqBody req)
    return ()

httpConnectionResumableSrc :: MonadIO m => HttpConnection -> ResumableSource m ByteString
httpConnectionResumableSrc (HttpConnection { socket = sock }) = 
    newResumableSource $ sourceSocket sock

