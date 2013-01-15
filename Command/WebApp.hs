{- git-annex webapp launcher
 -
 - Copyright 2012 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

module Command.WebApp where

import Common.Annex
import Command
import Assistant
import Assistant.Common
import Assistant.NamedThread
import Assistant.Threads.WebApp
import Assistant.WebApp
import Assistant.Install
import Utility.WebApp
import Utility.Daemon (checkDaemon)
import Init
import qualified Git
import qualified Git.Config
import qualified Git.CurrentRepo
import qualified Annex
import Locations.UserConfig

import System.Posix.Directory
import Control.Concurrent
import Control.Concurrent.STM
import System.Process (env, std_out, std_err)

def :: [Command]
def = [noCommit $ noRepo startNoRepo $ dontCheck repoExists $ notBareRepo $
	command "webapp" paramNothing seek "launch webapp"]

seek :: [CommandSeek]
seek = [withNothing start]

start :: CommandStart
start = start' True

start' :: Bool -> CommandStart
start' allowauto = do
	liftIO $ ensureInstalled
	ifM isInitialized ( go , auto )
	stop
  where
	go = do
		browser <- fromRepo webBrowser
		f <- liftIO . absPath =<< fromRepo gitAnnexHtmlShim
		ifM (checkpid <&&> checkshim f)
			( liftIO $ openBrowser browser f Nothing Nothing
			, startDaemon True True $ Just $ 
				\origout origerr _url htmlshim ->
					openBrowser browser htmlshim origout origerr
			)
	auto
		| allowauto = liftIO startNoRepo
		| otherwise = do
			d <- liftIO getCurrentDirectory
			error $ "no git repository in " ++ d
	checkpid = do
		pidfile <- fromRepo gitAnnexPidFile
		liftIO $ isJust <$> checkDaemon pidfile
	checkshim f = liftIO $ doesFileExist f

{- When run without a repo, see if there is an autoStartFile,
 - and if so, start the first available listed repository.
 - If not, it's our first time being run! -}
startNoRepo :: IO ()
startNoRepo = do
	autostartfile <- autoStartFile
	ifM (doesFileExist autostartfile) ( autoStart autostartfile , firstRun )

autoStart :: FilePath -> IO ()
autoStart autostartfile = do
	dirs <- nub . lines <$> readFile autostartfile
	edirs <- filterM doesDirectoryExist dirs
	case edirs of
		[] -> firstRun -- what else can I do? Nothing works..
		(d:_) -> do
			changeWorkingDirectory d
			state <- Annex.new =<< Git.CurrentRepo.get
			void $ Annex.eval state $ doCommand $ start' False

{- Run the webapp without a repository, which prompts the user, makes one,
 - changes to it, starts the regular assistant, and redirects the
 - browser to its url.
 -
 - This is a very tricky dance -- The first webapp calls the signaler,
 - which signals the main thread when it's ok to continue by writing to a
 - MVar. The main thread starts the second webapp, and uses its callback
 - to write its url back to the MVar, from where the signaler retrieves it,
 - returning it to the first webapp, which does the redirect.
 -
 - Note that it's important that mainthread never terminates! Much
 - of this complication is due to needing to keep the mainthread running.
 -}
firstRun :: IO ()
firstRun = do
	{- Without a repository, we cannot have an Annex monad, so cannot
	 - get a ThreadState. Using undefined is only safe because the
	 - webapp checks its noAnnex field before accessing the
	 - threadstate. -}
	let st = undefined
	{- Get a DaemonStatus without running in the Annex monad. -}
	dstatus <- atomically . newTMVar =<< newDaemonStatus
	d <- newAssistantData st dstatus
	urlrenderer <- newUrlRenderer
	v <- newEmptyMVar
	let callback a = Just $ a v
	void $ runAssistant d $ runNamedThread $
		webAppThread d urlrenderer True 
			(callback signaler)
			(callback mainthread)
  where
	signaler v = do
		putMVar v ""
		takeMVar v
	mainthread v _url htmlshim = do
		browser <- maybe Nothing webBrowser <$> Git.Config.global
		openBrowser browser htmlshim Nothing Nothing

		_wait <- takeMVar v

		state <- Annex.new =<< Git.CurrentRepo.get
		Annex.eval state $
			startDaemon True True $ Just $ sendurlback v
	sendurlback v _origout _origerr url _htmlshim = putMVar v url

openBrowser :: Maybe FilePath -> FilePath -> Maybe Handle -> Maybe Handle -> IO ()
openBrowser cmd htmlshim outh errh = do
	hPutStrLn (fromMaybe stdout outh) $ "Launching web browser on " ++ url
	environ <- cleanEnvironment
	(_, _, _, pid) <- createProcess p
		{ env = environ
		, std_out = maybe Inherit UseHandle outh
		, std_err = maybe Inherit UseHandle errh
		}
	exitcode <- waitForProcess pid
	unless (exitcode == ExitSuccess) $
		hPutStrLn (fromMaybe stderr errh) "failed to start web browser"
  where
	url = fileUrl htmlshim
	p = proc (fromMaybe browserCommand cmd) [htmlshim]

{- web.browser is a generic git config setting for a web browser program -}
webBrowser :: Git.Repo -> Maybe FilePath
webBrowser = Git.Config.getMaybe "web.browser"

fileUrl :: FilePath -> String
fileUrl file = "file://" ++ file
