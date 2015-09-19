{-# LANGUAGE OverloadedStrings #-}

module Lightstreamer.Request
    ( HttpRequest
    , KeepAliveMode(..)
    , PollingMode(..)
    , RequestConverter(..)
    , StandardHeaders
    , StreamRequest(..)
    , createStandardHeaders
    , serializeHttpRequest
    ) where

import Blaze.ByteString.Builder (Builder, fromByteString, toByteString)
import Blaze.ByteString.Builder.Char8 (fromString, fromShow)

import Data.Monoid ((<>), mempty)

import qualified Data.ByteString as B

newtype HttpRequest = HttpRequest B.ByteString

newtype StandardHeaders = StandardHeaders Builder

class RequestConverter r where
    convertToHttp :: r -> StandardHeaders -> HttpRequest

data StreamRequest = StreamRequest
    { srAdapterSet :: String 
    , srConnectionMode :: Either KeepAliveMode PollingMode
    , srContentLength :: Maybe Int
    , srHost :: String 
    , srPassword :: Maybe String 
    , srPort :: Int
    , srRequestedMaxBandwidth :: Maybe Double
    , srReportInfo :: Maybe Bool
    , srUser ::  Maybe String 
    }

data KeepAliveMode = KeepAliveMode Int

data PollingMode = PollingMode
    { idelMillis :: Maybe Int
    , pollingMillis :: Int
    }

instance RequestConverter StreamRequest where
    convertToHttp req (StandardHeaders h) = HttpRequest . toByteString $
           fromByteString "POST /lightstreamer/create_session.txt?LS_op2=create\
                          \&LS_cid=mgQkwtwdysogQz2BJ4Ji%20kOj2Bg&LS_adapter_set="
        <> fromString (srAdapterSet req)
        <> srReportInfo req <>? ("&LS_reportInfo=" <>+ fromShow)
        <> srContentLength req <>? ("&LS_content_length" <>+ fromShow)
        <> srRequestedMaxBandwidth req <>? ("&LS_requested_max_bandwith=" <>+ fromShow)
        <> srPassword req <>? ("&LS_password=" <>+ fromString)
        <> srUser req <>? ("&LS_user=" <>+ fromString) <>
        case srConnectionMode req of
          Left (KeepAliveMode x) -> "&LS_keepalive_millis=" <> fromShow x
          Right y -> "&LS_polling=true&LS_polling_millis=" <> fromShow (pollingMillis y)
                     <> idelMillis y <>? ("&LS_idel_millis=" <>+ fromShow)
        <> " HTTP/1.1\r\n" <> h <> fromByteString "Content-Length: 0\r\n\r\n"

type ToBuilder a = a -> Builder

(<>+) :: B.ByteString -> ToBuilder a -> ToBuilder a 
b <>+ from = (<>) (fromByteString b) . from

(<>?) :: Maybe a -> ToBuilder a -> Builder
Nothing <>? _ = mempty
(Just x) <>? y = y x

createStandardHeaders :: String -> StandardHeaders
createStandardHeaders host = StandardHeaders $
       fromByteString "Host: " <> fromString host
    <> fromByteString "\r\nUser-Agent: Haskell Lightstreamer Client 0.1.0\r\n"

serializeHttpRequest :: HttpRequest -> B.ByteString
serializeHttpRequest (HttpRequest x) = x

