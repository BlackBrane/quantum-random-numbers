{-# LANGUAGE ViewPatterns #-}

module QRN.Manager where

import QRN
import QRN.Helpers

import Prelude           hiding (writeFile)
import Data.Char                (isDigit, toLower)
import Data.Maybe               (isJust)
import Control.Monad.State      (lift)
import System.Console.Haskeline (InputT, getInputLine, runInputT, defaultSettings, outputStrLn)
import Data.ByteString          (writeFile)
import System.Directory         (doesFileExist)


---- Structure of commands ----

data Setting = MinSize | TargetSize

data Command = Add Int
             | Observe DisplayStyle Int
             | Peek DisplayStyle Int
             | PeekAll DisplayStyle
             | Live DisplayStyle Int
             | Fill
             | RestoreDefaults
             | Reinitialize
             | Status
             | Save String
             | Set Setting Int
             | Help
             | Quit

helpMsg = unlines
  [ "===== Available commands ====="
  , "add [# bytes]  –  Request specified number of QRN bytes from ANU and add them to the store"
  , "live [# bytes]  –  Request specified number of QRN bytes from ANU and display them directly"
  , "observe [# bytes] –  Take and display QRN data from store, retrieving more if needed. Those taken from the store are removed."
  , "peek [# bytes]  –  Display up to the specified number of bytes from the store. They are not removed."
  , "peekAll  –  Display all bytes from the store. They are not removed."
  , "fill  –  Fill the store to the target size with live ANU quantum random numbers"
  , "restoreDefaults  –  Restore default settings."
  , "reinitialize  –  Restore default settings, and refill QRN store to target size."
  , "status  –  Display status of store and settings."
  , "save [filepath]  –  save binary qrn file to specified file path."
  , "set minStoreSize  –  Set the number of bytes below which we refill."
  , "set targetStoreSize  –  Set the number of bytes we aim to have when refilling."
  , "help/?  –  Display this text."
  , "quit  –  quit."
  , ""
  , "===== Display options ====="
  , "Commands that display QRN data can take an optional display style modifier: 'spins' or 'binary'"
  , "Examples:"
  , "\"observe 25 spins\""
  , "\"live 50 binary\""
  , ""
  ]

---- Parsing commands ----

readDigit :: Char -> Maybe Int
readDigit c = if isDigit c then Just (read [c]) else Nothing

readInt :: String -> Maybe Int
readInt = readIntRev . reverse
   where readIntRev :: String -> Maybe Int
         readIntRev []       = Nothing
         readIntRev [c]      = readDigit c
         readIntRev (c:x:xs) = fmap (+) (readDigit c) <*> fmap (*10) (readIntRev (x:xs))


cwords :: String -> [String]
cwords = words . map toLower

readCommand :: String -> Maybe Command
readCommand (cwords -> ["add",w])                   = Add <$> readInt w
readCommand (cwords -> ["peekall"])                 = Just (PeekAll Default)
readCommand (cwords -> ["peekall","spins"])         = Just (PeekAll Spins)
readCommand (cwords -> ["peekall","binary"])        = Just (PeekAll Bits)
readCommand (cwords -> ["peek","all"])              = Just (PeekAll Default)
readCommand (cwords -> ["peek","all","spins"])      = Just (PeekAll Spins)
readCommand (cwords -> ["peek","all","binary"])     = Just (PeekAll Bits)
readCommand (cwords -> ["observe",w])               = Observe Default <$> readInt w
readCommand (cwords -> ["observe",w,"spins"])       = Observe Spins <$> readInt w
readCommand (cwords -> ["observe",w,"binary"])      = Observe Bits <$> readInt w
readCommand (cwords -> ["peek",w])                  = Peek Default <$> readInt w
readCommand (cwords -> ["peek",w,"spins"])          = Peek Spins <$> readInt w
readCommand (cwords -> ["peek",w,"binary"])         = Peek Bits <$> readInt w
readCommand (cwords -> ["live",w])                  = Live Default <$> readInt w
readCommand (cwords -> ["live",w,"spins"])          = Live Spins <$> readInt w
readCommand (cwords -> ["live",w,"binary"])         = Live Bits <$> readInt w
readCommand (cwords -> ["fill"])                    = Just Fill
readCommand (cwords -> ["restore"])                 = Just RestoreDefaults
readCommand (cwords -> ["reinitialize"])            = Just Reinitialize
readCommand (cwords -> ["status"])                  = Just Status
readCommand (cwords -> ["save",path])               = Just (Save path)
readCommand (cwords -> ["help"])                    = Just Help
readCommand (cwords -> ["?"])                       = Just Help
readCommand (cwords -> ["quit"])                    = Just Quit
readCommand (cwords -> ["q"])                       = Just Quit
readCommand (cwords -> ["set","minstoresize",n])    = Set MinSize <$> readInt n
readCommand (cwords -> ["set","targetstoresize",n]) = Set TargetSize <$> readInt n
readCommand _                                       = Nothing


---- Describing/announcing commands ----

bitsNBytes :: Int -> String
bitsNBytes n = show n ++ b ++ show (n*8) ++ " bits)"
   where b = if n /= 1 then " bytes (" else " byte ("

description :: Command -> String
description (Add n)         = "Adding " ++ bitsNBytes n ++ " of quantum random data to store"
description (Live _ n)      = "Viewing up to " ++ bitsNBytes n ++ " of live quantum random data from ANU"
description (Observe _ n)   = "Observing " ++ bitsNBytes n ++ " of quantum random data from store"
description (Peek _ n)      = "Viewing up to " ++ bitsNBytes n ++ " of quantum random data from store"
description (PeekAll _)     = "Viewing all quantum random data from store"
description Fill            = "Filling quantum random data store to specified level"
description RestoreDefaults = "Reverting to default settings"
description Reinitialize    = "Reverting to default settings, and refilling store"
description Quit            = "Exiting"
description _               = ""

announce :: Command -> IO ()
announce c = let str = description c in if str == "" then pure () else putStrLn str


---- Interpreting commands to actions ----

interp :: Command -> IO ()
interp (Add n)             = addToStore n
interp (Observe style n)   = observe style n
interp (Peek style n)      = peek style n
interp (PeekAll style)     = peekAll style
interp (Live style n)      = fetchQRN n >>= display style
interp Fill                = fill
interp RestoreDefaults     = restoreDefaults
interp Reinitialize        = reinitialize
interp Status              = status
interp (Save path)         = save path
interp (Set MinSize n)     = setMinStoreSize n
interp (Set TargetSize n)  = setTargetStoreSize n
interp Help                = putStrLn helpMsg
interp Quit                = return ()

command :: Command -> IO ()
command c = announce c *> interp c


---- Auxilliary IO actions ----

status :: IO ()
status = do
  siz <- storeSize
  min <- getMinStoreSize
  tar <- getTargetStoreSize
  sto <- getStoreFile
  mapM_ putStrLn
    [ "Store contains " ++ bitsNBytes siz ++ " of quantum random data"
    , ""
    , "Minimum store size set to " ++ bitsNBytes min ++ "."
    , "Target store size set to " ++ bitsNBytes tar ++ "."
    , ""
    , "Local data store location:"
    , sto
    , ""
    ]

save :: String -> IO ()
save path = do
  exists <- doesFileExist path
  qs <- getStore
  case exists of
       False -> writeFile path qs
       True  -> do putStrLn "File already exists. Enter 'yes' to overwrite."
                   i <- getLine
                   case i of
                        "yes" -> writeFile path qs *> putStrLn "Data saved."
                        _     -> putStrLn "Save aborted."

errorMsg :: IO ()
errorMsg = do
  putStrLn "***** QRN Error: Couldn't parse command."
  putStrLn "***** Enter 'help' or '?' to see list of available commands."


---- Core program code ----

qrn :: InputT IO ()
qrn = do str <- getInputLine "QRN> "
         let jc = readCommand =<< str
         case jc of
              Just Quit -> return ()
              Just c    -> lift (command c) *> qrn
              Nothing   -> lift errorMsg    *> qrn

main :: IO ()
main = runInputT defaultSettings qrn