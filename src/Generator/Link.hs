{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE NamedFieldPuns #-}
module Generator.Link (
    link
) where

import qualified Data.Graph as G
import qualified Data.Map as M
import qualified Data.Set as S
import qualified Data.List as L

import Data.List (isPrefixOf, intercalate, stripPrefix)
import Data.Char (isAlphaNum)
import Data.Tuple (swap)
import Data.Maybe (catMaybes)
import Data.Either (partitionEithers)
import Data.Monoid (Monoid)

import Prelude hiding(catch)
import System.FilePath ((</>), takeExtension, takeFileName)
import System.Directory (doesDirectoryExist, getDirectoryContents, copyFile, getModificationTime)
import Control.Applicative ((<$>))
import Control.Monad (unless, forM, forM_, filterM)
import Control.Exception (catch, IOException)
import System.IO.Error (isDoesNotExistError)
import System.IO (openFile, hGetLine, hPutStrLn, hIsEOF, IOMode(..), Handle, hClose)
import Encoding (zEncodeString)
import Module (Module, ModuleName, mkModule, moduleNameString, mkModuleName, moduleName, moduleNameSlashes, stringToPackageId)
import Outputable (showPpr)
import Distribution.Verbosity (Verbosity, normal)
import Distribution.Simple.Utils (findFileWithExtension, info, getDirectoryContentsRecursive, installOrdinaryFiles)
import Compiler.Variants

instance Show ModuleName where show = moduleNameString

data DependencyInfo = DependencyInfo {
    modules      :: S.Set ModuleName
  , files        :: S.Set FilePath
  , toSearch     :: [ModuleName]
  , functionDeps :: [((FilePath, Int), String, [String])]}
  deriving (Eq, Show)

emptyDeps = DependencyInfo S.empty S.empty [] []
appendDeps a b = DependencyInfo
                    (modules a `S.union` modules b)
                    (files a `S.union` files b)
                    (toSearch a ++ toSearch b)
                    (functionDeps a ++ functionDeps b)

link :: Variant -> String -> [FilePath] -> [FilePath] -> [ModuleName] -> [String] -> IO [String]
link var out searchPath objFiles pageModules _pageFunctions = do
    -- Output a the search path that should be used for dynamic loading
    writeFile (out </> "paths.js") $ "$hs_path = " ++ show searchPath

    -- Read in the dependencies stored at the start of each .js file.
    -- Read the .js files that corrispond to .o files.  We need to load them to get the ModuleName.
    let maybeObjectDeps dep = case S.elems $ modules dep of
                                [mod] -> Just (mod, dep)
                                _     -> Nothing
    objDeps <- (M.fromList . catMaybes . map maybeObjectDeps) <$> mapM readDeps objFiles

    -- Search for the required modules in the packages
    let initDeps = emptyDeps{modules=S.singleton (mkModuleName "GHC.Prim"), toSearch=pageModules}
    allDeps <- searchModules var searchPath objDeps initDeps

    let deps = functionDeps allDeps

        -- main and anything that starts with lazyLoad_
        isPageSymbol s = s == "$$ZCMain_main" || "_lazzyLoadzu" `isPrefixOf` (dropWhile (/='_') s)
        symbol (_, s, _) = s

        -- Nothing needs to depend on the page functions
        filteredDeps = map (\(x,s,others) -> (x,s,filter (not . isPageSymbol) others)) deps

        -- Make a graph based on the dependencies.
        (graph, lookupEdges, lookupVertex) = G.graphFromEdges filteredDeps

        pages :: [G.Vertex]
        pages = catMaybes . map lookupVertex . filter isPageSymbol $ map symbol deps

        -- Used by all
        primatives = catMaybes $ map lookupVertex [
            "$$GHCziTypes_False"
          , "$$GHCziTypes_True"]

        -- For every function identify the "pages" that need it.
        pageMap :: G.Vertex -> M.Map G.Vertex (S.Set G.Vertex)
        pageMap page = M.fromList $ zip (G.reachable graph page ++ primatives) (repeat $ S.fromList [page])
        functionToPageSet = M.unionsWith S.union (map pageMap pages)

        -- Group functions based by the set of pages that use them.
        pageSetToFunctions = M.fromListWith (++) . map (\(f, ps) -> (ps, [f])) $ M.toList functionToPageSet

        -- Comment listing the pages in a page set.
        lookupKey = (\(_,k,_)->k) . lookupEdges
        pageSetComment pageSet = map (\page -> '/':'/':(lookupKey page)) pageSet

        lengthFileAndKey ((file, len), key, _) = (len, (file, [key]))

    -- Determing the length of each page set.
    pageSetsWithLengths <- forM (M.toList pageSetToFunctions) $ \(pageSet, functions) -> do
        let s = map (lengthFileAndKey . lookupEdges) functions
        return (sum $ map fst s, (pageSet, map snd s))

    -- Combine smaller page sets (based on the lenth of the script).
    let compareSize (a,_) (b,_) = compare a b
        scriptsBySize = L.sortBy compareSize pageSetsWithLengths
        -- If the smallest two sizes is less than 20k then cobine them.
        combineSmall (a@(sa,(psA,scriptA)):b@(sb,(psB,scriptB)):rest) | sa + sb < 20000 =
            let new = (sa+sb, (psA `S.union` psB, scriptA++scriptB)) in
            combineSmall (L.insertBy compareSize new rest)
        combineSmall x = x
        combinedScripts = map snd $ combineSmall scriptsBySize

--    -- Create Java Script for each page set.
--    scripts <- forM (M.toList pageSetToFunctions) $ \(pageSet, functions) -> do
--        script <- mapM makeScript . M.toList . M.fromListWith (++) $ map (fileAndKey . lookupEdges) functions
--        return (sum $ map length script, (pageSet, script))

    bundles <- forM (zip [1..] combinedScripts) $ \(n, (pageSet, functions)) -> do
        out <- openFile (out++"hs"++show n++".js") WriteMode
        hPutStrLn out . unlines $ pageSetComment $ S.toList pageSet
        let scripts = M.toList . M.fromListWith (++) $ functions
        forM_ scripts $ copyScript isPageSymbol out
        hPutStrLn out $ "//@ sourceURL=hs"++show n++".js"
        hClose out
        return (n, pageSet)

    -- Work out the loader functions
    let pageToBundles :: M.Map Int [Int]
        pageToBundles = M.fromListWith (++) $ concatMap
                            (\(m, ps) -> map (\p -> (p, [m])) $ S.toList ps)
                            bundles

        loader :: [String]
        loader = ("// Bundle Count " ++ show (length combinedScripts)):
            map makeLoader (M.toList pageToBundles)

        makeLoader :: (Int, [Int]) -> String
        makeLoader (p, bs) = concat ["var ", lookupKey p,
            "=$L(", show bs,", function() { return $", lookupKey p, "; });"]

    writeFile (out++"hsloader.js") $ unlines loader

    return $ concatMap (\(n, _) -> [
                        "--js", concat [out, "hs", show n, ".js"],
                        "--module", concat ["hs", show n, "min:1:rts"]]
                        ) bundles ++ [
                        "--js", concat [out, "hsloader.js"]]

-- | This installs all the java script (.js) files in a directory to a target loction
-- preserving the directory layout.  Any files in ".jsexe" directories are ignored
-- as those sube directoies are likely to be the destination.
--
-- Only files with newer modification times are copied.
--
installJavaScriptFiles :: Variant -> Verbosity -> FilePath -> FilePath -> IO ()
installJavaScriptFiles var verbosity srcDir destDir = do
    info verbosity $ "Copying JavaScript From" ++ srcDir
    srcFiles <- getDirectoryContentsRecursive srcDir >>= filterM modTimeDiffers
    installOrdinaryFiles verbosity destDir [ (srcDir, f) | f <- srcFiles, variantExtension var `L.isSuffixOf` f ]
  where
    modTimeDiffers f = do
            srcTime  <- getModificationTime $ srcDir </> f
            destTime <- getModificationTime $ destDir </> f
            return $ destTime < srcTime
        `catch` \e -> if isDoesNotExistError e
                            then return True
                            else ioError e

searchModules :: Variant -> [FilePath] -> M.Map ModuleName DependencyInfo -> DependencyInfo -> IO DependencyInfo
searchModules var searchPath objDeps = \d -> do
 loop d
  where
    loop deps@DependencyInfo{toSearch=[]} = return deps -- No more modules to search
    loop deps@DependencyInfo{toSearch=(mod:mods)} = do
        case (mod `S.member` (modules deps), M.lookup mod objDeps) of
            (True, _)        -> loop deps{toSearch=mods} -- We already seearched this module
            (False, Just d)  -> loop (appendDeps deps d) -- It was in an object file
            (False, Nothing) -> do
                mbFile <- findFileWithExtension [variantExtension' var] searchPath (moduleNameSlashes mod)
                case mbFile of
                    Just file | not (file `S.member` (files deps)) -> do
                        fileDeps <- readDeps file
                        loop (appendDeps deps fileDeps)
                    _ -> loop deps{toSearch=mods} -- Can't find a file or we already seearched this file

readDeps :: FilePath -> IO DependencyInfo
readDeps file = do
    let fileDeps = emptyDeps{files = S.singleton file}
    h <- openFile file ReadMode
    eof <- hIsEOF h
    deps <- if eof
        then return fileDeps
        else do
            hGetLine h -- Skip blank line
            eof <- hIsEOF h
            if eof
                then return fileDeps
                else do
                    firstLine <- hGetLine h
                    case (stripPrefix "//GHCJS Haskell Module " firstLine) of
                        (Just s) -> do
                            case readOne s of
                                Nothing -> return fileDeps
                                Just (mod, toSearch) -> do
                                    functionDeps <- loop h []
                                    return fileDeps{
                                        modules   = S.singleton $ mkModuleName mod,
                                        toSearch  = map (moduleName.makeModule) $
                                                    filter (\m -> not (":" `isPrefixOf` snd m)) toSearch,
                                        functionDeps}
                        _ -> return fileDeps
    hClose h
    return deps
  where
    loop h x = do
        eof <- hIsEOF h
        if eof
            then return x
            else do
                line <- hGetLine h
                case line of
                    '/':'/':s -> loop h (readDep s x)
                    _         -> return x
    readDep s x = case reads s of
                    (((a, b), ""):_) -> ((file, 100), a, b):x -- TODO work out real size
                    _                -> x
    readOne s = case reads s of
                    ((x, ""):_) -> Just x
                    _           -> Nothing

makeModule :: (String, String) -> Module
makeModule (pkgid, modulename) = mkModule (stringToPackageId pkgid) (mkModuleName modulename)

copyScript :: (String -> Bool) -> Handle -> (FilePath, [String]) -> IO ()
copyScript _ _ (_, []) = return ()
copyScript _ _ ("", _) = return ()
copyScript pageSymbolSet out (file, symbols) = do
    file <- openFile file ReadMode
    contents <- copyContents out False file
    hClose file
  where
    copyContents out includeFunction file = do
        eof <- hIsEOF file
        unless eof $ do
            line <- hGetLine file
            case (includeFunction, line) of
                (_, ('v':'a':'r':' ':'$':'$':_)) -> do
                    case span (\c -> isAlphaNum c || c == '$' || c == '_') (drop 4 line) of
                        (s, '=':_) | filterBySymb s -> do
                          if pageSymbolSet s
                            then hPutStrLn out $ "var $" ++ drop 4 line
                            else hPutStrLn out line
                          copyContents out True file
                        _                           -> do
                          copyContents out False file
                (True, _) -> do
                  hPutStrLn out line
                  copyContents out True file
                _         -> do
                  copyContents out False file

    symbolSet = S.fromList symbols

    filterBySymb :: String -> Bool
    filterBySymb = flip S.member symbolSet

