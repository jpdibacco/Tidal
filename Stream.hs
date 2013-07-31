{-# LANGUAGE OverloadedStrings, FlexibleInstances, RankNTypes, NoMonomorphismRestriction #-}

module Stream where

import Data.Maybe
import Sound.OSC.FD
import Sound.OpenSoundControl
import Control.Applicative
--import Network.Netclock.Client
import Tempo (Tempo, logicalTime)
import TempoClient (clocked)
import Control.Concurrent
import Control.Concurrent.MVar
import Pattern
import Data.Ratio
import Control.Exception as E
import Parse

import qualified Data.Map as Map

data Param = S {name :: String, sDefault :: Maybe String}
           | F {name :: String, fDefault :: Maybe Double}
           | I {name :: String, iDefault :: Maybe Int}

instance Eq Param where
  a == b = name a == name b

instance Ord Param where
  compare a b = compare (name a) (name b)
instance Show Param where
  show p = name p

data OscShape = OscShape {path :: String,
                          params :: [Param],
                          timestamp :: Bool
                         }
type OscMap = Map.Map Param (Maybe Datum)

type OscPattern = Pattern OscMap

defaultDatum :: Param -> Maybe Datum
defaultDatum (S _ (Just x)) = Just $ String x
defaultDatum (I _ (Just x)) = Just $ Int x
defaultDatum (F _ (Just x)) = Just $ Float x
defaultDatum _ = Nothing

hasDefault :: Param -> Bool
hasDefault (S _ Nothing) = False
hasDefault (I _ Nothing) = False
hasDefault (F _ Nothing) = False
hasDefault _ = True

defaulted :: OscShape -> [Param]
defaulted = filter hasDefault . params

defaultMap :: OscShape -> OscMap
defaultMap s
  = Map.fromList $ map (\x -> (x, defaultDatum x)) (defaulted s)

required :: OscShape -> [Param]
required = filter (not . hasDefault) . params

hasRequired :: OscShape -> OscMap -> Bool
hasRequired s m = isSubset (required s) (Map.keys (Map.filter (\x -> x /= Nothing) m))

isSubset :: (Eq a) => [a] -> [a] -> Bool
isSubset xs ys = all (\x -> elem x ys) xs

tpb = 1

toMessage :: OscShape -> Tempo -> Int -> (Double, OscMap) -> Maybe Bundle
toMessage s change ticks (o, m) =
  do m' <- applyShape' s m
     let beat = fromIntegral ticks / fromIntegral tpb
         latency = 0.019
         logicalNow = (logicalTime change beat)
         beat' = (fromIntegral ticks + 1) / fromIntegral tpb
         logicalPeriod = (logicalTime change (beat + 1)) - logicalNow
         --logicalOnset = ntpr_to_ut $ logicalNow + (logicalPeriod * o) + latency
         logicalOnset = logicalNow + (logicalPeriod * o) + latency
         sec = floor logicalOnset
         usec = floor $ 1000000 * (logicalOnset - (fromIntegral sec))
         oscdata = catMaybes $ mapMaybe (\x -> Map.lookup x m') (params s)
         oscdata' = ((Int sec):(Int usec):oscdata)
         osc | timestamp s = Bundle (immediately) [Message (path s) oscdata']
             | otherwise = Bundle (immediately) [Message (path s) oscdata]
     return osc


applyShape' :: OscShape -> OscMap -> Maybe OscMap
applyShape' s m | hasRequired s m = Just $ Map.union m (defaultMap s)
                | otherwise = Nothing

start :: String -> String -> String -> String -> Int -> OscShape -> IO (MVar (OscPattern))
start client server name address port shape
  = do patternM <- newMVar silence
       putStrLn $ "connecting " ++ (show address) ++ ":" ++ (show port)
       s <- openUDP address port
       putStrLn $ "connected "
       let ot = (onTick s shape patternM) :: Tempo -> Int -> IO ()
       --forkIO $ clocked name client server 1 ot
       forkIO $ clocked server ot
       return patternM

stream :: String -> String -> String -> String -> Int -> OscShape -> IO (OscPattern -> IO ())
stream client server name address port shape 
  = do patternM <- start client server name address port shape
       return $ \p -> do swapMVar patternM p
                         return ()

streamcallback :: (OscPattern -> IO ()) -> String -> String -> String -> String -> Int -> OscShape -> IO (OscPattern -> IO ())
streamcallback callback client server name address port shape 
  = do f <- stream client server name address port shape
       let f' p = do callback p
                     f p
       return f'

onTick :: UDP -> OscShape -> MVar (OscPattern) -> Tempo -> Int -> IO ()
onTick s shape patternM change beats
  = do p <- readMVar patternM
       let --tpb' = 2 :: Integer
           tpb' = 1
           beats' = (fromIntegral beats) :: Integer
           a = beats' % tpb'
           b = (beats' + 1) % tpb'
           messages = mapMaybe 
                      (toMessage shape change beats) 
                      (seqToRelOnsets (a, b) p)
       --putStrLn $ (show a) ++ ", " ++ (show b)
       --putStrLn $ "tick " ++ show ticks ++ " = " ++ show messages
       E.catch (mapM_ (sendOSC s) messages) (\msg -> putStrLn $ "oops " ++ show (msg :: E.SomeException))
       return ()

{-ticker :: IO (MVar Rational)
ticker = do mv <- newMVar 0
            --forkIO $ clocked "ticker" "127.0.0.1" "127.0.0.1" tpb (f mv)
            forkIO $ clocked (f mv)
            return mv
  where f mv change ticks = do swapMVar mv ((fromIntegral ticks) / (fromIntegral tpb))
  where f mv ticks = do swapMVar mv (fromIntegral ticks)
                        return ()
        tpb = 32
-}

make :: (a -> Datum) -> OscShape -> String -> Pattern a -> OscPattern
make toOsc s nm p = fmap (\x -> Map.singleton nParam (defaultV x)) p
  where nParam = param s nm
        defaultV a = Just $ toOsc a
        --defaultV Nothing = defaultDatum nParam

makeS = make String
makeF = make Float g

makeI = make Int

param :: OscShape -> String -> Param
param shape n = head $ filter (\x -> name x == n) (params shape)
                
merge :: OscPattern -> OscPattern -> OscPattern
merge x y = Map.union <$> x <*> y

infixl 1 |+|
(|+|) :: OscPattern -> OscPattern -> OscPattern
(|+|) = merge



weave :: Rational -> OscPattern -> [OscPattern] -> OscPattern
weave t p ps | l == 0 = silence
             | otherwise = slow t $ stack $ map (\(i, p') -> ((density t p') |+| (((fromIntegral i) % l) <~ p))) (zip [0 ..] ps)
  where l = fromIntegral $ length ps

