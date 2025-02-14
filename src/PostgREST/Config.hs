{-|
Module      : PostgREST.Config
Description : Manages PostgREST configuration options.

This module provides a helper function to read the command line
arguments using the optparse-applicative and the AppConfig type to store
them.  It also can be used to define other middleware configuration that
may be delegated to some sort of external configuration.

It currently includes a hardcoded CORS policy but this could easly be
turned in configurable behaviour if needed.

Other hardcoded options such as the minimum version number also belong here.
-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell     #-}
{-# OPTIONS_GHC -fno-warn-type-defaults #-}

module PostgREST.Config ( prettyVersion
                        , docsVersion
                        , readOptions
                        , corsPolicy
                        , AppConfig (..)
                        , configPoolTimeout'
                        )
       where

import qualified Data.ByteString              as B
import qualified Data.ByteString.Char8        as BS
import qualified Data.CaseInsensitive         as CI
import qualified Data.Configurator            as C
import qualified Text.PrettyPrint.ANSI.Leijen as L

import Control.Exception           (Handler (..))
import Control.Lens                (preview)
import Control.Monad               (fail)
import Crypto.JWT                  (StringOrURI, stringOrUri)
import Data.List                   (lookup)
import Data.Scientific             (floatingOrInteger)
import Data.Text                   (dropEnd, dropWhileEnd,
                                    intercalate, lines, splitOn,
                                    strip, take, unpack)
import Data.Text.Encoding          (encodeUtf8)
import Data.Text.IO                (hPutStrLn)
import Data.Version                (versionBranch)
import Development.GitRev          (gitHash)
import Network.Wai.Middleware.Cors (CorsResourcePolicy (..))
import Paths_postgrest             (version)
import System.IO.Error             (IOError)

import Control.Applicative
import Data.Monoid
import Network.Wai
import Options.Applicative          hiding (str)
import Text.Heredoc
import Text.PrettyPrint.ANSI.Leijen hiding ((<$>), (<>))

import PostgREST.Error   (ApiRequestError (..))
import PostgREST.Parsers (pRoleClaimKey)
import PostgREST.Types   (JSPath, JSPathExp (..),
                          QualifiedIdentifier (..))
import Protolude         hiding (concat, hPutStrLn, intercalate, null,
                          take, (<>))


-- | Config file settings for the server
data AppConfig = AppConfig {
    configDatabase          :: Text
  , configAnonRole          :: Text
  , configProxyUri          :: Maybe Text
  , configSchema            :: Text
  , configHost              :: Text
  , configPort              :: Int
  , configSocket            :: Maybe Text

  , configJwtSecret         :: Maybe B.ByteString
  , configJwtSecretIsBase64 :: Bool
  , configJwtAudience       :: Maybe StringOrURI

  , configPool              :: Int
  , configPoolTimeout       :: Int
  , configMaxRows           :: Maybe Integer
  , configReqCheck          :: Maybe Text
  , configQuiet             :: Bool
  , configSettings          :: [(Text, Text)]
  , configRoleClaimKey      :: Either ApiRequestError JSPath
  , configExtraSearchPath   :: [Text]

  , configRootSpec          :: Maybe QualifiedIdentifier
  , configRawMediaTypes     :: [B.ByteString]
  }

configPoolTimeout' :: (Fractional a) => AppConfig -> a
configPoolTimeout' =
  fromRational . toRational . configPoolTimeout


defaultCorsPolicy :: CorsResourcePolicy
defaultCorsPolicy =  CorsResourcePolicy Nothing
  ["GET", "POST", "PATCH", "PUT", "DELETE", "OPTIONS"] ["Authorization"] Nothing
  (Just $ 60*60*24) False False True

-- | CORS policy to be used in by Wai Cors middleware
corsPolicy :: Request -> Maybe CorsResourcePolicy
corsPolicy req = case lookup "origin" headers of
  Just origin -> Just defaultCorsPolicy {
      corsOrigins = Just ([origin], True)
    , corsRequestHeaders = "Authentication":accHeaders
    , corsExposedHeaders = Just [
        "Content-Encoding", "Content-Location", "Content-Range", "Content-Type"
      , "Date", "Location", "Server", "Transfer-Encoding", "Range-Unit"
      ]
    }
  Nothing -> Nothing
  where
    headers = requestHeaders req
    accHeaders = case lookup "access-control-request-headers" headers of
      Just hdrs -> map (CI.mk . toS . strip . toS) $ BS.split ',' hdrs
      Nothing -> []

-- | User friendly version number
prettyVersion :: Text
prettyVersion =
  intercalate "." (map show $ versionBranch version)
  <> " (" <> take 7 $(gitHash) <> ")"

-- | Version number used in docs
docsVersion :: Text
docsVersion = "v" <> dropEnd 1 (dropWhileEnd (/= '.') prettyVersion)

-- | Function to read and parse options from the command line
readOptions :: IO AppConfig
readOptions = do
  -- First read the config file path from command line
  cfgPath <- customExecParser parserPrefs opts
  -- Now read the actual config file
  conf <- catches (C.load cfgPath)
    [ Handler (\(ex :: IOError)    -> exitErr $ "Cannot open config file:\n\t" <> show ex)
    , Handler (\(C.ParseError err) -> exitErr $ "Error parsing config file:\n\t" <> err)
    ]

  case C.runParser parseConfig conf of
    Left err ->
      exitErr $ "Error parsing config file:\n\t" <> err
    Right appConf ->
      return appConf

  where
    dbSchema = reqString "db-schema"
    parseConfig =
      AppConfig
        <$> reqString "db-uri"
        <*> reqString "db-anon-role"
        <*> optString "server-proxy-uri"
        <*> dbSchema
        <*> (fromMaybe "!4" <$> optString "server-host")
        <*> (fromMaybe 3000 <$> optInt "server-port")
        <*> optString "server-unix-socket"
        <*> (fmap encodeUtf8 <$> optString "jwt-secret")
        <*> (fromMaybe False <$> optBool "secret-is-base64")
        <*> parseJwtAudience "jwt-aud"
        <*> (fromMaybe 10 <$> optInt "db-pool")
        <*> (fromMaybe 10 <$> optInt "db-pool-timeout")
        <*> optInt "max-rows"
        <*> optString "pre-request"
        <*> pure False
        <*> (fmap (fmap coerceText) <$> C.subassocs "app.settings" C.value)
        <*> (maybe (Right [JSPKey "role"]) parseRoleClaimKey <$> optValue "role-claim-key")
        <*> (maybe ["public"] splitOnCommas <$> optValue "db-extra-search-path")
        <*> ((\x y -> QualifiedIdentifier x <$> y) <$> dbSchema <*> optString "root-spec")
        <*> (maybe [] (fmap encodeUtf8 . splitOnCommas) <$> optValue "raw-media-types")

    parseJwtAudience :: C.Key -> C.Parser C.Config (Maybe StringOrURI)
    parseJwtAudience k =
      C.optional k C.string >>= \case
        Nothing -> pure Nothing -- no audience in config file
        Just aud -> case preview stringOrUri (unpack aud) of
          Nothing -> fail "Invalid Jwt audience. Check your configuration."
          (Just "") -> pure Nothing
          aud' -> pure aud'

    reqString :: C.Key -> C.Parser C.Config Text
    reqString k = C.required k C.string

    optString :: C.Key -> C.Parser C.Config (Maybe Text)
    optString k = mfilter (/= "") <$> C.optional k C.string

    optValue :: C.Key -> C.Parser C.Config (Maybe C.Value)
    optValue k = C.optional k C.value

    optInt :: (Read i, Integral i) => C.Key -> C.Parser C.Config (Maybe i)
    optInt k = join <$> C.optional k (coerceInt <$> C.value)

    optBool :: C.Key -> C.Parser C.Config (Maybe Bool)
    optBool k = join <$> C.optional k (coerceBool <$> C.value)

    coerceText :: C.Value -> Text
    coerceText (C.String s) = s
    coerceText v            = show v

    coerceInt :: (Read i, Integral i) => C.Value -> Maybe i
    coerceInt (C.Number x) = rightToMaybe $ floatingOrInteger x
    coerceInt (C.String x) = readMaybe $ toS x
    coerceInt _            = Nothing

    coerceBool :: C.Value -> Maybe Bool
    coerceBool (C.Bool b)   = Just b
    coerceBool (C.String b) = readMaybe $ toS b
    coerceBool _            = Nothing

    parseRoleClaimKey :: C.Value -> Either ApiRequestError JSPath
    parseRoleClaimKey (C.String s) = pRoleClaimKey s
    parseRoleClaimKey v            = pRoleClaimKey $ show v

    splitOnCommas :: C.Value -> [Text]
    splitOnCommas (C.String s) = strip <$> splitOn "," s
    splitOnCommas _            = []

    opts = info (helper <*> pathParser) $
             fullDesc
             <> progDesc (
                 "PostgREST "
                 <> toS prettyVersion
                 <> " / create a REST API to an existing Postgres database"
               )
             <> footerDoc (Just $
                 text "Example Config File:"
                 L.<> nest 2 (hardline L.<> exampleCfg)
               )

    parserPrefs = prefs showHelpOnError

    exitErr :: Text -> IO a
    exitErr err = do
      hPutStrLn stderr err
      exitFailure

    exampleCfg :: Doc
    exampleCfg = vsep . map (text . toS) . lines $
      [str|db-uri = "postgres://user:pass@localhost:5432/dbname"
          |db-schema = "public" # this schema gets added to the search_path of every request
          |db-anon-role = "postgres"
          |db-pool = 10
          |db-pool-timeout = 10
          |
          |server-host = "!4"
          |server-port = 3000
          |
          |## unix socket location
          |## if specified it takes precedence over server-port
          |# server-unix-socket = "/tmp/pgrst.sock"
          |
          |## base url for swagger output
          |# server-proxy-uri = ""
          |
          |## choose a secret, JSON Web Key (or set) to enable JWT auth
          |## (use "@filename" to load from separate file)
          |# jwt-secret = "foo"
          |# secret-is-base64 = false
          |# jwt-aud = "your_audience_claim"
          |
          |## limit rows in response
          |# max-rows = 1000
          |
          |## stored proc to exec immediately after auth
          |# pre-request = "stored_proc_name"
          |
          |## jspath to the role claim key
          |# role-claim-key = ".role"
          |
          |## extra schemas to add to the search_path of every request
          |# db-extra-search-path = "extensions, util"
          |
          |## stored proc that overrides the root "/" spec
          |## it must be inside the db-schema
          |# root-spec = "stored_proc_name"
          |
          |## content types to produce raw output
          |# raw-media-types="image/png, image/jpg"
          |]

pathParser :: Parser FilePath
pathParser =
  strArgument $
    metavar "FILENAME" <>
    help "Path to configuration file"
