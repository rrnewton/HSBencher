{-# LANGUAGE NamedFieldPuns, ScopedTypeVariables #-}

-- | Misc Small Helpers

module HSBencher.Utils where

import Control.Concurrent
import Control.Exception (evaluate, handle, SomeException, throwTo, fromException, AsyncException(ThreadKilled))
import qualified Data.Set as Set
import Data.Char (isSpace)
import Data.List (isPrefixOf)
import Data.IORef
import qualified Data.ByteString.Char8 as B
import Control.Monad.Reader -- (lift, runReaderT, ask)
import qualified System.IO.Streams as Strm

import System.Process (system, waitForProcess, getProcessExitCode, runInteractiveCommand, 
                       createProcess, CreateProcess(..), CmdSpec(..), StdStream(..), readProcess)
import System.Environment (getArgs, getEnv, getEnvironment, getExecutablePath)
import System.IO (Handle, hPutStrLn, stderr, openFile, hClose, hGetContents, hIsEOF, hGetLine,
                  IOMode(..), BufferMode(..), hSetBuffering)
import System.Exit
import System.IO.Unsafe (unsafePerformIO)
import Text.Printf
import Prelude hiding (log)

import HSBencher.Types hiding (env)
import HSBencher.Logging

----------------------------------------------------------------------------------------------------
-- Global constants, variables:

-- TODO: grab this from the command line arguments:
my_name :: String
my_name = "hsbencher"

-- | In seconds.
defaultTimeout :: Double
defaultTimeout = 150

-- | Global variable holding the main thread id.
main_threadid :: IORef ThreadId
main_threadid = unsafePerformIO$ newIORef (error "main_threadid uninitialized")

--------------------------------------------------------------------------------

-- These int list arguments are provided in a space-separated form:
parseIntList :: String -> [Int]
parseIntList = map read . words 

-- Remove whitespace from both ends of a string:
trim :: String -> String
trim = f . f
   where f = reverse . dropWhile isSpace

-- | Parse a simple "benchlist.txt" file.
parseBenchList :: String -> [Benchmark]
parseBenchList str = 
  map parseBench $                 -- separate operator, operands
  filter (not . null) $            -- discard empty lines
  map words $ 
  filter (not . isPrefixOf "#") $  -- filter comments
  map trim $
  lines str

-- Parse one line of a benchmark file (a single benchmark name with args).
parseBench :: [String] -> Benchmark
parseBench (h:m:tl) = Benchmark {name=h, compatScheds=expandMode m, args=tl }
parseBench ls = error$ "entry in benchlist does not have enough fields (name mode args): "++ unwords ls

strBool :: String -> Bool
strBool ""  = False
strBool "0" = False
strBool "1" = True
strBool  x  = error$ "Invalid boolean setting for environment variable: "++x

fst3 (a,b,c) = a
snd3 (a,b,c) = b
thd3 (a,b,c) = c

-- Compute a cut-down version of a benchmark's args list that will do
-- a short (quick) run.  The way this works is that benchmarks are
-- expected to run and do something quick if they are invoked with no
-- arguments.  (A proper benchmarking run, therefore, requires larger
-- numeric arguments be supplied.)
-- 
-- HOWEVER: there's a further hack here which is that leading
-- non-numeric arguments are considered qualitative (e.g. "monad" vs
-- "sparks") rather than quantitative and are not pruned by this
-- function.
shortArgs :: [String] -> [String]
shortArgs [] = []
-- Crop as soon as we see something that is a number:
shortArgs (h:tl) | isNumber h = []
		 | otherwise  = h : shortArgs tl

isNumber :: String -> Bool
isNumber s =
  case reads s :: [(Double, String)] of 
    [(n,"")] -> True
    _        -> False

-- Based on a benchmark configuration, come up with a unique suffix to
-- distinguish the executable.
uniqueSuffix :: BenchRun -> String
uniqueSuffix BenchRun{threads,sched,bench} =    
  "_" ++ show sched ++ 
   if threads == 0 then "_serial"
                   else "_threaded"


-- Indent for prettier output
indent :: [String] -> [String]
indent = map ("    "++)


--------------------------------------------------------------------------------
-- TODO -- all this Mode selection should be factored out to make this
-- benchmark script a bit more generic.
--------------------------------------------------------------------------------


-- [2012.05.03] RRN: ContFree is not exposed, thus removing it from the
-- default set, though you can still ask for it explicitly:
defaultSchedSet :: Set.Set Sched
defaultSchedSet = Set.difference (Set.fromList [minBound ..])
                               (Set.fromList [ContFree, NUMA, SMP])

-- Omitting ContFree, as it takes way too long for most trials
ivarScheds :: [Sched]
ivarScheds = [Trace, Direct, SMP, NUMA] 
-- ivarScheds = [Trace, Direct]

-- TODO -- we really need to factor this out into a configuration file.
schedToModule :: Sched -> String
schedToModule s = 
  case s of 
--   Trace    -> "Control.Monad.Par"
   Trace    -> "Control.Monad.Par.Scheds.Trace"
   Direct   -> "Control.Monad.Par.Scheds.Direct"
   ContFree -> "Control.Monad.Par.Scheds.ContFree"
   Sparks   -> "Control.Monad.Par.Scheds.Sparks"
   SMP      -> "Control.Monad.Par.Meta.SMP"
   NUMA     -> "Control.Monad.Par.Meta.NUMAOnly"
   None     -> "qualified Control.Monad.Par as NotUsed"

schedToCabalFlag :: Sched -> String
schedToCabalFlag s =
  case s of
    Trace -> "--flags=\"-ftrace\""
    Direct -> "--flags=\"-fdirect\""
    ContFree -> "--flags=\"-fcontfree\""
    Sparks -> "--flags=\"-fsparks\""
    SMP -> "--flags=\"-fmeta-smp\""
    NUMA -> "--flags=\"-fmeta-numa\""
    None -> ""

-- TODO - GET RID OF THIS:
-- | Expand the mode string into a list of specific schedulers to run:
expandMode :: String -> [Sched]
expandMode "default" = [Trace]
expandMode "none"    = [None]
-- TODO: Add RNG:
expandMode "futures" = [Sparks] ++ ivarScheds
expandMode "ivars"   = ivarScheds 
expandMode "chans"   = [] -- Not working yet!

-- [future] Schedulers in which nested execution WORKS!
expandMode "nested"      = [Sparks,Direct] -- [2012.11.26]
expandMode "nested+ivar" = [Direct]        -- [2012.11.26]

-- Also allowing the specification of a specific scheduler:
expandMode "Trace"    = [Trace]
expandMode "Sparks"   = [Sparks]
expandMode "Direct"   = [Direct]
expandMode "ContFree" = [ContFree]
expandMode "SMP"      = [SMP]
expandMode "NUMA"     = [NUMA]

expandMode s = error$ "Unknown Scheduler or mode: " ++s


--------------------------------------------------------------------------------



----------------------------------------------------------------------------------------------------

------------------------------------------------------------

-- Helper for launching processes with logging and error checking
-----------------------------------------------------------------
-- [2012.05.03] HSH has been causing no end of problems in the
-- subprocess-management department.  Here we instead use the
-- underlying createProcess library function:
runCmdWithEnv :: Bool -> [(String, String)] -> String
              -> BenchM (String, ExitCode)
runCmdWithEnv echo env cmd = do 
  -- This current design has the unfortunate disadvantage that it
  -- produces no observable output until the subprocess is FINISHED.
  log$ "Executing: " ++ cmd
  baseEnv <- lift$ getEnvironment
  (Nothing, Just outH, Just errH, ph) <- lift$ createProcess 
     CreateProcess {
       cmdspec = ShellCommand cmd,
       env = Just$ baseEnv ++ env,
       std_in  = Inherit,
       std_out = CreatePipe,
       std_err = CreatePipe,
       cwd = Nothing,
       close_fds = False,
       create_group = False
     }
  mv1 <- echoThread echo outH
  mv2 <- echoThread echo errH
  lift$ waitForProcess ph  
  Just code <- lift$ getProcessExitCode ph  
  outStr <- lift$ takeMVar mv1
  _      <- lift$ takeMVar mv2
                
  Config{keepgoing} <- ask
  check keepgoing code ("ERROR, "++my_name++": command \""++cmd++"\" failed with code "++ show code)
  return (outStr, code)


-----------------------------------------------------------------
runIgnoreErr :: String -> IO String
runIgnoreErr cm = 
  do lns <- runLines cm
     return (unlines lns)
-----------------------------------------------------------------

-- | Create a thread that echos the contents of a Handle as it becomes
--   available.  Then return all text read through an MVar when the
--   handle runs dry.
echoThread :: Bool -> Handle -> BenchM (MVar String)
echoThread echoStdout hndl = do
  mv   <- lift$ newEmptyMVar
  conf <- ask
  lift$ void$ forkIOH "echo thread"  $ 
    runReaderT (echoloop mv []) conf    
  return mv  
 where
   echoloop mv acc = 
     do b <- lift$ hIsEOF hndl 
        if b then do lift$ hClose hndl
                     lift$ putMVar mv (unlines$ reverse acc)
         else do ln <- lift$ hGetLine hndl
                 logOn (if echoStdout then [LogFile, StdOut] else [LogFile]) ln 
                 echoloop mv (ln:acc)

-- | Create a thread that echos the contents of stdout/stderr InputStreams (lines) to
-- the appropriate places.
echoStream :: Bool -> Strm.InputStream B.ByteString -> BenchM (MVar ())
echoStream echoStdout outS = do
  conf <- ask
  mv   <- lift$ newEmptyMVar
  lift$ void$ forkIOH "echoStream thread"  $ 
    runReaderT (echoloop mv) conf 
  return mv
 where
   echoloop mv = 
     do
        x <- lift$ Strm.read outS
        case x of
          Nothing -> lift$ putMVar mv ()
          Just ln -> do
--            logOn (if echoStdout then [LogFile, StdOut] else [LogFile]) (B.unpack ln)
            lift$ B.putStrLn ln
            echoloop mv


-- | Runs a command through the OS shell and returns stdout split into
-- lines.
runLines :: String -> IO [String]
runLines cmd = do
  putStr$ "   * Executing: " ++ cmd 
  (Nothing, Just outH, Nothing, ph) <- createProcess 
     CreateProcess {
       cmdspec = ShellCommand cmd,
       env = Nothing,
       std_in  = Inherit,
       std_out = CreatePipe,
       std_err = Inherit,
       cwd = Nothing,
       close_fds = False,
       create_group = False
     }
  waitForProcess ph  
  Just _code <- getProcessExitCode ph  
  str <- hGetContents outH
  let lns = lines str
  putStrLn$ " -->   "++show (length lns)++" line(s)"
  return (lines str)


-- | Runs a command through the OS shell and returns the first line of
-- output.
runSL :: String -> IO String
runSL cmd = do
  lns <- runLines cmd
  case lns of
    h:_ -> return h
    []  -> error$ "runSL: expected at least one line of output for command "++cmd



-- Check the return code from a call to a test executable:
check :: Bool -> ExitCode -> String -> BenchM Bool
check _ ExitSuccess _           = return True
check keepgoing (ExitFailure code) msg  = do
  Config{ghc_flags, ghc_RTS} <- ask
  let report = log$ printf " #      Return code %d Params: %s, RTS %s " (143::Int) ghc_flags ghc_RTS
  case code of 
   143 -> 
     do report
        log         " #      Process TIMED OUT!!" 
   _ -> 
     do log$ " # "++msg 
	report 
        log "XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"
        unless keepgoing $ 
          lift$ exitWith (ExitFailure code)
  return False


-- | Fork a thread but ALSO set up an error handler.
forkIOH :: String -> IO () -> IO ThreadId
forkIOH who action = 
  forkIO $ handle (\ (e::SomeException) -> 
                   case fromException e of
                     Just ThreadKilled -> return ()
                     Nothing -> do
                        printf $ "ERROR: "++who++": Got exception inside forked thread: "++show e++"\n"                       
			tid <- readIORef main_threadid
			throwTo tid e
		  )
           action
