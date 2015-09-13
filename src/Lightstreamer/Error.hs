{-# LANGUAGE OverloadedStrings #-}

module Lightstreamer.Error where

import Data.Attoparsec.ByteString (Parser, string, takeTill)
import Data.Attoparsec.ByteString.Char8 (endOfLine, isEndOfLine, decimal)
import Data.ByteString (ByteString)

data LsError = LsError Int ByteString 
             | ConnectionError ByteString 
             | HttpError ByteString
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

