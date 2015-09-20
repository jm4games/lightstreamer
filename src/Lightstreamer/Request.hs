{-# LANGUAGE OverloadedStrings #-}

module Lightstreamer.Request
    ( HttpRequest
    , KeepAliveMode(..)
    , PollingMode(..)
    , RequestConverter(..)
    , Snapshot(..)
    , StandardHeaders
    , StreamRequest(..)
    , SubscriptionMode(..)
    , SubscriptionRequest(..)
    , TableInfo(..)
    , TableOperation(..)
    , UpdateFrequency(..)
    , createStandardHeaders
    , defaultStreamRequest
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
    , srPassword :: Maybe String 
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
    convertToHttp req h = HttpRequest . toByteString $
        ("POST /lightstreamer/create_session.txt?LS_op2=create\
        \&LS_cid=mgQkwtwdysogQz2BJ4Ji%20kOj2Bg&LS_adapter_set="
        <>+ fromString $ srAdapterSet req)
        <> srReportInfo req <>? ("&LS_reportInfo=" <>+ fromShow)
        <> srContentLength req <>? ("&LS_content_length" <>+ fromShow)
        <> srRequestedMaxBandwidth req <>? ("&LS_requested_max_bandwith=" <>+ fromShow)
        <> srPassword req <>? ("&LS_password=" <>+ fromString)
        <> srUser req <>? ("&LS_user=" <>+ fromString) <>
        case srConnectionMode req of
          Left (KeepAliveMode x) -> "&LS_keepalive_millis=" <> fromShow x
          Right y -> "&LS_polling=true&LS_polling_millis=" <> fromShow (pollingMillis y)
                     <> idelMillis y <>? ("&LS_idel_millis=" <>+ fromShow)
        <> requestEnd h

data SubscriptionRequest = ControlRequest
    { subSession :: B.ByteString
    , subTable :: B.ByteString
    , subTableOperation :: TableOperation
    }

data TableOperation = TableAdd TableInfo 
                    | TableAddSilent TableInfo 
                    | TableStart TableInfo
                    | TableDelete

data TableInfo = TableInfo
    { tiDataAdapter :: Maybe B.ByteString
    , tiId :: B.ByteString
    , tiMode :: SubscriptionMode 
    , tiRequestedBufferSize :: Maybe Int
    , tiRequestedMaxFrequency :: Maybe UpdateFrequency
    , tiSchema :: B.ByteString
    , tiSelector :: Maybe B.ByteString
    , tiSnapshot :: Maybe Snapshot
    }

data SubscriptionMode = Raw | Merge | Distinct | Command

data UpdateFrequency = Unfiltered | Frequency Double

data Snapshot = SnapTrue | SnapFalse | SnapLen Int

instance RequestConverter SubscriptionRequest where
    convertToHttp req h = HttpRequest . toByteString $
         "POST /lighstreamer/control.txt&LS_session="
      <> fromByteString (subSession req)
      <> ("&LS_table=" <>+ fromByteString $ subTable req) <>
      case subTableOperation req of
        TableDelete -> "&LS_op=delete"
        TableAdd t -> tbleOpts "&LS_op=add" t
        TableAddSilent t -> tbleOpts "&LS_op=add_silient" t
        TableStart t -> tbleOpts "&LS_op=start" t
      where 
          tbleOpts op t = op <>
            ("&LS_op=add&lsId=" <>+ fromByteString $ tiId t)
            <> ("&LS_schema=" <>+ fromByteString $ tiSchema t)
            <> subMode (tiMode t) 
            <> tiDataAdapter t <>? ("&LS_data_adapter=" <>+ fromByteString)
            <> tiRequestedBufferSize t <>? ("&LS_requested_buffer_size=" <>+ fromShow)
            <> tiRequestedMaxFrequency t <>? ("&LS_requested_max_frequency=" <>+ fromUpdateFreq)
            <> tiSelector t <>? ("&LS_selector=" <>+ fromByteString)
            <> tiSnapshot t <>? ("&LS_snapshot=" <>+ fromSnapshot)
            <> requestEnd h
          subMode x = 
            case x of
              Raw -> "&LS_mode=raw"
              Merge -> "&LS_mode=merge"
              Distinct -> "&LS_mode=distinct"
              Command -> "&LS_mode=command"
          fromUpdateFreq Unfiltered = "&LS_updated_max_frequency=unfiltered"
          fromUpdateFreq (Frequency dbl) = "&LS_updated_max_frequency=" <>+ fromShow $ dbl  
          fromSnapshot SnapTrue = "&LS_snapshot=true"
          fromSnapshot SnapFalse = "&LS_snapshot=false"
          fromSnapshot (SnapLen x) = "&LS_snapshot=" <>+ fromShow $ x

type ToBuilder a = a -> Builder

(<>+) :: B.ByteString -> ToBuilder a -> ToBuilder a 
b <>+ from = (<>) (fromByteString b) . from

(<>?) :: Maybe a -> ToBuilder a -> Builder
Nothing <>? _ = mempty
(Just x) <>? y = y x

defaultStreamRequest :: String -> StreamRequest
defaultStreamRequest adapter = StreamRequest
    { srAdapterSet = adapter
    , srConnectionMode = Left $ KeepAliveMode 600
    , srContentLength = Nothing
    , srPassword = Nothing
    , srRequestedMaxBandwidth = Nothing
    , srReportInfo = Nothing
    , srUser = Nothing 
    }

createStandardHeaders :: String -> StandardHeaders
createStandardHeaders host = StandardHeaders $
       fromByteString "Host: " <> fromString host
    <> fromByteString "\r\nUser-Agent: Haskell Lightstreamer Client 0.1.0\r\n"

serializeHttpRequest :: HttpRequest -> B.ByteString
serializeHttpRequest (HttpRequest x) = x

requestEnd :: StandardHeaders -> Builder
requestEnd (StandardHeaders h) = " HTTP/1.1\r\n" <> h <> "Content-Length: 0\r\n\r\n"
