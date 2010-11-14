{- git-annex commands
 -
 - Copyright 2010 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

module Command where

import Control.Monad.State (liftIO)
import System.Directory
import System.Posix.Files
import Control.Monad (filterM)

import Types
import qualified Backend
import Messages
import qualified Annex
import qualified GitRepo as Git
import Locations

{- A subcommand runs in four stages.
 -
 - 0. The seek stage takes the parameters passed to the subcommand,
 -    looks through the repo to find the ones that are relevant
 -    to that subcommand (ie, new files to add), and generates
 -    a list of start stage actions. -}
type SubCmdSeek = [String] -> Annex [SubCmdStart]
{- 1. The start stage is run before anything is printed about the
  -   subcommand, is passed some input, and can early abort it
  -   if the input does not make sense. It should run quickly and
  -   should not modify Annex state. -}
type SubCmdStart = Annex (Maybe SubCmdPerform)
{- 2. The perform stage is run after a message is printed about the subcommand
 -    being run, and it should be where the bulk of the work happens. -}
type SubCmdPerform = Annex (Maybe SubCmdCleanup)
{- 3. The cleanup stage is run only if the perform stage succeeds, and it
 -    returns the overall success/fail of the subcommand. -}
type SubCmdCleanup = Annex Bool
{- Some helper functions are used to build up SubCmdSeek and SubCmdStart
 - functions. -}
type SubCmdSeekStrings = SubCmdStartString -> SubCmdSeek
type SubCmdStartString = String -> SubCmdStart
type SubCmdSeekBackendFiles = SubCmdStartBackendFile -> SubCmdSeek
type SubCmdStartBackendFile = (FilePath, Maybe Backend) -> SubCmdStart
type SubCmdSeekNothing = SubCmdStart -> SubCmdSeek
type SubCmdStartNothing = SubCmdStart

data SubCommand = SubCommand {
	subcmdname :: String,
	subcmdparams :: String,
	subcmdseek :: [SubCmdSeek],
	subcmddesc :: String
}

{- Prepares a list of actions to run to perform a subcommand, based on
 - the parameters passed to it. -}
prepSubCmd :: SubCommand -> AnnexState -> [String] -> IO [Annex Bool]
prepSubCmd SubCommand { subcmdseek = seek } state params = do
	lists <- Annex.eval state $ mapM (\s -> s params) seek
	return $ map doSubCmd $ foldl (++) [] lists

{- Runs a subcommand through the start, perform and cleanup stages -}
doSubCmd :: SubCmdStart -> SubCmdCleanup
doSubCmd start = do
	s <- start
	case (s) of
		Nothing -> return True
		Just perform -> do
			p <- perform
			case (p) of
				Nothing -> do
					showEndFail
					return False
				Just cleanup -> do
					c <- cleanup
					if (c)
						then do
							showEndOk
							return True
						else do
							showEndFail
							return False

notAnnexed :: FilePath -> Annex (Maybe a) -> Annex (Maybe a)
notAnnexed file a = do
	r <- Backend.lookupFile file
	case (r) of
		Just _ -> return Nothing
		Nothing -> a

isAnnexed :: FilePath -> ((Key, Backend) -> Annex (Maybe a)) -> Annex (Maybe a)
isAnnexed file a = do
	r <- Backend.lookupFile file
	case (r) of
		Just v -> a v
		Nothing -> return Nothing

{- These functions find appropriate files or other things based on a
   user's parameters, and run a specified action on them. -}
withFilesInGit :: SubCmdSeekStrings
withFilesInGit a params = do
	repo <- Annex.gitRepo
	files <- liftIO $ mapM (Git.inRepo repo) params
	return $ map a $ filter notState $ foldl (++) [] files
withFilesMissing :: SubCmdSeekStrings
withFilesMissing a params = do
	files <- liftIO $ filterM missing params
	return $ map a $ filter notState files
	where
		missing f = do
			e <- doesFileExist f
			return $ not e
withFilesNotInGit :: SubCmdSeekBackendFiles
withFilesNotInGit a params = do
	repo <- Annex.gitRepo
	newfiles <- liftIO $ mapM (Git.notInRepo repo) params
	backendPairs a $ filter notState $ foldl (++) [] newfiles
withFilesUnlocked :: SubCmdSeekBackendFiles
withFilesUnlocked a params = do
	-- unlocked files have changed type from a symlink to a regular file
	repo <- Annex.gitRepo
	typechangedfiles <- liftIO $ mapM (Git.typeChangedFiles repo) params
	unlockedfiles <- liftIO $ filterM notSymlink $ foldl (++) [] typechangedfiles
	backendPairs a $ filter notState unlockedfiles
backendPairs :: SubCmdSeekBackendFiles
backendPairs a files = do
	pairs <- Backend.chooseBackends files
	return $ map a pairs
withString :: SubCmdSeekStrings
withString a params = return [a $ unwords params]
withFilesToBeCommitted :: SubCmdSeekStrings
withFilesToBeCommitted a params = do
	repo <- Annex.gitRepo
	tocommit <- liftIO $ mapM (Git.stagedFiles repo) params
	return $ map a $ filter notState $ foldl (++) [] tocommit
withUnlockedFilesToBeCommitted :: SubCmdSeekStrings
withUnlockedFilesToBeCommitted a params = do
	repo <- Annex.gitRepo
	typechangedfiles <- liftIO $ mapM (Git.typeChangedStagedFiles repo) params
	unlockedfiles <- liftIO $ filterM notSymlink $ foldl (++) [] typechangedfiles
	return $ map a $ filter notState unlockedfiles
withKeys :: SubCmdSeekStrings
withKeys a params = return $ map a params
withTempFile :: SubCmdSeekStrings
withTempFile a params = return $ map a params
withNothing :: SubCmdSeekNothing
withNothing a [] = return [a]
withNothing _ _ = return []

{- Default to acting on all files matching the seek action if
 - none are specified. -}
withAll :: SubCmdSeekStrings -> SubCmdSeekStrings
withAll w a params = do
	if null params
		then do
			g <- Annex.gitRepo
			w a [Git.workTree g]
		else w a params

{- Provides a default parameter to act on if none is specified. -}
withDefault :: String-> SubCmdSeekStrings -> SubCmdSeekStrings
withDefault d w a params = do
	if null params
		then w a [d]
		else w a params

{- filter out files from the state directory -}
notState :: FilePath -> Bool
notState f = stateLoc /= take (length stateLoc) f
	
{- filter out symlinks -}	
notSymlink :: FilePath -> IO Bool
notSymlink f = do
	s <- liftIO $ getSymbolicLinkStatus f
	return $ not $ isSymbolicLink s
