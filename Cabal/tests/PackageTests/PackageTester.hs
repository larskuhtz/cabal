{-# LANGUAGE ScopedTypeVariables #-}

-- You can set the following VERBOSE environment variable to control
-- the verbosity of the output generated by this module.
module PackageTests.PackageTester
    ( PackageSpec(..)
    , Success(..)
    , Result(..)

    -- * Running cabal commands
    , cabal_configure
    , cabal_build
    , cabal_haddock
    , cabal_test
    , cabal_bench
    , cabal_install
    , unregister
    , compileSetup
    , run

    -- * Test helpers
    , assertBuildSucceeded
    , assertBuildFailed
    , assertHaddockSucceeded
    , assertTestSucceeded
    , assertInstallSucceeded
    , assertOutputContains
    , assertOutputDoesNotContain
    ) where

import qualified Control.Exception.Extensible as E
import Control.Monad
import qualified Data.ByteString.Char8 as C
import Data.List
import Data.Maybe
import System.Directory (canonicalizePath, doesFileExist, getCurrentDirectory)
import System.Environment (getEnv)
import System.Exit (ExitCode(ExitSuccess))
import System.FilePath
import System.IO
import System.IO.Error (isDoesNotExistError)
import System.Process (runProcess, waitForProcess)
import Test.HUnit (Assertion, assertFailure)

import Distribution.Simple.BuildPaths (exeExtension)
import Distribution.Simple.Utils (printRawCommandAndArgs)
import Distribution.Compat.CreatePipe (createPipe)
import Distribution.ReadE (readEOrFail)
import Distribution.Verbosity (Verbosity, flagToVerbosity, normal)

data PackageSpec = PackageSpec
    { directory  :: FilePath
    , configOpts :: [String]
    }

data Success = Failure
             | ConfigureSuccess
             | BuildSuccess
             | HaddockSuccess
             | InstallSuccess
             | TestSuccess
             | BenchSuccess
             deriving (Eq, Show)

data Result = Result
    { successful :: Bool
    , success    :: Success
    , outputText :: String
    } deriving Show

nullResult :: Result
nullResult = Result True Failure ""

------------------------------------------------------------------------
-- * Running cabal commands

recordRun :: (String, ExitCode, String) -> Success -> Result -> Result
recordRun (cmd, exitCode, exeOutput) thisSucc res =
    res { successful = successful res && exitCode == ExitSuccess
        , success    = if exitCode == ExitSuccess then thisSucc
                       else success res
        , outputText =
            (if null $ outputText res then "" else outputText res ++ "\n") ++
            cmd ++ "\n" ++ exeOutput
        }

cabal_configure :: PackageSpec -> FilePath -> IO Result
cabal_configure spec ghcPath = do
    res <- doCabalConfigure spec ghcPath
    record spec res
    return res

doCabalConfigure :: PackageSpec -> FilePath -> IO Result
doCabalConfigure spec ghcPath = do
    cleanResult@(_, _, _) <- cabal spec ["clean"] ghcPath
    requireSuccess cleanResult
    res <- cabal spec
           (["configure", "--user", "-w", ghcPath] ++ configOpts spec)
           ghcPath
    return $ recordRun res ConfigureSuccess nullResult

doCabalBuild :: PackageSpec -> FilePath -> IO Result
doCabalBuild spec ghcPath = do
    configResult <- doCabalConfigure spec ghcPath
    if successful configResult
        then do
            res <- cabal spec ["build", "-v"] ghcPath
            return $ recordRun res BuildSuccess configResult
        else
            return configResult

cabal_build :: PackageSpec -> FilePath -> IO Result
cabal_build spec ghcPath = do
    res <- doCabalBuild spec ghcPath
    record spec res
    return res

cabal_haddock :: PackageSpec -> [String] -> FilePath -> IO Result
cabal_haddock spec extraArgs ghcPath = do
    res <- doCabalHaddock spec extraArgs ghcPath
    record spec res
    return res

doCabalHaddock :: PackageSpec -> [String] -> FilePath -> IO Result
doCabalHaddock spec extraArgs ghcPath = do
    configResult <- doCabalConfigure spec ghcPath
    if successful configResult
        then do
            res <- cabal spec ("haddock" : extraArgs) ghcPath
            return $ recordRun res HaddockSuccess configResult
        else
            return configResult

unregister :: String -> FilePath -> IO ()
unregister libraryName ghcPkgPath = do
    res@(_, _, output) <- run Nothing ghcPkgPath ["unregister", "--user", libraryName]
    if "cannot find package" `isInfixOf` output
        then return ()
        else requireSuccess res

-- | Install this library in the user area
cabal_install :: PackageSpec -> FilePath -> IO Result
cabal_install spec ghcPath = do
    buildResult <- doCabalBuild spec ghcPath
    res <- if successful buildResult
        then do
            res <- cabal spec ["install"] ghcPath
            return $ recordRun res InstallSuccess buildResult
        else
            return buildResult
    record spec res
    return res

cabal_test :: PackageSpec -> [String] -> FilePath -> IO Result
cabal_test spec extraArgs ghcPath = do
    res <- cabal spec ("test" : extraArgs) ghcPath
    let r = recordRun res TestSuccess nullResult
    record spec r
    return r

cabal_bench :: PackageSpec -> [String] -> FilePath -> IO Result
cabal_bench spec extraArgs ghcPath = do
    res <- cabal spec ("bench" : extraArgs) ghcPath
    let r = recordRun res BenchSuccess nullResult
    record spec r
    return r

compileSetup :: FilePath -> FilePath -> IO ()
compileSetup packageDir ghcPath = do
    wd <- getCurrentDirectory
    r <- run (Just $ packageDir) ghcPath
         [ "--make"
-- HPC causes trouble -- see #1012
--       , "-fhpc"
         , "-package-conf " ++ wd </> "../dist/package.conf.inplace"
         , "Setup.hs"
         ]
    requireSuccess r

-- | Returns the command that was issued, the return code, and the output text.
cabal :: PackageSpec -> [String] -> FilePath -> IO (String, ExitCode, String)
cabal spec cabalArgs ghcPath = do
    customSetup <- doesFileExist (directory spec </> "Setup.hs")
    if customSetup
        then do
            compileSetup (directory spec) ghcPath
            path <- canonicalizePath $ directory spec </> "Setup"
            run (Just $ directory spec) path cabalArgs
        else do
            -- Use shared Setup executable (only for Simple build types).
            path <- canonicalizePath "Setup"
            run (Just $ directory spec) path cabalArgs

-- | Returns the command that was issued, the return code, and hte output text
run :: Maybe FilePath -> String -> [String] -> IO (String, ExitCode, String)
run cwd path args = do
    verbosity <- getVerbosity
    -- path is relative to the current directory; canonicalizePath makes it
    -- absolute, so that runProcess will find it even when changing directory.
    path' <- do pathExists <- doesFileExist path
                canonicalizePath (if pathExists then path else path <.> exeExtension)
    printRawCommandAndArgs verbosity path' args
    (readh, writeh) <- createPipe
    pid <- runProcess path' args cwd Nothing Nothing (Just writeh) (Just writeh)

    -- fork off a thread to start consuming the output
    out <- suckH [] readh
    hClose readh

    -- wait for the program to terminate
    exitcode <- waitForProcess pid
    let fullCmd = unwords (path' : args)
    return ("\"" ++ fullCmd ++ "\" in " ++ fromMaybe "" cwd, exitcode, out)
  where
    suckH output h = do
        eof <- hIsEOF h
        if eof
            then return (reverse output)
            else do
                c <- hGetChar h
                suckH (c:output) h

requireSuccess :: (String, ExitCode, String) -> IO ()
requireSuccess (cmd, exitCode, output) =
    unless (exitCode == ExitSuccess) $
        assertFailure $ "Command " ++ cmd ++ " failed.\n" ++
        "output: " ++ output

record :: PackageSpec -> Result -> IO ()
record spec res = do
    C.writeFile (directory spec </> "test-log.txt") (C.pack $ outputText res)

------------------------------------------------------------------------
-- * Test helpers

assertBuildSucceeded :: Result -> Assertion
assertBuildSucceeded result = unless (successful result) $
    assertFailure $
    "expected: \'setup build\' should succeed\n" ++
    "  output: " ++ outputText result

assertBuildFailed :: Result -> Assertion
assertBuildFailed result = when (successful result) $
    assertFailure $
    "expected: \'setup build\' should fail\n" ++
    "  output: " ++ outputText result

assertHaddockSucceeded :: Result -> Assertion
assertHaddockSucceeded result = unless (successful result) $
    assertFailure $
    "expected: \'setup haddock\' should succeed\n" ++
    "  output: " ++ outputText result

assertTestSucceeded :: Result -> Assertion
assertTestSucceeded result = unless (successful result) $
    assertFailure $
    "expected: \'setup test\' should succeed\n" ++
    "  output: " ++ outputText result

assertInstallSucceeded :: Result -> Assertion
assertInstallSucceeded result = unless (successful result) $
    assertFailure $
    "expected: \'setup install\' should succeed\n" ++
    "  output: " ++ outputText result

assertOutputContains :: String -> Result -> Assertion
assertOutputContains needle result =
    unless (needle `isInfixOf` (concatOutput output)) $
    assertFailure $
    " expected: " ++ needle ++ "\n" ++
    " in output: " ++ output ++ ""
  where output = outputText result

assertOutputDoesNotContain :: String -> Result -> Assertion
assertOutputDoesNotContain needle result =
    when (needle `isInfixOf` (concatOutput output)) $
    assertFailure $
    "unexpected: " ++ needle ++
    " in output: " ++ output
  where output = outputText result

-- | Replace line breaks with spaces, correctly handling "\r\n".
concatOutput :: String -> String
concatOutput = unwords . lines . filter ((/=) '\r')

------------------------------------------------------------------------
-- Verbosity

lookupEnv :: String -> IO (Maybe String)
lookupEnv name =
    (fmap Just $ getEnv name)
    `E.catch` \ (e :: IOError) ->
        if isDoesNotExistError e
        then return Nothing
        else E.throw e

-- TODO: Convert to a "-v" flag instead.
getVerbosity :: IO Verbosity
getVerbosity = do
    maybe normal (readEOrFail flagToVerbosity) `fmap` lookupEnv "VERBOSE"
