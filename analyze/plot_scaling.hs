#!/usr/bin/env runhaskell
{-# LANGUAGE NamedFieldPuns
  #-}

-- This script generates gnuplot plots.
-- Give it a .dat file as input... (or it will try to open results.dat)

module Main where

-- import Text.PrettyPrint.HughesPJClass
import Text.Regex
import Data.List
import Data.Maybe (mapMaybe)
import Data.Function
import Control.Monad
import System.Process (system)
import System.IO
import System.FilePath 
import System.Exit
import System.Environment
import System.Console.GetOpt (getOpt, ArgOrder(Permute), 
			      OptDescr(Option), ArgDescr(NoArg,ReqArg), usageInfo)

import HSH
import Data.Array (listArray)
import Data.Monoid (mappend)
import Debug.Trace (trace)

import ScriptHelpers
import DatfileHelpers

--------------------------------------------------------------------------------
-- Settings

linewidth = "5.0"

-- Ok, gunplot line type 6 is YELLOW... that's not too smart:
line_types = [0..5] ++ [7..]

round_2digits :: Double -> Double
round_2digits n = (fromIntegral $round (n * 100)) / 100

   
--------------------------------------------------------------------------------
-- Let's take a particular interpretation of Enum for pairs:
instance (Enum t1, Enum t2) => Enum (t1,t2) where 
  succ (a,b) = (succ a, succ b)
  pred (a,b) = (pred a, pred b)
  toEnum n = (toEnum n, toEnum n)
  fromEnum (a,b) = case (fromEnum a, fromEnum b) of
                     (x,y) | x == y -> x
		     (x,y) -> error$ "fromEnum of pair: nonmatching numbers: " ++ show x ++" and "++ show y


-- Removes single blanks and separates lines into groups based on double blanks.
sepDoubleBlanks :: [String] -> [[String]]
sepDoubleBlanks ls = loop [] ls 
 where 
  loop acc []        = [reverse acc]
  loop acc ("":"":t) = reverse acc : loop [] (stripLeadingBlanks t)
  loop acc ("":t)    = loop acc t
  loop acc (h :t)    = loop (h:acc) t 
  stripLeadingBlanks []     = [] 
  stripLeadingBlanks ("":t) = stripLeadingBlanks t
  stripLeadingBlanks ls     = ls


--------------------------------------------------------------------------------

groupSort fn = 
   (groupBy ((==) `on` fn)) . 
   (sortBy (compare `on` fn))

-- | Add three more levels of list nesting to organize the data:
organize_data :: [Entry] -> [[[[Entry]]]]
organize_data = 
	 (map (map (groupSort sched)))  . 
  	      (map (groupSort variant)) .
                   (groupSort name)


newtype Mystr = Mystr String

instance Show Mystr where
  show (Mystr s) = s

--               Name, Variant, Scheduler,        Threads, BestTime, Speedup
data Best = Best (String, String, String,   Int, Double, Double)

matchShape :: [[a]] -> [b] -> [[b]]
matchShape [] [] = []
matchShape [] _  = error "matchShape: not the same number of elements"
matchShape (h:tl) ls = take (length h) ls : 
		       matchShape tl (drop (length h) ls)

----------------------------------------------------------------------------------------------------

{-
   I ended up giving up on using the gnuplot package on hackage.

   The below script turns a single benchmark into a gnuplot script
   (produced as a string).

   plot_benchmark2 expects entries with three levels of grouping, from
   outside to in:
     * Name 
     * Variant (e.g. variant of the benchmark)
     * Sched

-}
plot_benchmark2 :: [Double] -> String -> [[[Entry]]] -> [String] -> IO Best

plot_benchmark2 basetimes root entries ignored_scheds = 
    do let lineplots = filter goodSched (concat entries) 
       action lineplots (map head$ matchShape lineplots basetimes)
       putStrLn$ " PLOTTING BENCHMAKR "++ show benchname ++ " best index "++ show best_index ++ " of "++ show (length basetimes)
       return$ Best (benchname, bestvariant, 
		     bestsched, bestthreads, best, 
		     (basetimes !! best_index) / best)
 where 
  benchname = name $ head $ head $ head entries
  -- What was the best single-threaded execution time across variants/schedulers:

  goodSched [] = error "Empty block of data entries..."
  goodSched (h:t) = not $ (sched h) `elem` ignored_scheds 
  
  -- Knock down two levels of grouping leaving only Scheduler:
  cat = concat $ map concat entries

  -- threads0 = filter ((== 0) . threads) cat
  -- threads1 = filter ((== 1) . threads) cat
  map_normalized_time = map (\x -> tmed x / normfactor x)

  best = foldl1 min $ map_normalized_time cat
  -- Index into CONCATENATED version:
  Just best_index = elemIndex best $ map_normalized_time cat
  bestsched   = sched  $ cat !! best_index
  bestvariant = variant$ cat !! best_index
  bestthreads = threads$ cat !! best_index

  (filebase,_) = break (== '.') $ basename benchname 

  -- If all normfactors are the default 1.0 we print a different message:
  --let is_norm = not$ all (== 1.0) $ map normfactor ponits
  norms = map normfactor cat
  default_norms = all (== 1.0) $ norms
  max_norm = foldl1 max norms

  scrub '_' = ' '
  scrub x = x

  action lines basetimes = 
   do 
      let scriptfile = root ++ filebase ++ ".gp"
      putStrLn$ "  Drawing "++show(length lines)++" lines. Dumping gnuplot script to: "++ scriptfile
      putStrLn$ "    NORM FACTORS "++ show norms

      let str_basetimes = if 1 == length (nub basetimes) -- All the same
	                  then show (round_2digits $ (head basetimes) * max_norm)
			  else unwords$ map show $ nub basetimes

      runIO$ echo "set terminal postscript enhanced color\n"         -|- appendTo scriptfile
      runIO$ echo ("set output \""++filebase++".eps\"\n")            -|- appendTo scriptfile
      runIO$ echo ("set title \"Benchmark: "++ map scrub filebase ++
		   ", speedup relative to serial time " ++ str_basetimes ++" seconds "++ 
--		   "for input size " ++ show (round_2digits max_norm)
		   (if default_norms then "" else "for input size " ++ show (round max_norm))
		   --if is_norm then "normalized to work unit"
		   --if default_norms then "" else " per unit benchmark input"
		   ++"\"\n") -|- appendTo scriptfile
      runIO$ echo ("set xlabel \"Number of Threads\"\n")             -|- appendTo scriptfile
      runIO$ echo ("set ylabel \"Parallel Speedup\"\n")              -|- appendTo scriptfile
      runIO$ echo ("set xrange [1:]\n")                              -|- appendTo scriptfile
      runIO$ echo ("set key left top\n")                             -|- appendTo scriptfile
      runIO$ echo ("plot \\\n")                                      -|- appendTo scriptfile

      -- In this loop does the errorbars:
      forM_ (zip [1..] lines) $ \(i,points) -> do 
          let datfile = root ++ filebase ++ show i ++".dat"
	  runIO$ echo ("   \""++ basename datfile ++"\" using 1:2:3:4 with errorbars lt "++
	              show (line_types !! i)	              
		      ++" title \"\", \\\n") -|- appendTo scriptfile

      -- Now a second loop for the lines themselves and to dump the actual data to the .dat file:
      forM_ (zip [1..] lines) $ \(i,points) -> do 
          let datfile = root ++ filebase ++ show i ++".dat"          
	  let schd = sched$   head points  -- should be the same across all point
	  let var  = variant$ head points  -- should be the same across all point
	  let nickname = var ++"/"++ schd
	  runIO$ echo ("# Data for variant "++ nickname ++"\n") -|- appendTo datfile

          let lines_basetimes = basetimes!!(i-1)

          putStrLn$ "   "++show(i-1)++": Normalizing Sched "++ show schd++ " to serial baseline "++show (basetimes!!(i-1))
          forM_ points $ \x -> do 

              -- Here we print a line of output:
	      runIO$ echo (show (fromIntegral (threads x)) ++" "++
			   show (lines_basetimes / (tmed x / normfactor x))        ++" "++
                           show (lines_basetimes / (tmax x / normfactor x))        ++" "++ 
			   show (lines_basetimes / (tmin x / normfactor x))        ++" \n") -|- appendTo datfile

	  let comma = if i == length lines then "" else ",\\"
	  runIO$ echo ("   \""++ basename datfile ++
		       "\" using 1:2 with lines linewidth "++linewidth++" lt "++ 
		       show (line_types !! i) ++" title \""++nickname++"\" "++comma++"\n")
		   -|- appendTo scriptfile

      --putStrLn$ "Finally, running gnuplot..."
      --runIO$ "(cd "++root++"; gnuplot "++basename scriptfile++")"
      --runIO$ "(cd "++root++"; ps2pdf "++ filebase ++".eps )"


--------------------------------------------------------------------------------
--                              Main Script                                   --
--------------------------------------------------------------------------------

-- | Datatype for command line flags.
data Flag = SerialBasecase
	  | IgnoreSched String
	  | Relative
  deriving Eq

-- | Command line options.
cli_options :: [OptDescr Flag]
cli_options = 
     [ Option [] ["serial"] (NoArg SerialBasecase)
          "use THREADS=0 cases to further handicap parallel speedup based on overhead of compiling with -threaded."

     , Option [] ["ignore"] (ReqArg IgnoreSched "SCHED")
          "ignore all datapoints with scheduler SCHED"

     , Option [] ["relative"] (NoArg Relative)
          "do not normalize all schedulers to the same serial baseline"
     ]


main = do 
 rawargs <- getArgs 
 let (options,args,errs) = getOpt Permute cli_options rawargs
     exitUsage = do
	putStrLn$ "Errors parsing command line options:" 
	mapM_ (putStr . ("   "++)) errs
	putStr$ usageInfo "Usage plot_scaling [OPTIONS] <results.dat>" cli_options
	exitFailure
 unless (null errs) exitUsage
 file <- case args of 
	   [f] -> return f 
	   _   -> exitUsage

 -- Read in the .dat file, ignoring comments:
 parsed0 <- parseDatFile file
 let parsed = if SerialBasecase `elem` options
              then parsed0
	      else filter (\ Entry{threads} -> threads /= 0) parsed0

-- mapM_ print parsed
 let organized = organize_data parsed

 putStrLn$ "Parsed "++show (length parsed)++" lines containing data."
-- This can get big, I was just printing it for debugging:
-- print organized

 let root = "./" ++ dropExtension file ++ "_graphs/"
     ignoredScheds = concatMap isched options 
     isched (IgnoreSched name) = [name]
     isched _ = []

 -- For hygiene, completely anhilate output directory:
 system$ "rm -rf "  ++root ++"/"
 system$ "mkdir -p "++root
 bests <- 
  forM organized    $ \ perbenchmark -> do 

   ------------------------------------------------------------
   -- The baseline case is either 0 threads (i.e. no "-threaded") or
   -- -threaded with +RTS -N1:
   let allrows = concat $ map concat perbenchmark
       threads0or1 = filter ((== 0) . threads) allrows ++
                     filter ((== 1) . threads) allrows
       calcbase pred onerow = 
	let benchname = name $ head $ head $ head perbenchmark	    
	    map_normalized_time = map (\x -> tmed x / normfactor x)
	    times0or1 = map_normalized_time (filter (pred onerow) threads0or1)
	    basetime = if    not$ null times0or1
		       then foldl1 min times0or1
		       else error$ "\nFor benchmark "++ show benchname ++ 
				   " could not find either 1-thread or 0-thread run.\n" ++
				   "\nALL entries threads: "++ show (map threads allrows)
	in basetime
   ------------------------------------------------------------
   let basetimes = 
          if Relative `elem` options
          -- In relative mode we create a separate per-scheduler serial baseline:
	  then map (calcbase (\a b -> sched a == sched b)) allrows
	  else replicate (length allrows)
	                 (calcbase (\_ _ -> True) allrows)
   ------------------------------------------------------------
   putStrLn$ "SERIAL BASELINES: " ++ show basetimes

   best <- plot_benchmark2 basetimes root perbenchmark ignoredScheds
   forM_ perbenchmark $ \ pervariant -> 
    forM_ pervariant   $ \ persched -> 
      do let mins = map tmin persched
 	 let pairs = (zip (map (fromIntegral . threads) persched) mins)
	 --putStrLn$ show pairs
	 --plot Graphics.Gnuplot.Terminal.X11.cons (path pairs)
	 --System.exitWith ExitSuccess
	 --plot x11 (path pairs)
         return ()

   return best

 putStrLn$ "Now generating final plot files...\n\n"

 let summarize hnd = do 
       hPutStrLn hnd $ "# Benchmark, Variant, Scheduler, best #threads, best median time, max parallel speedup: "
       hPutStrLn hnd $ "# Summary for " ++ file

       let pads n s = take (n - length s) $ repeat ' '
       let pad  n x = " " ++ (pads n (show x))

       forM_ bests $ \ (Best(name, variant, sched, threads, best, speed)) ->
	 hPutStrLn hnd$ "    "++ name++  (pad 25 name) ++
			  variant++ (pad 20 variant)++
			  sched++   (pad 10 sched) ++
			  show threads++ (pad 5 threads)++ 
			  show best ++   (pad 15 best) ++
			  show speed 
       hPutStrLn hnd$ "\n\n"

 putStrLn$ "Done."
 summarize stdout
 withFile (dropExtension file `addExtension` "summary") WriteMode $ summarize 

