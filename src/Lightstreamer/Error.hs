{-# LANGUAGE OverloadedStrings #-}

module Lightstreamer.Error
    ( LsError(..)
    , errorParser
    , showException
    ) where

import Control.Exception (SomeException)

import Data.Attoparsec.ByteString (Parser, string, takeTill, choice, takeByteString)
import Data.Attoparsec.ByteString.Char8 (endOfLine, isEndOfLine, decimal)
import Data.ByteString (ByteString)
import Data.ByteString.Char8 (pack)
import Data.Functor ((<$>))

data LsError = LsError Int ByteString 
             | ConnectionError ByteString 
             | ErrorPage ByteString
             | HttpError Int ByteString
             | Unexpected ByteString
             deriving Show

errorParser :: Parser LsError
errorParser =  choice [errorCodeParser, errorPageParser]

errorCodeParser :: Parser LsError
errorCodeParser = do
    _ <- string "ERROR"
    endOfLine
    errCode <- decimal
    endOfLine
    msg <- takeTill isEndOfLine
    endOfLine
    return $ LsError errCode msg

errorPageParser :: Parser LsError
errorPageParser = ErrorPage <$> takeByteString 

showException :: SomeException -> ByteString
showException e = pack $ show e
