{- git-annex "WORM" backend -- Write Once, Read Many
 - -}

module Backend.WORM (backend) where

import Control.Monad.State
import System.FilePath
import System.Posix.Files
import qualified Data.ByteString.Lazy.Char8 as B

import qualified Backend.File
import TypeInternals
import Utility

backend = Backend.File.backend {
	name = "WORM",
	getKey = keyValue
}

-- The key is formed from the file size, modification time, and the
-- basename of the filename.
--
-- That allows multiple files with the same names to have different keys,
-- while also allowing a file to be moved around while retaining the
-- same key.
keyValue :: FilePath -> Annex (Maybe Key)
keyValue file = do
	stat <- liftIO $ getFileStatus file
	return $ Just $ Key ((name backend), key stat)
	where
 		key stat = uniqueid stat ++ sep ++ base
		uniqueid stat = (show $ modificationTime stat) ++ sep ++
			(show $ fileSize stat)
		base = takeFileName file
		sep = ":"
