{-# LANGUAGE DeriveDataTypeable, OverloadedStrings, RankNTypes,
             ScopedTypeVariables #-}

module Lightstreamer.Http
    ( Connection(closeConnection)
    , ConnectionSettings(..)
    , HttpBody(..)
    , HttpException(..)
    , HttpHeader(..)
    , HttpResponse
        ( resBody
        , resHeaders
        , resReason
        , resStatusCode
        )
    , TlsSettings(..)
    , newConnection
    , readStreamedResponse
    , sendHttpRequest
    , simpleHttpRequest
    ) where

import Control.Concurrent (ThreadId, forkIO)
import Control.Exception (Exception, SomeException, catch, throwIO, try)
import Control.Monad (unless)
import Control.Monad.IO.Class (MonadIO(..))

import Data.ByteString.Char8 (readInt, pack)
import Data.ByteString.Lazy (toStrict, fromStrict)
import Data.ByteString.Lex.Integral (readHexadecimal)
import Data.Conduit (Consumer, Conduit, Producer, ($$+), ($$+-), ($=+), await, leftover, yield)
import Data.Default (def)
import Data.List (find)
import Data.Typeable (Typeable)

import Lightstreamer.Error (showException)
import Lightstreamer.Request (RequestConverter(..), StandardHeaders
                             , createStandardHeaders, serializeHttpRequest)

import System.X509 (getSystemCertificateStore)

import qualified Data.ByteString as B
import qualified Data.Conduit.Binary as CB
import qualified Data.Word8 as W

import qualified Network.Socket as S
import qualified Network.Socket.ByteString as SB
import qualified Network.TLS as TLS
import qualified Network.TLS.Extra as TLS

data ConnectionSettings = ConnectionSettings
    { csHost :: String
    , csPort :: Int
    , csTlsSettings :: Maybe TlsSettings
    }

data TlsSettings = TlsSettings
    { tlsDisableCertificateValidation :: Bool
    }

data Connection = Connection
    { closeConnection :: IO ()
    , readBytes :: IO B.ByteString
    , standardHeaders :: StandardHeaders
    , writeBytes :: B.ByteString -> IO ()
    } 

data HttpException = HttpException B.ByteString deriving (Show, Typeable)

instance Exception HttpException where
    
data HttpHeader = HttpHeader B.ByteString B.ByteString deriving Show

data HttpBody = StreamingBody ThreadId | ContentBody B.ByteString | None

data HttpResponse = HttpResponse
    { resBody :: HttpBody 
    , resHeaders :: [HttpHeader]
    , resReason :: B.ByteString
    , resStatusCode :: Int
    }

newConnection :: ConnectionSettings -> IO Connection 
newConnection settings = do
    addr <- S.inet_addr (csHost settings)
    let sockAddr = S.SockAddrInet (fromInteger . toInteger $ csPort settings) addr
    sock <- S.socket S.AF_INET S.Stream 6 --6 = tcp 
    S.setSocketOption sock S.NoDelay 1
    S.connect sock sockAddr
    maybe (mkConnection sock) (mkTlsConnection (csHost settings) sock) $ csTlsSettings settings
    where 
        mkConnection sock = return Connection
            { closeConnection = S.close sock
            , readBytes = SB.recv sock 8192
            , standardHeaders = createStandardHeaders $ csHost settings 
            , writeBytes = SB.sendAll sock 
            }
        mkTlsConnection host sock tls = do
            certStore <- getSystemCertificateStore
            context <- TLS.contextNew sock $ mkClientParams certStore
            TLS.handshake context
            return Connection
                { closeConnection = 
                    -- Closing an SSL connection gracefully involves writing/reading
                    -- on the socket.  But when this is called the socket might be
                    -- already closed, and we get a @ResourceVanished@. 
                    catch (TLS.bye context >> TLS.contextClose context) (\(_ :: SomeException) -> return ())
                , readBytes = TLS.recvData context
                , writeBytes = TLS.sendData context . fromStrict
                , standardHeaders = createStandardHeaders $ csHost settings
                }
            where
                mkClientParams certStore = 
                    (TLS.defaultParamsClient host (pack . show $ csPort settings))
                        { TLS.clientSupported = 
                            def { TLS.supportedCiphers = TLS.ciphersuite_all }
                        , TLS.clientShared = def
                            { TLS.sharedCAStore = certStore 
                            , TLS.sharedValidationCache = validationCache
                            }
                        }
                    where validationCache 
                            | tlsDisableCertificateValidation tls =
                                TLS.ValidationCache (\_ _ _ -> return TLS.ValidationCachePass)
                                        (\_ _ _ -> return ())
                            | otherwise = def

sendHttpRequest :: RequestConverter r => Connection -> r -> IO ()
sendHttpRequest conn req = writeBytes conn . serializeHttpRequest $ 
                            convertToHttp req (standardHeaders conn)

connectionProducer :: Connection -> Producer IO B.ByteString
connectionProducer conn = loop
    where loop = do
            bytes <- liftIO $ readBytes conn
            unless (B.null bytes) $ yield bytes >> loop 
        
readStreamedResponse :: Connection 
                     -> Maybe ThreadId 
                     -> (B.ByteString -> IO ())
                     -> Consumer [B.ByteString] IO () 
                     -> IO (Either B.ByteString HttpResponse)
readStreamedResponse conn tId errHandle streamSink = do 
    (rSrc, res) <- connectionProducer conn $$+ readHttpHeader
    case find contentHeader $ resHeaders res of
      Just (HttpHeader "Content-Length" val) -> do
        body <- rSrc $$+- (CB.take . maybe 0 fst $ readInt val)
        return $ Right res { resBody = ContentBody $ toStrict body } 
      
      Just (HttpHeader "Transfer-Encoding" _) -> do
        let action = try (rSrc $=+ chunkConduit B.empty $$+- streamSink) >>=
                        either (errHandle . showException) return
        a <- maybe (forkIO action) ((>>) action . return) tId
        return $ Right res { resBody = StreamingBody a }
      _ -> throwHttpException "Could not determine body type of response."
                
    where
        contentHeader (HttpHeader "Content-Length" _) = True
        contentHeader (HttpHeader "Transfer-Encoding" _) = True
        contentHeader _ = False

simpleHttpRequest :: RequestConverter r => Connection -> r -> IO (Either B.ByteString HttpResponse)
simpleHttpRequest conn req = do
    sendHttpRequest conn req
    (rSrc, res) <- connectionProducer conn $$+ readHttpHeader
    case find contentHeader $ resHeaders res of
      Just (HttpHeader "Content-Length" val) -> do
        body <- rSrc $$+- (CB.take . maybe 0 fst $ readInt val)
        return $ Right res { resBody = ContentBody $ toStrict body } 

      _ -> throwHttpException "Unexpected response body."
    where 
        contentHeader (HttpHeader "Content-Length" _) = True
        contentHeader _ = False

readHttpHeader :: Consumer B.ByteString IO HttpResponse
readHttpHeader = loop [] Nothing 
    where
        loop acc res = await >>= maybe (complete acc res) (build acc res)
        
        complete [rest] (Just res) = do
            leftover rest
            return res
        complete _ (Just _) = throwHttpException "Unexpected response."
        complete _ Nothing = throwHttpException "No response provided."
        
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
                    Left err -> throwHttpException err 
                    Right res' -> build [] res' $ B.drop 1 rest -- drop 1 = \n

              Nothing -> loop (p1:acc) res
            where 
                (p1, p2) = B.break (==W._cr) more  
                parse bytes Nothing =
                    if B.count W._space (B.take 15 bytes) >= 2 then
                        let (_, rest) = B.break (==W._space) bytes
                        in let (code, rest') = B.break (==W._space) (B.drop 1 rest) 
                            in Right $ Just HttpResponse
                                         { resStatusCode = maybe 0 fst $ readInt code
                                         , resReason = B.drop 1 rest' 
                                         , resHeaders = []
                                         , resBody = None
                                         }
                    else Left $ B.concat ["Invalid HTTP response. :", bytes]
                parse bytes (Just a) =
                    let header = let (name, value) = B.break (==W._colon) bytes
                                 in HttpHeader name (B.dropWhile (==W._space) $ B.drop 1 value) 
                    in Right $ Just a { resHeaders = header : resHeaders a } 

throwHttpException :: MonadIO m => B.ByteString -> m a
throwHttpException = liftIO . throwIO . HttpException

chunkConduit :: B.ByteString -> Conduit B.ByteString IO [B.ByteString]
chunkConduit partial = await >>= maybe (return ()) build
    where
        build
            | partial /= B.empty = yieldChunks . B.append partial 
            | otherwise = yieldChunks
        yieldChunks bytes =
            case readChunks bytes of
              Left err -> throwHttpException err 
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
                 else case hexToDec p1 of
                        Left err -> Left err
                        Right 0 -> retRight acc B.empty
                        Right size -> 
                          if B.length p2 > size then
                            let (chunk, rest) = B.splitAt size $ B.drop 2 p2
                            in loop (chunk:acc) $ B.drop 2 rest
                          else retRight acc buf 
                where (p1, p2) = B.break (==W._cr) buf
        retRight acc rest = Right (reverse acc, rest)
        hexToDec = maybe (Left "Invalid hexidecimal number.") (Right . fst) . readHexadecimal
