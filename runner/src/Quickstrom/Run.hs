{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE Strict #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Quickstrom.Run
  ( WebDriver (..),
    WebDriverResponseError (..),
    WebDriverOtherError (..),
    CheckEnv (..),
    CheckOptions (..),
    CheckResult (..),
    PassedTest (..),
    FailedTest (..),
    Size (..),
    Timeout (..),
    CheckEvent (..),
    TestEvent (..),
    check,
  )
where

import Control.Lens hiding (each)
import Control.Monad (fail, filterM, forever, when, (>=>))
import Control.Monad.Catch (MonadCatch, MonadThrow, catch)
import Control.Monad.IO.Class (MonadIO (liftIO))
import Control.Monad.Loops (andM)
import Control.Monad.Trans.Class (MonadTrans (lift))
import Control.Natural (type (~>))
import qualified Data.Aeson as JSON
import Data.Function ((&))
import Data.Generics.Product (field)
import Data.List hiding (map)
import Data.Maybe (catMaybes)
import Data.String (String, fromString)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Text.Prettyprint.Doc
import Data.Tree
import Data.Vector (Vector)
import qualified Data.Vector as Vector
import GHC.Generics (Generic)
import Pipes (Pipe, Producer, (>->))
import qualified Pipes
import qualified Pipes.Prelude as Pipes
import Quickstrom.Action
import Quickstrom.Element
import Quickstrom.Prelude hiding (catch, check, trace)
import Quickstrom.Result
import Quickstrom.Specification
import Quickstrom.Trace
import Quickstrom.WebDriver.Class
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import qualified Test.QuickCheck as QuickCheck
import Text.URI (URI)
import qualified Text.URI as URI

newtype Runner m a = Runner (ReaderT CheckEnv m a)
  deriving (Functor, Applicative, Monad, MonadIO, WebDriver, MonadReader CheckEnv, MonadThrow, MonadCatch)

run :: CheckEnv -> Runner m a -> m a
run env (Runner ma) = runReaderT ma env

data PassedTest = PassedTest
  { trace :: Trace TraceElementEffect
  }
  deriving (Show, Generic)

data FailedTest = FailedTest
  { numShrinks :: Int,
    trace :: Trace TraceElementEffect,
    reason :: Maybe Text
  }
  deriving (Show, Generic)

data CheckResult
  = CheckSuccess {passedTests :: Vector PassedTest}
  | CheckFailure {failedAfter :: Int, passedTests :: Vector PassedTest, failedTest :: FailedTest}
  | CheckError {checkError :: Text}
  deriving (Show, Generic)

data TestEvent
  = TestStarted Size
  | TestPassed Size (Trace TraceElementEffect)
  | TestFailed Size (Trace TraceElementEffect)
  | Shrinking Int
  | RunningShrink Int
  deriving (Show, Generic)

data CheckEvent
  = CheckStarted Int
  | CheckTestEvent TestEvent
  | CheckFinished CheckResult
  deriving (Show, Generic)

data CheckEnv = CheckEnv {checkOptions :: CheckOptions, checkScripts :: CheckScripts}

data CheckOptions = CheckOptions
  { checkTests :: Int,
    checkMaxActions :: Size,
    checkShrinkLevels :: Int,
    checkOrigin :: URI,
    checkMaxTrailingStateChanges :: Int,
    checkTrailingStateChangeTimeout :: Timeout,
    checkWebDriverOptions :: WebDriverOptions,
    checkCaptureScreenshots :: Bool
  }

newtype Size = Size {unSize :: Word32}
  deriving (Eq, Show, Generic, JSON.FromJSON, JSON.ToJSON)

newtype Timeout = Timeout Word64
  deriving (Eq, Show, Generic, JSON.FromJSON, JSON.ToJSON)

mapTimeout :: (Word64 -> Word64) -> Timeout -> Timeout
mapTimeout f (Timeout ms) = Timeout (f ms)

data CheckScript a = CheckScript {runCheckScript :: forall m. WebDriver m => m a}

data CheckScripts = CheckScripts
  { isElementVisible :: Element -> CheckScript Bool,
    observeState :: Queries -> CheckScript ObservedElementStates,
    registerNextStateObserver :: Timeout -> Queries -> CheckScript (),
    awaitNextState :: CheckScript ()
  }

check ::
  (Specification spec, MonadIO n, MonadCatch n, WebDriver m, MonadIO m) =>
  CheckOptions ->
  (m ~> n) ->
  spec ->
  Pipes.Producer CheckEvent n CheckResult
check opts@CheckOptions {checkTests} runWebDriver spec = do
  -- stdGen <- getStdGen
  Pipes.yield (CheckStarted checkTests)
  env <- CheckEnv opts <$> lift readScripts
  res <-
    Pipes.hoist (runWebDriver . run env) (runAll opts spec)
      & (`catch` \err@SomeException {} -> pure (CheckError (show err)))
  Pipes.yield (CheckFinished res)
  pure res

elementsToTrace :: Monad m => Producer (TraceElement ()) (Runner m) () -> Runner m (Trace ())
elementsToTrace = fmap Trace . Pipes.toListM

minBy :: (Monad m, Ord b) => (a -> b) -> Producer a m () -> m (Maybe a)
minBy f = Pipes.fold step Nothing identity
  where
    step x a = Just $ case x of
      Nothing -> a
      Just a' ->
        case f a `compare` f a' of
          EQ -> a
          LT -> a
          GT -> a'

select :: Monad m => (a -> Maybe b) -> Pipe a b m ()
select f = forever do
  x <- Pipes.await
  maybe (pure ()) Pipes.yield (f x)

runSingle ::
  (MonadIO m, WebDriver m, Specification spec) =>
  spec ->
  Size ->
  Producer TestEvent (Runner m) (Either FailedTest PassedTest)
runSingle spec size = do
  Pipes.yield (TestStarted size)
  result <-
    generateValidActions (actions spec)
      >-> Pipes.take (fromIntegral (unSize size))
      & runAndVerifyIsolated 0
  case result of
    Right trace -> do
      Pipes.yield (TestPassed size trace)
      pure (Right (PassedTest trace))
    Left ft@(FailedTest _ trace _) -> do
      CheckOptions {checkShrinkLevels} <- lift (asks checkOptions)
      Pipes.yield (TestFailed size trace)
      if checkShrinkLevels > 0
        then do
          Pipes.yield (Shrinking checkShrinkLevels)
          let shrinks = shrinkForest shrinkList' checkShrinkLevels (trace ^.. traceActions)
          shrunk <-
            minBy
              (lengthOf (field @"trace" . traceElements))
              ( traverseShrinks runShrink shrinks
                  >-> select (preview _Left)
                  >-> Pipes.take 5
              )
          pure (maybe (Left ft) Left shrunk)
        else pure (Left ft)
  where
    runAndVerifyIsolated ::
      (MonadIO m, WebDriver m) =>
      Int ->
      Producer (ActionSequence Selected) (Runner m) () ->
      Producer TestEvent (Runner m) (Either FailedTest (Trace TraceElementEffect))
    runAndVerifyIsolated n producer = do
      trace <- lift do
        opts <- asks checkOptions
        annotateStutteringSteps <$> inNewPrivateWindow (checkWebDriverOptions opts) do
          beforeRun spec
          elementsToTrace (producer >-> runActions' spec)
      case verify spec (trace ^.. nonStutterStates) of
        Right Accepted -> pure (Right trace)
        Right Rejected -> pure (Left (FailedTest n trace Nothing))
        Left err -> pure (Left (FailedTest n trace (Just err)))
    runShrink (Shrink n actions') = do
      Pipes.yield (RunningShrink n)
      runAndVerifyIsolated n (Pipes.each actions')

runAll :: (MonadIO m, WebDriver m, Specification spec) => CheckOptions -> spec -> Producer CheckEvent (Runner m) CheckResult
runAll opts spec' = go mempty (sizes opts `zip` [1 ..])
  where
    go :: (MonadIO m, WebDriver m) => Vector PassedTest -> [(Size, Int)] -> Producer CheckEvent (Runner m) CheckResult
    go passed [] = pure (CheckSuccess passed)
    go passed ((size, n) : rest) =
      (runSingle spec' size >-> Pipes.map CheckTestEvent)
        >>= \case
          Right passedTest -> go (passed <> pure passedTest) rest
          Left failingTest -> pure (CheckFailure n passed failingTest)

sizes :: CheckOptions -> [Size]
sizes CheckOptions {checkMaxActions = Size maxActions, checkTests} =
  map (\n -> Size (n * maxActions `div` fromIntegral checkTests)) [1 .. fromIntegral checkTests]

defaultAwaitSecs :: Int
defaultAwaitSecs = 10

beforeRun :: (MonadIO m, WebDriver m, Specification spec) => spec -> Runner m ()
beforeRun spec = do
  navigateToOrigin
  do
    res <- awaitElement defaultAwaitSecs (readyWhen spec)
    case res of
      ActionFailed s -> fail $ Text.unpack s
      _ -> pass

takeWhileChanging :: Functor m => (a -> a -> Bool) -> Pipe a a m ()
takeWhileChanging compare' = Pipes.await >>= loop
  where
    loop prev = do
      Pipes.yield prev
      next <- Pipes.await
      if next `compare'` prev then pass else loop next

observeManyStatesAfter :: (MonadIO m, WebDriver m) => Queries -> ActionSequence Selected -> Pipe a (TraceElement ()) (Runner m) ()
observeManyStatesAfter queries' actionSequence = do
  CheckEnv {checkScripts = scripts, checkOptions = CheckOptions {checkMaxTrailingStateChanges, checkTrailingStateChangeTimeout, checkCaptureScreenshots}} <- lift ask
  lift (runCheckScript (registerNextStateObserver scripts checkTrailingStateChangeTimeout queries'))
  result <- lift (runActionSequence actionSequence)
  lift (runCheckScript (awaitNextState scripts) `catchResponseError` const pass)
  newState <- lift (runCheckScript (observeState scripts queries'))
  screenshot <- if checkCaptureScreenshots then Just <$> lift takeScreenshot else pure Nothing
  Pipes.yield (TraceAction () actionSequence result)
  Pipes.yield (TraceState () (ObservedState screenshot newState))
  nonStutters <-
    ( loop checkCaptureScreenshots checkTrailingStateChangeTimeout
        >-> takeWhileChanging (\a b -> elementStates a == elementStates b)
        >-> Pipes.take checkMaxTrailingStateChanges
      )
      & Pipes.toListM
      & lift
  mapM_ (Pipes.yield . TraceState ()) nonStutters
  where
    loop :: WebDriver m => Bool -> Timeout -> Producer ObservedState (Runner m) ()
    loop checkCaptureScreenshots timeout = do
      scripts <- lift (asks checkScripts)
      newState <- lift do
        runCheckScript (registerNextStateObserver scripts timeout queries')
        runCheckScript (awaitNextState scripts) `catchResponseError` const pass
        runCheckScript (observeState scripts queries')
      screenshot <- if checkCaptureScreenshots then Just <$> lift takeScreenshot else pure Nothing
      Pipes.yield (ObservedState screenshot newState)
      loop checkCaptureScreenshots (mapTimeout (* 2) timeout)

{-# SCC runActions' "runActions'" #-}
runActions' :: (MonadIO m, WebDriver m, Specification spec) => spec -> Pipe (ActionSequence Selected) (TraceElement ()) (Runner m) ()
runActions' spec = do
  scripts <- lift (asks checkScripts)
  state1 <- lift (runCheckScript (observeState scripts queries'))
  screenshot <- pure <$> lift takeScreenshot
  Pipes.yield (TraceState () (ObservedState screenshot state1))
  loop
  where
    queries' = queries spec
    loop = do
      actionSequence <- Pipes.await
      observeManyStatesAfter queries' actionSequence
      loop

data Shrink a = Shrink Int a

shrinkForest :: (a -> [a]) -> Int -> a -> Forest (Shrink a)
shrinkForest shrink limit = go 1
  where
    go n
      | n <= limit = map (\x -> Node (Shrink n x) (go (succ n) x)) . shrink
      | otherwise = mempty

traverseShrinks :: Monad m => (Shrink a -> m (Either e b)) -> Forest (Shrink a) -> Producer (Either e b) m ()
traverseShrinks test = go
  where
    go = \case
      [] -> pure ()
      Node x xs : rest -> do
        r <- lift (test x)
        Pipes.yield r
        when (isn't _Right r) do
          go xs
        go rest

shrinkList' :: [a] -> [[a]]
shrinkList' = concatMap shrinkInits . shrinkTails
  where
    shrinkInits = takeWhile (not . null) . iterate init
    shrinkTails = takeWhile (not . null) . iterate tail

shrinkList'' = QuickCheck.shrinkList shrinkAction

shrinkAction :: ActionSequence Selected -> [ActionSequence Selected]
shrinkAction _ = [] -- TODO?

generate :: MonadIO m => QuickCheck.Gen a -> m a
generate = liftIO . QuickCheck.generate

generateValidActions :: (MonadIO m, WebDriver m) => Vector (Int, ActionSequence Selector) -> Producer (ActionSequence Selected) (Runner m) ()
generateValidActions possibleActions = loop
  where
    loop = do
      validActions <- lift $ for (Vector.toList possibleActions) \(prob, action') -> do
        fmap (prob,) <$> selectValidActionSeq action'
      case map (_2 %~ pure) (catMaybes validActions) of
        [] -> pass
        actions' -> do
          actions'
            & QuickCheck.frequency
            & generate
            & lift
            & (>>= Pipes.yield)
          loop

selectValidActionSeq :: (MonadIO m, WebDriver m) => ActionSequence Selector -> Runner m (Maybe (ActionSequence Selected))
selectValidActionSeq (Single action) = map Single <$> selectValidAction False action
selectValidActionSeq (Sequence (a :| as)) =
  selectValidAction False a >>= \case
    Just firstAction -> do
      restActions <- traverse (selectValidAction True) as
      pure (Just (Sequence (firstAction :| catMaybes restActions)))
    Nothing -> pure Nothing

selectValidAction ::
  (MonadIO m, WebDriver m) => Bool -> Action Selector -> Runner m (Maybe (Action Selected))
selectValidAction skipValidation possibleAction =
  case possibleAction of
    KeyPress k -> do
      active <- isActiveInput
      if skipValidation || active then pure (Just (KeyPress k)) else pure Nothing
    EnterText t -> do
      active <- isActiveInput
      if skipValidation || active then pure (Just (EnterText t)) else pure Nothing
    Navigate p -> pure (Just (Navigate p))
    Await sel -> pure (Just (Await sel))
    AwaitWithTimeoutSecs i sel -> pure (Just (AwaitWithTimeoutSecs i sel))
    Focus sel -> selectOne sel Focus (if skipValidation then alwaysTrue else isNotActive)
    Click sel -> selectOne sel Click (if skipValidation then alwaysTrue else isClickable)
    Clear sel -> selectOne sel Clear (if skipValidation then alwaysTrue else isClearable)
    Refresh  -> pure (Just Refresh)
  where
    selectOne ::
      (MonadIO m, WebDriver m) =>
      Selector ->
      (Selected -> Action Selected) ->
      (Element -> (Runner m) Bool) ->
      Runner m (Maybe (Action Selected))
    selectOne sel ctor isValid = do
      found <- findAll sel
      validChoices <-
        filterM
            (\(_, e) -> isValid e `catchResponseError` const (pure False))
            (zip [0 ..] found)
      case validChoices of
        [] -> pure Nothing
        choices -> Just <$> generate (ctor . Selected sel <$> QuickCheck.elements (map fst choices))
    isNotActive e = (/= Just e) <$> activeElement
    activeElement = (Just <$> getActiveElement) `catchResponseError` const (pure Nothing)
    alwaysTrue = const (pure True)
    isClickable e = do
      scripts <- asks checkScripts
      andM [isElementEnabled e, runCheckScript (isElementVisible scripts e)]
    isClearable el = (`elem` ["input", "textarea"]) <$> getElementTagName el
    isActiveInput =
      activeElement >>= \case
        Just el -> (`elem` ["input", "textarea"]) <$> getElementTagName el
        Nothing -> pure False

navigateToOrigin :: WebDriver m => Runner m ()
navigateToOrigin = do
  CheckOptions {checkOrigin} <- asks checkOptions
  navigateTo (URI.render checkOrigin)

tryAction :: WebDriver m => Runner m ActionResult -> Runner m ActionResult
tryAction action =
  action
    `catchResponseError` (\(WebDriverResponseError msg) -> pure (ActionFailed msg))

click :: WebDriver m => Selected -> Runner m ActionResult
click =
  findSelected >=> \case
    Just e -> tryAction (ActionSuccess <$ elementClick e)
    Nothing -> pure ActionImpossible

clear :: WebDriver m => Selected -> Runner m ActionResult
clear =
  findSelected >=> \case
    Just e -> tryAction (ActionSuccess <$ elementClear e)
    Nothing -> pure ActionImpossible

sendKeys :: WebDriver m => Text -> Runner m ActionResult
sendKeys t = tryAction (ActionSuccess <$ (getActiveElement >>= elementSendKeys t))

sendKey :: WebDriver m => Char -> Runner m ActionResult
sendKey = sendKeys . Text.singleton

focus :: WebDriver m => Selected -> Runner m ActionResult
focus =
  findSelected >=> \case
    Just e -> tryAction (ActionSuccess <$ elementSendKeys "" e)
    Nothing -> pure ActionImpossible

runAction :: (MonadIO m, WebDriver m) => Action Selected -> Runner m ActionResult
runAction = \case
  Focus s -> focus s
  KeyPress c -> sendKey c
  EnterText t -> sendKeys t
  Click s -> click s
  Clear s -> clear s
  Await s -> awaitElement defaultAwaitSecs s
  AwaitWithTimeoutSecs i s -> awaitElement i s
  Navigate uri -> tryAction (ActionSuccess <$ navigateTo uri)
  Refresh  -> tryAction (ActionSuccess <$ pageRefresh)

runActionSequence :: (MonadIO m, WebDriver m) => ActionSequence Selected -> Runner m ActionResult
runActionSequence = \case
  Single h -> runAction h
  Sequence actions' ->
    let loop [] = pure ActionSuccess
        loop (x : xs) =
          runAction x >>= \case
            ActionSuccess -> loop xs
            err -> pure err
     in loop (toList actions')

findSelected :: WebDriver m => Selected -> Runner m (Maybe Element)
findSelected (Selected s i) =
  findAll s >>= \es -> pure (es ^? ix i)

awaitElement :: (MonadIO m, WebDriver m) => Int -> Selector -> Runner m ActionResult
awaitElement secondsTimeout sel@(Selector s) =
  let loop n
        | n > secondsTimeout =
          pure $ ActionFailed ("Giving up after having waited " <> show secondsTimeout <> " seconds for selector to match an element: " <> toS s)
        | otherwise =
          findAll sel >>= \case
            [] -> liftIO (threadDelay 1000000) >> loop (n + 1)
            _ -> pure ActionSuccess
   in loop (1 :: Int)

readScripts :: MonadIO m => m CheckScripts
readScripts = do
  let key = "QUICKSTROM_CLIENT_SIDE_DIR"
  dir <- liftIO (maybe (fail (key <> " environment variable not set")) pure =<< lookupEnv key)
  let readScript :: MonadIO m => String -> m Text
      readScript name = liftIO (fromString . toS <$> readFile (dir </> name <> ".js"))
  isElementVisibleScript <- readScript "isElementVisible"
  observeStateScript <- readScript "observeState"
  registerNextStateObserverScript <- readScript "registerNextStateObserver"
  awaitNextStateScript <- readScript "awaitNextState"
  pure
    CheckScripts
      { isElementVisible = \el -> CheckScript ((== JSON.Bool True) <$> runScript isElementVisibleScript [JSON.toJSON el]),
        observeState = \queries' -> CheckScript (runScript observeStateScript [JSON.toJSON queries']),
        registerNextStateObserver = \timeout queries' -> CheckScript (runScript registerNextStateObserverScript [JSON.toJSON timeout, JSON.toJSON queries']),
        awaitNextState = CheckScript (runScript awaitNextStateScript [])
      }
