{-# language NumDecimals #-}
module System.IO.TailFile (tailFile) where

import Data.Foldable
import Data.Monoid
import qualified Data.ByteString
import Data.ByteString.Lazy.Internal (defaultChunkSize)
import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar
import Control.Monad
import Control.Exception
import System.INotify
import System.IO (withFile
                 ,IOMode(ReadMode)
                 ,hSeek
                 ,SeekMode(AbsoluteSeek,SeekFromEnd)
                 ,hFileSize)
import System.IO.Error (isDoesNotExistError)

tailFile :: FilePath 
         -> (a -> Data.ByteString.ByteString -> IO a) 
         -> IO a 
         -> IO void
tailFile filepath callback initial = withINotify (\i -> 
    do sem <- newEmptyMVar
       state <- initial
       loop i sem state)
    where
    loop i sem =
        let go pristine a = do ea' <- tryJust (guard . isDoesNotExistError)
                                              (watchFile pristine i sem a)
                               case ea' of 
                                  Left ()  -> do threadDelay 5e5
                                                 go False a -- reuse the state
                                  Right a' -> go False a'
        in  go True
    watchFile pristine i sem a = 
        bracket (addWatch i 
                          [Modify,MoveSelf,DeleteSelf] 
                          filepath 
                          (\event -> let stop = Any (case event of
                                                        MovedSelf {} -> True
                                                        Deleted {} -> True
                                                        _ -> False)
                                     in do old <- fold <$> tryTakeMVar sem
                                           new <- evaluate $ old <> stop
                                           putMVar sem new))
                removeWatch
                (\_ -> withFile filepath ReadMode (\h -> 
                           do if pristine then hSeek h SeekFromEnd 0
                                          else return ()
                              sleeper sem h a))
    sleeper sem h =
        let go ms a = do event <- takeMVar sem
                         size' <- hFileSize h 
                         for_ ms (\size -> if size' < size -- truncation 
                                           then hSeek h AbsoluteSeek 0
                                           else return ())
                         a' <- drainBytes h a
                         if getAny event then return a'
                                         else go (Just size') a'
        in  go Nothing
    drainBytes h = 
        let go a = do c <- Data.ByteString.hGetSome h defaultChunkSize
                      if Data.ByteString.null c
                         then do return a
                         else do a' <- callback a c
                                 drainBytes h a'
        in  go
