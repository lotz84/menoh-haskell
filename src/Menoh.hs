{-# OPTIONS_GHC -Wall #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ScopedTypeVariables #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  Menoh
-- Copyright   :  Copyright (c) 2018 Preferred Networks, Inc.
-- License     :  MIT (see the file LICENSE)
--
-- Maintainer  :  Masahiro Sakai <sakai@preferred.jp>
-- Stability   :  experimental
-- Portability :  non-portable
--
-- Haskell binding for /Menoh/ DNN inference library.
--
-- = Basic usage
--
-- 1. Load computation graph from ONNX file using 'makeModelDataFromONNX'.
--
-- 2. Specify input variable type/dimentions (in particular batch size) and
--    which output variables you want to retrieve. These information is
--    represented as 'VariableProfileTable'.
--    Simple way to construct 'VariableProfileTable' is to use 'makeVariableProfileTable'.
--
-- 3. Optimize 'ModelData' with respect to your 'VariableProfileTable' by using
--    'optimizeModelData'.
--
-- 4. Construct a 'Model' using 'makeModel' or 'makeModelWithConfig'.
--    If you want to use custom buffers instead of internally allocated ones,
--    You need to use more low level 'ModelBuilder'.
--
-- 5. Load input data. This can be done conveniently using 'writeBufferFromVector'
--    or 'writeBufferFromStorableVector'. There are also more low-level API such as
--    'unsafeGetBuffer' and 'withBuffer'.
--
-- 6. Run inference using 'run'.
--
-- 7. Retrieve the result data. This can be done conveniently using 'readBufferToVector'
--    or 'readBufferToStorableVector'.
--
-----------------------------------------------------------------------------
module Menoh
  (
  -- * Basic data types
    Dims
  , DType (..)
  , HasDType (..)
  , Error (..)

  -- * ModelData type
  , ModelData (..)
  , makeModelDataFromONNX
  , optimizeModelData

  -- * Model type
  , Model (..)
  , makeModel
  , makeModelWithConfig
  , run
  , getDType
  , getDims
  , unsafeGetBuffer
  , withBuffer
  , writeBufferFromVector
  , writeBufferFromStorableVector
  , readBufferToVector
  , readBufferToStorableVector

  -- * Misc
  , version
  , bindingVersion

  -- * Low-level API
  -- ** VariableProfileTable
  , VariableProfileTable (..)
  , makeVariableProfileTable
  , vptGetDType
  , vptGetDims

  -- ** Builder for 'VariableProfileTable'
  , VariableProfileTableBuilder (..)
  , makeVariableProfileTableBuilder
  , addInputProfileDims2
  , addInputProfileDims4
  , addOutputProfile
  , buildVariableProfileTable

  -- ** Builder for 'Model'
  , ModelBuilder (..)
  , makeModelBuilder
  , attachExternalBuffer
  , buildModel
  , buildModelWithConfig
  ) where

import Control.Concurrent
import Control.Monad
import Control.Monad.Trans.Control (MonadBaseControl, liftBaseOp)
import Control.Monad.IO.Class
import Control.Exception
import qualified Data.Aeson as J
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.Proxy
import qualified Data.Vector.Storable as VS
import qualified Data.Vector.Storable.Mutable as VSM
import qualified Data.Vector.Generic as VG
import Data.IntMap (IntMap)
import qualified Data.IntMap as IntMap
import Data.Version
import Foreign
import Foreign.C

import qualified Menoh.Base as Base
import qualified Paths_menoh

#include "MachDeps.h"

-- ------------------------------------------------------------------------

-- | Functions in this module can throw this exception type.
data Error
  = ErrorStdError String
  | ErrorUnknownError String
  | ErrorInvalidFilename String
  | ErrorONNXParseError String
  | ErrorInvalidDType String
  | ErrorInvalidAttributeType String
  | ErrorUnsupportedOperatorAttribute String
  | ErrorDimensionMismatch String
  | ErrorVariableNotFound String
  | ErrorIndexOutOfRange String
  | ErrorJSONParseError String
  | ErrorInvalidBackendName String
  | ErrorUnsupportedOperator String
  | ErrorFailedToConfigureOperator String
  | ErrorBackendError String
  | ErrorSameNamedVariableAlreadyExist String
  deriving (Eq, Ord, Show, Read)

instance Exception Error

runMenoh :: IO Base.MenohErrorCode -> IO ()
runMenoh m = runInBoundThread' $ do
  e <- m
  if e == Base.menohErrorCodeSuccess then
    return ()
  else do
    s <- peekCString =<< Base.menoh_get_last_error_message
    case IntMap.lookup (fromIntegral e) table of
      Just ex -> throwIO $ ex s
      Nothing -> throwIO $ ErrorUnknownError $ s ++ "(error code: " ++ show (fromIntegral e :: Int) ++ ")"
  where
    table :: IntMap (String -> Error)
    table = IntMap.fromList $ map (\(k,v) -> (fromIntegral k, v)) $
      [ (Base.menohErrorCodeStdError                      , ErrorStdError)
      , (Base.menohErrorCodeUnknownError                  , ErrorUnknownError)
      , (Base.menohErrorCodeInvalidFilename               , ErrorInvalidFilename)
      , (Base.menohErrorCodeOnnxParseError                , ErrorONNXParseError)
      , (Base.menohErrorCodeInvalidDtype                  , ErrorInvalidDType)
      , (Base.menohErrorCodeInvalidAttributeType          , ErrorInvalidAttributeType)
      , (Base.menohErrorCodeUnsupportedOperatorAttribute  , ErrorUnsupportedOperatorAttribute)
      , (Base.menohErrorCodeDimensionMismatch             , ErrorDimensionMismatch)
      , (Base.menohErrorCodeVariableNotFound              , ErrorVariableNotFound)
      , (Base.menohErrorCodeIndexOutOfRange               , ErrorIndexOutOfRange)
      , (Base.menohErrorCodeJsonParseError                , ErrorJSONParseError)
      , (Base.menohErrorCodeInvalidBackendName            , ErrorInvalidBackendName)
      , (Base.menohErrorCodeUnsupportedOperator           , ErrorUnsupportedOperator)
      , (Base.menohErrorCodeFailedToConfigureOperator     , ErrorFailedToConfigureOperator)
      , (Base.menohErrorCodeBackendError                  , ErrorBackendError)
      , (Base.menohErrorCodeSameNamedVariableAlreadyExist , ErrorSameNamedVariableAlreadyExist)
      ]

runInBoundThread' :: IO a -> IO a
runInBoundThread' action
  | rtsSupportsBoundThreads = runInBoundThread action
  | otherwise = action

-- ------------------------------------------------------------------------

-- | Data type of array elements
data DType
  = DTypeFloat                    -- ^ single precision floating point number
  | DTypeUnknown !Base.MenohDType -- ^ types that this binding is unware of
  deriving (Eq, Ord, Show, Read)

instance Enum DType where
  toEnum x
    | x == fromIntegral Base.menohDtypeFloat = DTypeFloat
    | otherwise = DTypeUnknown (fromIntegral x)

  fromEnum DTypeFloat = fromIntegral Base.menohDtypeFloat
  fromEnum (DTypeUnknown i) = fromIntegral i

-- | Haskell types that have associated 'DType' type code.
class Storable a => HasDType a where
  dtypeOf :: Proxy a -> DType

instance HasDType CFloat where
  dtypeOf _ = DTypeFloat

#if SIZEOF_HSFLOAT == SIZEOF_FLOAT

instance HasDType Float where
  dtypeOf _ = DTypeFloat

#endif

-- ------------------------------------------------------------------------

-- | Dimensions of array
type Dims = [Int]

-- ------------------------------------------------------------------------

-- | @ModelData@ contains model parameters and computation graph structure.
newtype ModelData = ModelData (ForeignPtr Base.MenohModelData)

-- | Load onnx file and make 'ModelData'.
makeModelDataFromONNX :: MonadIO m => FilePath -> m ModelData
makeModelDataFromONNX fpath = liftIO $ withCString fpath $ \fpath' -> alloca $ \ret -> do
  runMenoh $ Base.menoh_make_model_data_from_onnx fpath' ret
  liftM ModelData $ newForeignPtr Base.menoh_delete_model_data_funptr =<< peek ret

-- | Optimize function for 'ModelData'.
--
-- This function modify given 'ModelData'.
optimizeModelData :: MonadIO m => ModelData -> VariableProfileTable -> m ()
optimizeModelData (ModelData m) (VariableProfileTable vpt) = liftIO $
  withForeignPtr m $ \m' -> withForeignPtr vpt $ \vpt' ->
    runMenoh $ Base.menoh_model_data_optimize m' vpt'

-- ------------------------------------------------------------------------

-- | Builder for creation of 'VariableProfileTable'.
newtype VariableProfileTableBuilder
  = VariableProfileTableBuilder (ForeignPtr Base.MenohVariableProfileTableBuilder)

-- | Factory function for 'VariableProfileTableBuilder'.
makeVariableProfileTableBuilder :: MonadIO m => m VariableProfileTableBuilder
makeVariableProfileTableBuilder = liftIO $ alloca $ \p -> do
  runMenoh $ Base.menoh_make_variable_profile_table_builder p
  liftM VariableProfileTableBuilder $ newForeignPtr Base.menoh_delete_variable_profile_table_builder_funptr =<< peek p

addInputProfileDims :: MonadIO m => VariableProfileTableBuilder -> String -> DType -> Dims -> m ()
addInputProfileDims vpt name dtype dims =
  case dims of
    [num, size] -> addInputProfileDims2 vpt name dtype (num, size)
    [num, channel, height, width] -> addInputProfileDims4 vpt name dtype (num, channel, height, width)
    _ -> liftIO $ throwIO $ ErrorDimensionMismatch $ "Menoh.addInputProfileDims: cannot handle dims of length " ++ show (length dims)

-- | Add 2D input profile.
--
-- Input profile contains name, dtype and dims @(num, size)@.
-- This 2D input is conventional batched 1D inputs.
addInputProfileDims2
  :: MonadIO m
  => VariableProfileTableBuilder
  -> String
  -> DType
  -> (Int, Int) -- ^ (num, size)
  -> m ()
addInputProfileDims2 (VariableProfileTableBuilder vpt) name dtype (num, size) = liftIO $
  withForeignPtr vpt $ \vpt' -> withCString name $ \name' ->
    runMenoh $ Base.menoh_variable_profile_table_builder_add_input_profile_dims_2
      vpt' name' (fromIntegral (fromEnum dtype))
      (fromIntegral num) (fromIntegral size)

-- | Add 4D input profile
--
-- Input profile contains name, dtype and dims @(num, channel, height, width)@.
-- This 4D input is conventional batched image inputs. Image input is
-- 3D (channel, height, width).
addInputProfileDims4
  :: MonadIO m
  => VariableProfileTableBuilder
  -> String
  -> DType
  -> (Int, Int, Int, Int) -- ^ (num, channel, height, width)
  -> m ()
addInputProfileDims4 (VariableProfileTableBuilder vpt) name dtype (num, channel, height, width) = liftIO $
  withForeignPtr vpt $ \vpt' -> withCString name $ \name' ->
    runMenoh $ Base.menoh_variable_profile_table_builder_add_input_profile_dims_4
      vpt' name' (fromIntegral (fromEnum dtype))
      (fromIntegral num) (fromIntegral channel) (fromIntegral height) (fromIntegral width)

-- | Add output profile
--
-- Output profile contains name and dtype. Its 'Dims' are calculated automatically,
-- so that you don't need to specify explicitly.
addOutputProfile :: MonadIO m => VariableProfileTableBuilder -> String -> DType -> m ()
addOutputProfile (VariableProfileTableBuilder vpt) name dtype = liftIO $
  withForeignPtr vpt $ \vpt' -> withCString name $ \name' ->
    runMenoh $ Base.menoh_variable_profile_table_builder_add_output_profile
      vpt' name' (fromIntegral (fromEnum dtype))

-- | Factory function for 'VariableProfileTable'
buildVariableProfileTable
  :: MonadIO m
  => VariableProfileTableBuilder
  -> ModelData
  -> m VariableProfileTable
buildVariableProfileTable (VariableProfileTableBuilder b) (ModelData m) = liftIO $
  withForeignPtr b $ \b' -> withForeignPtr m $ \m' -> alloca $ \ret -> do
    runMenoh $ Base.menoh_build_variable_profile_table b' m' ret
    liftM VariableProfileTable $ newForeignPtr Base.menoh_delete_variable_profile_table_funptr =<< peek ret

-- ------------------------------------------------------------------------

-- | @VariableProfileTable@ contains information of dtype and dims of variables.
--
-- Users can access to dtype and dims via 'vptGetDType' and 'vptGetDims'.
newtype VariableProfileTable
  = VariableProfileTable (ForeignPtr Base.MenohVariableProfileTable)

-- | Convenient function for constructing 'VariableProfileTable'.
--
-- If you need finer control, you can use 'VariableProfileTableBuidler'.
makeVariableProfileTable
  :: MonadIO m
  => [(String, DType, Dims)]  -- ^ input names with dtypes and dims
  -> [(String, DType)]        -- ^ required output name list with dtypes
  -> ModelData                -- ^ model data
  -> m VariableProfileTable
makeVariableProfileTable input_name_and_dims_pair_list required_output_name_list model_data = liftIO $ do
  b <- makeVariableProfileTableBuilder
  forM_ input_name_and_dims_pair_list $ \(name,dtype,dims) -> do
    addInputProfileDims b name dtype dims
  forM_ required_output_name_list $ \(name,dtype) -> do
    addOutputProfile b name dtype
  buildVariableProfileTable b model_data

-- | Accessor function for 'VariableProfileTable'
--
-- Select variable name and get its 'DType'.
vptGetDType :: MonadIO m => VariableProfileTable -> String -> m DType
vptGetDType (VariableProfileTable vpt) name = liftIO $
  withForeignPtr vpt $ \vpt' -> withCString name $ \name' -> alloca $ \ret -> do
    runMenoh $ Base.menoh_variable_profile_table_get_dims_size vpt' name' ret
    (toEnum . fromIntegral) <$> peek ret

-- | Accessor function for 'VariableProfileTable'
--
-- Select variable name and get its 'Dims'.
vptGetDims :: MonadIO m => VariableProfileTable -> String -> m Dims
vptGetDims (VariableProfileTable vpt) name = liftIO $
  withForeignPtr vpt $ \vpt' -> withCString name $ \name' -> alloca $ \ret -> do
    runMenoh $ Base.menoh_variable_profile_table_get_dims_size vpt' name' ret
    size <- peek ret
    forM [0..size-1] $ \i -> do
      runMenoh $ Base.menoh_variable_profile_table_get_dims_at vpt' name' (fromIntegral i) ret
      fromIntegral <$> peek ret

-- ------------------------------------------------------------------------

-- | Helper for creating of 'Model'.
newtype ModelBuilder = ModelBuilder (ForeignPtr Base.MenohModelBuilder)

-- | Factory function for 'ModelBuilder'
makeModelBuilder :: MonadIO m => VariableProfileTable -> m ModelBuilder
makeModelBuilder (VariableProfileTable vpt) = liftIO $
  withForeignPtr vpt $ \vpt' -> alloca $ \ret -> do
    runMenoh $ Base.menoh_make_model_builder vpt' ret
    liftM ModelBuilder $ newForeignPtr Base.menoh_delete_model_builder_funptr =<< peek ret

-- | Attach a buffer which allocated by users.
--
-- Users can attach a external buffer which they allocated to target variable.
--
-- Variables attached no external buffer are attached internal buffers allocated
-- automatically.
--
-- Users can get that internal buffer handle by calling 'unsafeGetBuffer' etc. later.
attachExternalBuffer :: MonadIO m => ModelBuilder -> String -> Ptr a -> m ()
attachExternalBuffer (ModelBuilder m) name buf = liftIO $
  withForeignPtr m $ \m' -> withCString name $ \name' ->
    runMenoh $ Base.menoh_model_builder_attach_external_buffer m' name' buf

-- | Factory function for 'Model'.
buildModel
  :: MonadIO m
  => ModelBuilder
  -> ModelData
  -> String  -- ^ backend name
  -> m Model
buildModel builder m backend = liftIO $
  withCString "" $
    buildModelWithConfigString builder m backend

-- | Similar to 'buildModel', but backend specific configuration can be supplied as JSON.
buildModelWithConfig
  :: (MonadIO m, J.ToJSON a)
  => ModelBuilder
  -> ModelData
  -> String  -- ^ backend name
  -> a       -- ^ backend config
  -> m Model
buildModelWithConfig builder m backend backend_config = liftIO $
  BS.useAsCString (BL.toStrict (J.encode backend_config)) $
    buildModelWithConfigString builder m backend

buildModelWithConfigString
  :: MonadIO m
  => ModelBuilder
  -> ModelData
  -> String  -- ^ backend name
  -> CString -- ^ backend config
  -> m Model
buildModelWithConfigString (ModelBuilder builder) (ModelData m) backend backend_config = liftIO $
  withForeignPtr builder $ \builder' -> withForeignPtr m $ \m' -> withCString backend $ \backend' -> alloca $ \ret -> do
    runMenoh $ Base.menoh_build_model builder' m' backend' backend_config ret
    liftM Model $ newForeignPtr Base.menoh_delete_model_funptr =<< peek ret

-- ------------------------------------------------------------------------

-- | ONNX model with input/output buffers
newtype Model = Model (ForeignPtr Base.MenohModel)

-- | Run model inference.
--
-- This function can't be called asynchronously.
run :: MonadIO m => Model -> m ()
run (Model model) = liftIO $ withForeignPtr model $ \model' -> do
  runMenoh $ Base.menoh_model_run model'

-- | Get 'DType' of target variable.
getDType :: MonadIO m => Model -> String -> m DType
getDType (Model m) name = liftIO $ do
  withForeignPtr m $ \m' -> withCString name $ \name' -> alloca $ \ret -> do
    runMenoh $ Base.menoh_model_get_variable_dtype m' name' ret
    liftM (toEnum . fromIntegral) $ peek ret

-- | Get 'Dims' of target variable.
getDims :: MonadIO m => Model -> String -> m Dims
getDims (Model m) name = liftIO $ do
  withForeignPtr m $ \m' -> withCString name $ \name' -> alloca $ \ret -> do
    runMenoh $ Base.menoh_model_get_variable_dims_size m' name' ret
    size <- peek ret
    forM [0..size-1] $ \i -> do
      runMenoh $ Base.menoh_model_get_variable_dims_at m' name' (fromIntegral i) ret
      fromIntegral <$> peek ret

-- | Get a buffer handle attached to target variable.
--
-- Users can get a buffer handle attached to target variable.
-- If that buffer is allocated by users and attached to the variable by calling
-- 'attachExternalBuffer', returned buffer handle is same to it.
--
-- This function is unsafe because it does not prevent the model to be GC'ed and
-- the returned pointer become dangling pointer.
--
-- See also 'withBuffer'.
unsafeGetBuffer :: MonadIO m => Model -> String -> m (Ptr a)
unsafeGetBuffer (Model m) name = liftIO $ do
  withForeignPtr m $ \m' -> withCString name $ \name' -> alloca $ \ret -> do
    runMenoh $ Base.menoh_model_get_variable_buffer_handle m' name' ret
    peek ret

-- | This function takes a function which is applied to the buffer associated to specified variable.
-- The resulting action is then executed. The buffer is kept alive at least during the whole action,
-- even if it is not used directly inside.
-- Note that it is not safe to return the pointer from the action and use it after the action completes.
--
-- See also 'unsafeGetBuffer'.
withBuffer :: forall m r a. (MonadIO m, MonadBaseControl IO m) => Model -> String -> (Ptr a -> m r) -> m r
withBuffer (Model m) name f =
  liftBaseOp (withForeignPtr m) $ \m' ->
  (liftBaseOp (withCString name) ::  (CString -> m r) -> m r) $ \name' ->
  liftBaseOp alloca $ \ret -> do
    p <- liftIO $ do
      runMenoh $ Base.menoh_model_get_variable_buffer_handle m' name' ret
      peek ret
    f p

checkDType :: String -> DType -> DType -> IO ()
checkDType name dtype1 dtype2
  | dtype1 /= dtype2 = throwIO $ ErrorInvalidDType $ name ++ ": dtype mismatch"
  | otherwise        = return ()

checkDTypeAndSize :: String -> (DType,Int) -> (DType,Int) -> IO ()
checkDTypeAndSize name (dtype1,n1) (dtype2,n2)
  | dtype1 /= dtype2 = throwIO $ ErrorInvalidDType $ name ++ ": dtype mismatch"
  | n1 /= n2         = throwIO $ ErrorDimensionMismatch $ name ++ ": dimension mismatch"
  | otherwise        = return ()

-- | Copy whole elements of 'VG.Vector' into a model's buffer
writeBufferFromVector :: forall v a m. (VG.Vector v a, HasDType a, MonadIO m) => Model -> String -> v a -> m ()
writeBufferFromVector model name vec = liftIO $ withBuffer model name $ \p -> do
  dtype <- getDType model name
  dims <- getDims model name
  let n = product dims
  checkDTypeAndSize "Menoh.writeBufferFromVector" (dtype, n) (dtypeOf (Proxy :: Proxy a), VG.length vec)
  forM_ [0..n-1] $ \i -> do
    pokeElemOff p i (vec VG.! i)

-- | Copy whole elements of @'VS.Vector' a@ into a model's buffer
writeBufferFromStorableVector :: forall a m. (HasDType a, MonadIO m) => Model -> String -> VS.Vector a -> m ()
writeBufferFromStorableVector model name vec = liftIO $ withBuffer model name $ \p -> do
  dtype <- getDType model name
  dims <- getDims model name
  let n = product dims
  checkDTypeAndSize "Menoh.writeBufferFromStorableVector" (dtype, n) (dtypeOf (Proxy :: Proxy a), VG.length vec)
  VS.unsafeWith vec $ \src -> do
    copyArray p src n

-- | Read whole elements of 'Array' and return as a 'VG.Vector'.
readBufferToVector :: forall v a m. (VG.Vector v a, HasDType a, MonadIO m) => Model -> String -> m (v a)
readBufferToVector model name = liftIO $ withBuffer model name $ \p -> do
  dtype <- getDType model name
  dims <- getDims model name
  checkDType "Menoh.readBufferToVector" dtype (dtypeOf (Proxy :: Proxy a))
  let n = product dims
  VG.generateM n $ peekElemOff p

-- | Read whole eleemnts of 'Array' and return as a @'VS.Vector' 'Float'@.
readBufferToStorableVector :: forall a m. (HasDType a, MonadIO m) => Model -> String -> m (VS.Vector a)
readBufferToStorableVector model name = liftIO $ withBuffer model name $ \p -> do
  dtype <- getDType model name
  dims <- getDims model name
  checkDType "Menoh.readBufferToStorableVector" dtype (dtypeOf (Proxy :: Proxy a))
  let n = product dims
  vec <- VSM.new n
  VSM.unsafeWith vec $ \dst -> copyArray dst p n
  VS.unsafeFreeze vec

-- | Convenient methods for constructing  a 'Model'.
makeModel
  :: MonadIO m
  => VariableProfileTable    -- ^ variable profile table
  -> ModelData               -- ^ model data
  -> String                  -- ^ backend name
  -> m Model
makeModel vpt model_data backend_name = liftIO $ do
  b <- makeModelBuilder vpt
  buildModel b model_data backend_name

-- | Similar to 'makeModel' but backend-specific configuration can be supplied.
makeModelWithConfig
  :: (MonadIO m, J.ToJSON a)
  => VariableProfileTable    -- ^ variable profile table
  -> ModelData               -- ^ model data
  -> String                  -- ^ backend name
  -> a                       -- ^ backend config
  -> m Model
makeModelWithConfig vpt model_data backend_name backend_config = liftIO $ do
  b <- makeModelBuilder vpt
  buildModelWithConfig b model_data backend_name backend_config

-- ------------------------------------------------------------------------

-- | Menoh version which was supplied on compilation time via CPP macro.
version :: Version
version = makeVersion [Base.menoh_major_version, Base.menoh_minor_version, Base.menoh_patch_version]

-- | Version of this Haskell binding. (Not the version of /Menoh/ itself)
bindingVersion :: Version
bindingVersion = Paths_menoh.version
