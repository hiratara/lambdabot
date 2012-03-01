{-# LANGUAGE TemplateHaskell, TypeFamilies #-}

-- | Pointfree programming fun
--
-- A catalogue of refactorings is at:
--      http://www.cs.kent.ac.uk/projects/refactor-fp/catalogue/
--      http://www.cs.kent.ac.uk/projects/refactor-fp/catalogue/RefacIdeasAug03.html
--
-- Use more Arrow stuff
--
-- TODO would be to plug into HaRe and use some of their refactorings.
module Plugin.Pl (theModule) where

import Plugin

import Plugin.Pl.Common          (TopLevel, mapTopLevel, getExpr)
import Plugin.Pl.Parser          (parsePF)
import Plugin.Pl.PrettyPrinter   (Expr)
import Plugin.Pl.Transform       (transform)
import Plugin.Pl.Optimize        (optimize)

import Lambdabot.Message( Nick )

import Control.Concurrent.Chan    (Chan, newChan, isEmptyChan, readChan, writeList2Chan)
import Control.Exception (unblock)
-- firstTimeout is the timeout when the expression is simplified for the first
-- time. After each unsuccessful attempt, this number is doubled until it hits
-- maxTimeout.
firstTimeout, maxTimeout :: Int
firstTimeout =  3000000 --  3 seconds
maxTimeout   = 15000000 -- 15 seconds

type PlState = GlobalPrivate () (Int, TopLevel)

$(plugin "Pl")

instance Module PlModule where
    type ModuleState PlModule = PlState

    moduleCmds _ = 
        [ (command "pointless")
            { aliases = ["pl"]
            , help = say "pointless <expr>. Play with pointfree code."
            , process = \rest -> do
                target <- getTarget
                lift (pf target rest) >>= mapM_ say
            }
        , (command "pl-resume")
            { help = say "pl-resume. Resume a suspended pointless transformation."
            , process = \_ -> do
                target <- getTarget
                lift (res target) >>= mapM_ say
            }
        ]

    moduleDefState _ = return $ mkGlobalPrivate 15 ()

------------------------------------------------------------------------

res :: Nick -> Pl [String]
res target = do
  d <- readPS target
  case d of
    Nothing -> return ["pointless: sorry, nothing to resume."]
    Just d' -> optimizeTopLevel target d'

-- | Convert a string to pointfree form
pf :: Nick -> String -> Pl [String]
pf target inp = case parsePF inp of
  Right d  -> optimizeTopLevel target (firstTimeout, mapTopLevel transform d)
  Left err -> return [err]

optimizeTopLevel :: Nick -> (Int, TopLevel) -> Pl [String]
optimizeTopLevel target (to, d) = do
  let (e,decl) = getExpr d
  (e', finished) <- io $ optimizeIO to e
  extra <- if finished
           then do writePS target Nothing
                   return []
           else do writePS target $ Just (min (2*to) maxTimeout, decl e')
                   return ["optimization suspended, use @pl-resume to continue."]
  return $ (show $ decl e') : extra

------------------------------------------------------------------------

optimizeIO :: Int -> Expr -> IO (Expr, Bool)
optimizeIO to e = do
  chan <- newChan
  -- We need "unblock" here because "timeout" will terminate the thread
  -- with an async exception and the current thread is in blocked
  -- mode for reasons that still aren't clear to me.
  result <- timeout to $ unblock (writeList2Chan chan $ optimize e)
  e' <- getChanLast chan e
  return $ case result of
    Nothing -> (e', False)
    Just _  -> (e', True)

getChanLast :: Chan a -> a -> IO a
getChanLast c x = do
  b <- isEmptyChan c
  if b then return x else getChanLast c =<< readChan c
