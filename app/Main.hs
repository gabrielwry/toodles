{-# LANGUAGE DeriveDataTypeable  #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main where

import qualified Control.Exception               as E
import           Data.Maybe
import qualified Data.Text                       as T
import Data.Monoid
import           Data.Version                    (showVersion)
import           Data.Void
import           Paths_pile                      (version)
import           System.Console.CmdArgs
import           System.IO.HVFS
import qualified          System.IO.Strict as SIO
import           System.Path
import           Text.Megaparsec
import           Text.Megaparsec.Char
import Text.Printf
import qualified Text.Megaparsec.Char.Lexer      as L
import Debug.Trace

import           Lib

data CommentedLine = CommentedLine
  { sourceFile  :: FilePath
  , lineNumber  :: Integer
  , commentText :: T.Text
  } deriving (Show)

data TodoEntry = TodoEntryHead
  { body     :: [T.Text]
  , assignee :: Maybe T.Text
  } | TodoBodyLine T.Text deriving (Show)

isEntryHead (TodoEntryHead _ _) = True
isEntryHead _                   = False

isBodyLine (TodoBodyLine _ ) = True
isBodyLine _                 = False

combineTodo :: TodoEntry -> TodoEntry -> TodoEntry
combineTodo (TodoEntryHead b a) (TodoBodyLine l) = TodoEntryHead (b ++ [l]) a
combineTodo _ _ = error "Can't combine todoEntry of these types"

data SourceFile = SourceFile {
  fullPath    :: FilePath,
  sourceLines :: [T.Text]
                             } deriving (Show)

data PileArgs = PileArgs
  { project_root :: Maybe FilePath
  } deriving (Show, Data, Typeable, Eq)

argParser :: PileArgs
argParser =
  PileArgs
  {project_root = def &= typFile &= help "Root directory of your project"} &=
  summary ("pile " ++ showVersion version) &=
  program "pile" &=
  verbosity &=
  help "Manage TODO's directly from your codebase"

fileTypeToComment :: [(T.Text, T.Text)]
fileTypeToComment =
  [ (".hs", "--")
  , (".js", "//")
  , (".yaml", "#")
  , (".go", "//")
  , (".proto", "//")
  , (".ts", "//")
  , (".py", "#")
  , (".java", "//")
  , (".cpp", "//")
  ]

unkownMarker :: T.Text
unkownMarker = "UNKNOWN-DELIMETER-UNKNOWN-DELIMETER-UNKNOWN-DELIMETER"

getCommentForFileType :: T.Text -> T.Text
getCommentForFileType extension =
  fromMaybe unkownMarker $ lookup adjustedExtension fileTypeToComment where
    adjustedExtension = if T.isPrefixOf "." extension then extension else "." <> extension

type Parser = Parsec Void T.Text

lexeme :: Parser a -> Parser a
lexeme = L.lexeme space

symbol :: T.Text -> Parser T.Text
symbol = L.symbol space

parseComment :: T.Text -> Parser TodoEntry
parseComment extension = do
  _ <- manyTill anyChar (symbol $ getCommentForFileType extension)
  b <- many anyChar
  return . TodoBodyLine $ T.pack b

parseTodoEntryHead :: T.Text -> Parser TodoEntry
parseTodoEntryHead extension = do
  _ <- manyTill anyChar (symbol $ getCommentForFileType extension)
  _ <- symbol "TODO"
  b <- many anyChar
  return $ TodoEntryHead [T.pack b] Nothing

parseTodo :: T.Text -> Parser TodoEntry
parseTodo ext = try (parseTodoEntryHead ext) <|> parseComment ext

-- TODO hi hi hi

-- TODO(avi) here's a todo!
-- this should still be part of the todo
getAllFiles :: FilePath -> IO [SourceFile]
getAllFiles path = E.catch
  (do
    putStrLn path -- a comment!
    files <- recurseDir SystemFS path
    let validFiles = filter fileHasValidExtension files
    -- TODO make sure it's a file first
    mapM (\f -> SourceFile f . (map T.pack . lines) <$> E.catch (SIO.readFile f) (\(e :: E.IOException) -> print e >> return "")) validFiles)
  (\(e :: E.IOException) ->
     putStrLn ("Error reading " ++ path ++ ": " ++ show e) >> return [])

fileHasValidExtension :: FilePath -> Bool
fileHasValidExtension path =
  any (\ext -> ext `T.isSuffixOf` T.pack path) (map fst fileTypeToComment)

getExtension :: FilePath -> T.Text
getExtension path = last $ T.splitOn "." (T.pack path)

runTodoParser :: SourceFile -> [TodoEntry]
runTodoParser (SourceFile path ls) =
  -- FIXME
  let parsedTodoLines = map (parseMaybe . parseTodo $ getExtension path) ls
      groupedTodos = foldl foldFn ([], False) parsedTodoLines in
    fst groupedTodos

foldFn :: ([TodoEntry], Bool) -> Maybe TodoEntry -> ([TodoEntry], Bool)
foldFn (todos :: [TodoEntry], currentlyBuildingTodoLines :: Bool) maybeTodo
  | isNothing maybeTodo = (todos, False)
  | isEntryHead $ fromJust maybeTodo = (todos ++ [fromJust maybeTodo], True)
  | isBodyLine (fromJust maybeTodo) && currentlyBuildingTodoLines =
    (init todos ++ [combineTodo (last todos) (fromJust maybeTodo)], True)
  | otherwise = (todos, False)

prettyFormat :: TodoEntry -> String
prettyFormat (TodoEntryHead l a) =
  printf "Assignee: %s\n%s" (fromMaybe "None" a) (unlines $ map (T.unpack) l)

main :: IO ()
main = do
  userArgs <- cmdArgs argParser
  let directory  = project_root userArgs
  if isJust directory then do
    allFiles <- getAllFiles $ fromJust directory
    let parsedTodos = concatMap runTodoParser allFiles
    mapM_ (putStrLn . prettyFormat) $ take 50 parsedTodos
  else
    putStrLn "no directory supplied"
