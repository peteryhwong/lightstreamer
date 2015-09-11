{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

module Lightstreamer.Http
    ( HttpConnection
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
import Data.Conduit (Consumer, Conduit, Producer, ($$+), ($$+-), ($=+), await, leftover)
import Data.Conduit.Network (sourceSocket)
import Data.Functor ((<$>))
import Data.List (find)
import Data.Typeable (Typeable)

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
    
data HttpHeader = HttpHeader B.ByteString B.ByteString

data HttpBody = StreamingBody ThreadId | ContentBody B.ByteString | None

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

httpConnectionProducer :: HttpConnection -> Producer IO B.ByteString
httpConnectionProducer (HttpConnection { socket = sock }) = sourceSocket sock

readStreamedResponse :: HttpConnection 
                     -> Consumer B.ByteString IO () 
                     -> IO (Either B.ByteString HttpResponse)
readStreamedResponse conn streamSink = do 
    (rSrc, res) <- httpConnectionProducer conn $$+ readHttpHeader
    case find contentHeader $ resHeaders res of
      Just (HttpHeader "Content-Length" val) -> do
        body <- rSrc $$+- (CB.take . maybe 0 fst $ readInt val)
        return $ Right res { resBody = ContentBody $ toStrict body } 
      
      Just (HttpHeader "Transfer-Encoding" _) -> do
        tId <- forkIO (rSrc $=+ chunkConduit [] $$+- streamSink)
        return $ Right res { resBody = StreamingBody tId }
      _ -> 
        throwIO $ HttpException "Could not determine body type of response."
                
    where
        contentHeader (HttpHeader "Content-Length" _) = True
        contentHeader (HttpHeader "Transfer-Encoding" _) = True
        contentHeader _ = False

readHttpHeader :: MonadIO m => Consumer B.ByteString m HttpResponse
readHttpHeader = loop [] Nothing 
    where
        loop acc res = await >>= maybe (complete acc res) (build acc res)
        
        complete acc (Just res) = do
            unless (null acc) $ leftover (B.concat $ reverse acc)
            return res
        complete _ Nothing = liftIO . throwIO $ HttpException "No response provided."

        build acc res more = 
            case B.uncons p2 of
              -- dropping \r
              Just (_, rest) 
                | rest == B.singleton W._lf && null acc -> complete [] res
                | otherwise -> 
                  -- dropping \n
                  case parse (B.drop 1 . B.concat . reverse $ p1:acc) res of
                    Left err -> liftIO . throwIO $ HttpException err 
                    Right res' -> build [] res' rest

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
                    let header = uncurry HttpHeader $ B.breakByte W._colon bytes
                    in Right $ Just a { resHeaders = header : resHeaders a } 

chunkConduit :: MonadIO m => [[B.ByteString]] -> Conduit B.ByteString m B.ByteString 
chunkConduit = undefined
