module Control.Concurrent.STM.Batch
  ( Batch
    -- * Batch Operations
  , newBatch
  , writeBatch
  , flushBatch
    -- * Time Utilities
  , fromMilliSecs
  , fromSecs
  , fromMicroSecs
    -- * Re-exports
  , TimeSpec(..)
  ) where

import Data.Maybe (isJust, fromJust)
import System.Clock
import Control.Concurrent (forkIO, threadDelay)
import Control.Monad (void, when, forever, unless, forM_)
import Control.Concurrent.STM
import Control.Concurrent.STM.TVar
import Control.Concurrent.STM.TMVar

-- | Opaque batch with buffer and settings.
data Batch a = Batch
  { batchAcc     :: TVar [a]
  , batchLength  :: TVar Int
  , batchLimit   :: Int
  , batchTimeout :: Maybe TimeSpec
  , batchStarted :: TMVar TimeSpec
  , batchHandler :: [a] -> STM ()
  }

-- | Constructs a new batcher state. If a batch timeout is configured this
-- operation will automatically spawn a timeout handler thread. The timeout
-- handler will automatically be killed when the batcher is garbage collected.

newBatch ::
     Int             -- ^ Max items in a batch
  -> Maybe TimeSpec  -- ^ Batch timeout
  -> ([a] -> STM ()) -- ^ Handler for complete batch
  -> IO (Batch a)    -- ^ Batch with settings

newBatch batchLimit' batchTimeout' batchHandler' = do
  batchLength'  <- newTVarIO 0
  batchAcc'     <- newTVarIO []
  batchStarted' <- newEmptyTMVarIO

  let
    batch = Batch
      { batchAcc     = batchAcc'
      , batchLength  = batchLength'
      , batchLimit   = batchLimit'
      , batchTimeout = batchTimeout'
      , batchStarted = batchStarted'
      , batchHandler = batchHandler'
      }

  forM_ batchTimeout' $ \batchTimeout'' -> void $ forkIO $ timeoutHandler batchTimeout'' batch

  return batch

-- | Fires the batchHandler for the current batch from the current thread.
-- This function is automatically called for a timeout or when buffer is filled
-- by a write operation.
flushBatch :: Batch a -> STM ()
flushBatch ctx = do
  acc <- readTVar $ batchAcc ctx
  when (not $ null acc) $ batchHandler ctx acc
  void $ takeTMVar $ batchStarted ctx
  writeTVar (batchAcc ctx) []
  writeTVar (batchLength ctx) 0

-- | Add a single item to the batch. The batch is automatically flushed when full.
writeBatch :: Batch a -> a -> IO ()
writeBatch ctx item = do
  batchInitial <- atomically $ do
    modifyTVar' (batchAcc ctx) (item :)
    modifyTVar' (batchLength ctx) (+ 1)
    len <- readTVar $ batchLength ctx
    unless (len < batchLimit ctx) $ flushBatch ctx
    return $ len == 1

  when (batchInitial && batchLimit ctx > 1) $ do
    now <- getTime Monotonic
    atomically $ putTMVar (batchStarted ctx) now

timeoutHandler :: TimeSpec -> Batch a -> IO ()
timeoutHandler timeout ctx = forever $ do
  now <- getTime Monotonic
  t <- atomically $ readTMVar $ batchStarted ctx
  if now - t <= timeout
    then threadDelay $ fromIntegral $ toMicroSecs $ now - t + timeout
    else atomically $ flushBatch ctx

-- | Convenience function for timeout in milliseconds.
fromMilliSecs :: Integer -> TimeSpec
fromMilliSecs ts = fromNanoSecs $ 1000000 * ts

-- | Convenience function for timeout in seconds.
fromSecs :: Integer -> TimeSpec
fromSecs ts = TimeSpec (fromIntegral ts) 0

-- | Highest resolution time supported by internal usage of @threadDelay@.
fromMicroSecs :: Integer -> TimeSpec
fromMicroSecs ts = fromNanoSecs $ 1000 * ts

toMicroSecs :: TimeSpec -> Integer
toMicroSecs ts = toNanoSecs ts `quot` 1000
