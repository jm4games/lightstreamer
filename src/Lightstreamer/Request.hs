{-# LANGUAGE OverloadedStrings #-}

module Lightstreamer.Request
    ( AsyncMessageRequest(..)
    , BindRequest(..)
    , ConstraintsRequest(..)
    , DestroyRequest (..)
    , HttpRequest
    , KeepAliveMode(..)
    , MessageRequest(..)
    , PollingMode(..)
    , RebindRequest(..)
    , ReconfigureRequest(..)
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
    , defaultTableInfo
    , mkBindRequest
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
    convertToHttp req = mkHttpRequest $
        ("POST /lightstreamer/create_session.txt?LS_op2=create\
        \&LS_cid=mgQkwtwdysogQz2BJ4Ji%20kOj2Bg&LS_adapter_set="
        <>+ fromString $ srAdapterSet req)
        <> fromReportInfo (srReportInfo req)
        <> fromContentLength (srContentLength req)
        <> fromMaxBandwidth (srRequestedMaxBandwidth req)
        <> srPassword req <>? ("&LS_password=" <>+ fromString)
        <> srUser req <>? ("&LS_user=" <>+ fromString)
        <> fromConnectionMode (srConnectionMode req)

data BindRequest = BindRequest
    { brConnectionMode :: Either KeepAliveMode PollingMode
    , brContentLength :: Maybe Int
    , brReportInfo :: Maybe Bool
    , brRequestedMaxBandwidth :: Maybe Double
    , brSessionId :: B.ByteString
    }

instance RequestConverter BindRequest where
    convertToHttp req = mkHttpRequest $
      "POST /lightstreamer/bind_session.txt?LS_session=" 
      <> fromByteString (brSessionId req)
      <> fromConnectionMode (brConnectionMode req)
      <> fromContentLength (brContentLength req)
      <> fromReportInfo (brReportInfo req) 
      <> fromMaxBandwidth (brRequestedMaxBandwidth req)

data SubscriptionRequest = SubscriptionRequest
    { subSessionId :: B.ByteString
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
    convertToHttp req = mkHttpRequest $
            controlPrefix (subSessionId req)
            <> ("&LS_table=" <>+ fromByteString $ subTable req) <>
      case subTableOperation req of
        TableDelete -> "&LS_op=delete"
        TableAdd t -> tbleOpts "&LS_op=add" t
        TableAddSilent t -> tbleOpts "&LS_op=add_silient" t
        TableStart t -> tbleOpts "&LS_op=start" t
      where 
          tbleOpts op t = op <>
            ("&LS_Id=" <>+ fromByteString $ tiId t)
            <> ("&LS_schema=" <>+ fromByteString $ tiSchema t)
            <> subMode (tiMode t) 
            <> tiDataAdapter t <>? ("&LS_data_adapter=" <>+ fromByteString)
            <> tiRequestedBufferSize t <>? ("&LS_requested_buffer_size=" <>+ fromShow)
            <> tiRequestedMaxFrequency t <>? fromUpdateFreq 
            <> tiSelector t <>? ("&LS_selector=" <>+ fromByteString)
            <> tiSnapshot t <>? ("&LS_snapshot=" <>+ fromSnapshot)
          subMode x = 
            case x of
              Raw -> "&LS_mode=RAW"
              Merge -> "&LS_mode=MERGE"
              Distinct -> "&LS_mode=DISTINCT"
              Command -> "&LS_mode=COMMAND"
          fromSnapshot SnapTrue = "&LS_snapshot=true"
          fromSnapshot SnapFalse = "&LS_snapshot=false"
          fromSnapshot (SnapLen x) = "&LS_snapshot=" <>+ fromShow $ x

data ReconfigureRequest = ReconfigureRequest
    { rrRequestedMaxFrequency :: Maybe UpdateFrequency
    , rrSessionId :: B.ByteString
    , rrTable :: B.ByteString
    }

instance RequestConverter ReconfigureRequest where
    convertToHttp req = mkHttpRequest $ 
         controlPrefix (rrSessionId req)
      <> rrRequestedMaxFrequency req <>? fromUpdateFreq 
      <> "&LS_op=reconf&LS_table=" <> fromByteString (rrTable req)

data ConstraintsRequest = ConstraintsRequest
    { conSessionId :: B.ByteString
    , conRequestedMaxBandwith :: Maybe Int
    }

instance RequestConverter ConstraintsRequest where
    convertToHttp req = mkHttpRequest $
      controlPrefix (conSessionId req)
      <> "&LS_op=constrain"
      <> conRequestedMaxBandwith req <>? ("&LS_requested_max_bandwidth=" <>+ fromShow)

data RebindRequest = RebindRequest { rebSessionId :: B.ByteString }

instance RequestConverter RebindRequest where
    convertToHttp req = mkHttpRequest $
      controlPrefix (rebSessionId req) <> "&LS_op=force_rebind"

data DestroyRequest = DestroyRequest { desSessionId :: B.ByteString }

instance RequestConverter DestroyRequest where
    convertToHttp req = mkHttpRequest $
      controlPrefix (desSessionId req) <> "&LS_op=destory"

data MessageRequest = MessageRequest
    { smMessage :: B.ByteString
    , smSessionId :: B.ByteString
    }

instance RequestConverter MessageRequest where
    convertToHttp req = mkHttpRequest $ 
      msgPrefix (smSessionId req) <> appendMessage (smMessage req)

data AsyncMessageRequest = AsyncMessageRequest
    { amMaxWait :: Maybe Int
    , amMessage :: B.ByteString
    , amProgressiveNumber :: Int
    , amSequenceId :: B.ByteString
    , amSessionId :: B.ByteString
    }

instance RequestConverter AsyncMessageRequest where
    convertToHttp req = mkHttpRequest $
      msgPrefix (amSessionId req) <> appendMessage (amMessage req)
      <> ("&LS_sequence=" <>+ fromShow) (amSequenceId req)
      <> ("&LS_msg_prog=" <>+ fromShow) (amProgressiveNumber req)
      <> amMaxWait req <>? ("&LS_max_wait=" <>+ fromShow)

type ToBuilder a = a -> Builder

(<>+) :: B.ByteString -> ToBuilder a -> ToBuilder a 
b <>+ from = (<>) (fromByteString b) . from

(<>?) :: Maybe a -> ToBuilder a -> Builder
Nothing <>? _ = mempty
(Just x) <>? y = y x

mkHttpRequest :: Builder -> StandardHeaders -> HttpRequest
mkHttpRequest b (StandardHeaders h) = HttpRequest . toByteString $ 
        b <> " HTTP/1.1\r\n" <> h <> "Content-Length: 0\r\n\r\n"

mkBindRequest :: B.ByteString -> StreamRequest -> BindRequest
mkBindRequest sessionId sr = BindRequest
    { brConnectionMode = srConnectionMode sr
    , brContentLength = srContentLength sr
    , brReportInfo = srReportInfo sr
    , brRequestedMaxBandwidth = srRequestedMaxBandwidth sr
    , brSessionId = sessionId
    }

fromReportInfo :: Maybe Bool -> Builder
fromReportInfo x = x <>? ("&LS_report_info=" <>+ fromShow)

fromMaxBandwidth :: Maybe Double -> Builder
fromMaxBandwidth x = x <>? ("&LS_requested_max_bandwidth=" <>+ fromShow)

fromContentLength :: Maybe Int -> Builder
fromContentLength x = x <>? ("&LS_content_length=" <>+ fromShow)

fromConnectionMode :: Either KeepAliveMode PollingMode -> Builder
fromConnectionMode mode =
    case mode of
      Left (KeepAliveMode x) -> "&LS_keepalive_millis=" <> fromShow x
      Right y -> "&LS_polling=true&LS_polling_millis=" <> fromShow (pollingMillis y)
                 <> idelMillis y <>? ("&LS_idel_millis=" <>+ fromShow)

fromUpdateFreq :: UpdateFrequency -> Builder
fromUpdateFreq Unfiltered = "&LS_requested_max_frequency=unfiltered"
fromUpdateFreq (Frequency dbl) = "&LS_requested_max_frequency=" <>+ fromShow $ dbl  

appendMessage :: B.ByteString -> Builder
appendMessage = (<>) "&LS_message=" . fromByteString

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

defaultTableInfo :: B.ByteString -> SubscriptionMode -> B.ByteString -> TableInfo
defaultTableInfo tableId mode schema = TableInfo
    { tiDataAdapter = Nothing
    , tiId = tableId
    , tiMode = mode
    , tiRequestedBufferSize = Nothing
    , tiRequestedMaxFrequency = Nothing
    , tiSchema = schema
    , tiSelector = Nothing
    , tiSnapshot = Nothing
    }

createStandardHeaders :: String -> StandardHeaders
createStandardHeaders host = StandardHeaders $
       fromByteString "Host: " <> fromString host
    <> fromByteString "\r\nUser-Agent: Haskell Lightstreamer Client 0.1.0\r\n"

serializeHttpRequest :: HttpRequest -> B.ByteString
serializeHttpRequest (HttpRequest x) = x

controlPrefix :: B.ByteString -> Builder
controlPrefix = (<>) "POST /lightstreamer/control.txt?LS_session=" . fromByteString

msgPrefix :: B.ByteString -> Builder
msgPrefix = (<>) "POST /lightstreamer/send_message.txt?LS_session=" . fromByteString
