{-# LANGUAGE OverloadedStrings #-}

module Lightstreamer.Error where

import Control.Exception (SomeException)

import Data.Attoparsec.ByteString (Parser, string, takeTill)
import Data.Attoparsec.ByteString.Char8 (endOfLine, isEndOfLine, decimal)
import Data.ByteString (ByteString)
import Data.ByteString.Char8 (pack)

data LsError = LsError Int ByteString 
             | ConnectionError ByteString 
             | HttpError Int ByteString
             | Unexpected ByteString
             deriving Show

errorParser :: Parser LsError
errorParser = do
    _ <- string "ERROR"
    endOfLine
    errCode <- decimal
    endOfLine
    msg <- takeTill isEndOfLine
    endOfLine
    return $ LsError errCode msg

showException :: SomeException -> ByteString
showException e = pack $ show e
