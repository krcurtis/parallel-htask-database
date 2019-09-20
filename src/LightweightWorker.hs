-- Copyright 2019 Fred Hutchinson Cancer Research Center
--------------------------------------------------------------------------------
-- 

{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}



module LightweightWorker where


import System.Environment (getEnv)
import System.Posix.Files

import Data.Aeson
import Data.Aeson.TH


import qualified Data.ByteString.Lazy.Char8 as BL
import qualified Data.Text as T
import Database.MongoDB hiding (host)
import Control.Monad.Trans (liftIO)
import Control.Monad (when)

--import qualified Network.Socket as N
--import Network.Socket (PortNumber(..))   -- Module `Network.Socket' does not export `PortNumber'
--import Network.Socket.Types -- Could not load module `Network.Socket.Types' it is a hidden module in the package `network-2.8.0.1'
import qualified Network as N  -- 2.8.0.1 complains that Network is deprecated, but importing Network.Socket and PortNumber does not compile


import System.Environment

import qualified System.Process as P
import System.Exit (ExitCode(..))
import System.IO

-- to get current time
import Data.Time.Calendar
import Data.Time.Clock

import Control.Exception

import Data.Bson (merge)
import System.Environment (lookupEnv)
import System.Random

import Control.Concurrent (threadDelay)
import Data.UUID.V4
import Data.UUID


--------------------------------------------------------------------------------



data InfoMongoServer = InfoMongoServer
     { host :: String
     , user :: String
     , password :: String
     , port :: Int -- cannot get this to work as Network.PortNumber
     } deriving (Show, Eq)

$(deriveJSON defaultOptions ''InfoMongoServer)

--------------------------------------------------------------------------------

read_mongo_server_info :: IO InfoMongoServer
read_mongo_server_info = do
    home_dir <- getEnv "HOME"
    let database_access_file = home_dir ++ "/.mongo_database"
    access_mode <- fileMode `fmap` getFileStatus database_access_file
    let has_group_other_access = nullFileMode /= intersectFileModes (groupModes `unionFileModes` otherModes) access_mode
    if has_group_other_access then
        error "ERROR database access file has permissions for group or other"
    else do
        json_text <- readFile database_access_file
        let json_results = decode (BL.pack json_text) :: Maybe InfoMongoServer
        case json_results of
            Just server_info -> return server_info
            _ -> error "ERROR could not understand contents of database access file"



-- connect to MongoDB and authenticate, essentially assume it all works, maybe switch to exceptions later?
get_mongo_pipe :: InfoMongoServer -> IO Pipe
get_mongo_pipe server_info = do
    pipe <- connect (Host (host server_info) (N.PortNumber (read (show (port server_info)) :: N.PortNumber))) -- fromIntegral?
    let u = (T.pack (user server_info))
    let p = (T.pack (password server_info))
    access pipe master (T.pack "admin") (auth u p)
    return pipe






-- may need to change this to whatever text type that Aeson returns by default for JSON strings

-- raise an exception or what??
invoke_system :: [T.Text] -> Maybe T.Text -> IO Bool
invoke_system [] _ = return True
invoke_system (cmd:params) log_file = do
    --readProcessWithExitCode can generate confusing exceptions if the program cmd does not exist
    result <- try (P.readProcessWithExitCode (T.unpack cmd) (map T.unpack params) "") :: IO (Either SomeException (ExitCode, String, String))

    case result of
      Left _ -> do
        let msg = "ERROR could not invoke " ++ (T.unpack cmd) ++ " " ++ (show params)
        putStrLn msg
        case log_file of
          Nothing -> return False
          Just filename -> do
            handle <- openFile (T.unpack filename) AppendMode
            hPutStrLn handle msg
            hPutStrLn handle ("cmd: " ++ show cmd ++ show params)
            hClose handle
            return False
        
      Right (exitcode, out_msg, err_msg) -> do
        putStrLn ("stdout:" ++ out_msg)
        putStrLn ("stderr:" ++ err_msg)
        case log_file of
          Nothing -> handle_exit exitcode out_msg err_msg
          Just filename -> do
            handle <- openFile (T.unpack filename) AppendMode
            hPutStrLn handle ("cmd: " ++ show cmd ++ show params)
            hPutStrLn handle ("stdout: " ++ out_msg)
            hPutStrLn handle ("stderr: " ++ err_msg)
            hClose handle
            handle_exit exitcode out_msg err_msg
  where
    handle_exit :: ExitCode -> String -> String -> IO Bool
    handle_exit exitcode output_message error_message =
        case exitcode of
          ExitSuccess -> return True
          ExitFailure ecode -> do
            let msg = "ERROR: failed (returns" ++ show ecode ++ ") " ++ (T.unpack cmd) ++ " " ++
                           show params ++ "\n" ++ error_message ++ "\n" ++ output_message
            putStrLn msg
            return False





-- given a connection, download job parameter info
get_job_parameters :: Pipe -> T.Text -> IO (Maybe Document)
get_job_parameters pipe database = do
    result <- access pipe master database (findOne (select [ "processing" =: False ] "tasks"))
    when (Nothing == result) $ putStrLn "Found no potentials tasks in database"
    return result



set_processing :: Document -> IO Document
set_processing job = do
    now <- getCurrentTime
    uuid <- fmap toString nextRandom
    env_info <-  lookupEnv "SLURM_JOBID"
    task_info <- lookupEnv "SLURM_ARRAY_TASK_ID"
    let jobid = case (env_info, task_info) of
                  (Nothing, _) -> "not running as a slurm_job"
                  (Just job_label, Nothing) -> job_label
                  (Just job_label, Just task_label) -> job_label ++ "_" ++ task_label
        job' = merge [ "processing" =: True, "start" =: now, "jobid" =: jobid, "uuid" =: uuid] job
        
    return job'


set_not_processing :: Document -> Bool -> IO Document
set_not_processing job success = do
    now <- getCurrentTime
    let job' = merge [ "success" =: success, "stop" =: now] job
    return job'
  


atomic_update_of_job :: Pipe -> T.Text -> Document -> IO Bool
atomic_update_of_job pipe database job = do
        let Just mongoid = look "_id" job
        access pipe master database (replace (select [ "_id" =: mongoid, "processing" =: False ] "tasks") job)
        --sadly that doesn't seem to tell us if it actually changed the database, so use a hack to see if updated
        --job actually made it into the database
        Just in_database <- access pipe master database (findOne (select [ "_id" =: mongoid  ] "tasks"))
        let Just original_uuid = look "uuid" job
        let Just replaced_uuid = look "uuid" job
        let Just original_jobid = look "jobid" job
        let Just replaced_jobid= look "jobid" job
        --putStrLn (show job)
        --putStrLn (show in_database)

        --Also, the utc time formatting is not preserved by going to and
        --back from the MongoDB for some reason, so cannot use that to
        --check
        
        return ([original_uuid, original_jobid] == [replaced_uuid, replaced_jobid])

        -- print('Found task', update)
        --print('replace collision, matched={matched_count} modified={modified_count}'.format(matched_count=result.matched_count, modified_count=result.modified_count))



get_random_seed :: IO Integer
get_random_seed = fmap ( (\x -> div x 1000) . diffTimeToPicoseconds . utctDayTime) getCurrentTime

get_random_d10 :: StdGen -> (Int, StdGen)
get_random_d10 gen = (1 + mod mynumber 10, gen')
  where
    (mynumber, gen') = random gen -- :: (Int, StdGen)



-- wrapper over the download that handles the random time delays between requests
download_job_parameters :: InfoMongoServer -> T.Text -> IO (Maybe Document)
download_job_parameters info database = do
    seed <- get_random_seed
    let gen = mkStdGen (fromIntegral seed)

    retry_job_download gen
  where
    retry_job_download :: StdGen -> IO (Maybe Document)
    retry_job_download gen = do
        let (delay, gen') = get_random_d10 gen
        threadDelay (delay * 1000000)
        putStrLn "Connecting..."
        pipe <- get_mongo_pipe info
        potential_task <- get_job_parameters pipe database
        close pipe
        case potential_task of
          Nothing -> return Nothing
          Just job -> do
            revised <- set_processing job
            pipe' <- get_mongo_pipe info
            result <- atomic_update_of_job pipe' database revised
            close pipe'
            case result of
              True -> return (Just revised)
              False -> do
                putStrLn "Looping in check loop"
                retry_job_download gen'



close_job_parameters :: InfoMongoServer -> T.Text -> Document -> Bool -> IO Bool
close_job_parameters info database job success = do
    job' <- set_not_processing job success

    pipe <- get_mongo_pipe info
    let Just mongoid = look "_id" job'
    access pipe master database (replace (select [ "_id" =: mongoid, "processing" =: True ] "tasks") job')
    -- hack to see if job was updated, assume stop time was not in original
    Just in_database <- access pipe master database (findOne (select [ "_id" =: mongoid  ] "tasks"))
    close pipe
    
    let result = case (look "stop" in_database, look "success" in_database) of
                 (Just _, Just _) -> True
                 _ -> False
    if result
      then putStrLn "Successfully updated database"
      else putStrLn ("Error in database update: " ++ (show job'))
    return result



main_loop :: (Document -> IO Bool) -> T.Text -> IO ()
main_loop app_func database = do
    info <- read_mongo_server_info
    putStrLn "Starting main loop"
    job_candidate <- download_job_parameters info database

    case job_candidate of
      Nothing -> putStrLn "No job found"
      Just job -> do
        result <- try (app_func job) :: IO (Either SomeException Bool)
        case result of
          Left e -> do
            putStrLn "ERROR exception!!"
            putStrLn (show e)
            close_job_parameters info database job False
            return ()
          Right result' -> do
            close_job_parameters info database job result'
            when result' $ putStrLn ("DONE[" ++ show job ++ "]")

    

{-
view_random_job :: Pipe -> T.Text -> IO ()
view_random_job pipe database = undefined
    ... access pipe master "stats_tasks" (findOne (select [] "tasks"))

-}
