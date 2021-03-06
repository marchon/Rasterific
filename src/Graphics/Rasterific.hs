{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE ConstraintKinds #-}
-- | Main module of Rasterific, an Haskell rasterization engine.
--
-- Creating an image is rather simple, here is a simple example
-- of a drawing and saving it in a PNG file:
--
-- > import Codec.Picture( PixelRGBA8( .. ), writePng )
-- > import Graphics.Rasterific
-- > import Graphics.Rasterific.Texture
-- >
-- > main :: IO ()
-- > main = do
-- >   let white = PixelRGBA8 255 255 255 255
-- >       drawColor = PixelRGBA8 0 0x86 0xc1 255
-- >       recColor = PixelRGBA8 0xFF 0x53 0x73 255
-- >       img = renderDrawing 400 200 white $
-- >          withTexture (uniformTexture drawColor) $ do
-- >             fill $ circle (V2 0 0) 30
-- >             stroke 4 JoinRound (CapRound, CapRound) $
-- >                    circle (V2 400 200) 40
-- >             withTexture (uniformTexture recColor) .
-- >                    fill $ rectangle (V2 100 100) 200 100
-- >
-- >   writePng "yourimage.png" img
--
-- <<docimages/module_example.png>>
--
-- The coordinate system is the picture classic one, with the origin in
-- the upper left corner; with the y axis growing to the bottom and the
-- x axis growing to the right:
--
-- <<docimages/coordinate.png>>
--
module Graphics.Rasterific
    (
      -- * Rasterization command
      fill
    , fillWithMethod
    , withTexture
    , withClipping
    , withTransformation
    , withPathOrientation
    , stroke
    , dashedStroke
    , dashedStrokeWithOffset
    , printTextAt
    , printTextRanges
    , TextRange( .. )

      -- * Generating images
    , ModulablePixel
    , RenderablePixel
    , renderDrawing
    , pathToPrimitives

      -- * Rasterization types
    , Texture
    , Drawing
    , Modulable

      -- * Geometry description
    , V2( .. )
    , Point
    , Vector
    , CubicBezier( .. )
    , Line( .. )
    , Bezier( .. )
    , Primitive( .. )
    , Path( .. )
    , PathCommand( .. )
    , Transformable( .. )
    , PointFoldable( .. )
    , PlaneBoundable( .. )
    , PlaneBound( .. )
    , boundWidth
    , boundHeight
    , boundLowerLeftCorner

      -- * Helpers
    , line
    , rectangle
    , roundedRectangle
    , circle
    , ellipse
    , polyline
    , polygon
    , drawImageAtSize
    , drawImage

      -- ** Geometry Helpers
    , clip
    , bezierFromPath
    , lineFromPath
    , cubicBezierFromPath

      -- * Rasterization control
    , Join( .. )
    , Cap( .. )
    , SamplerRepeat( .. )
    , FillMethod( .. )
    , DashPattern
    , drawOrdersOfDrawing

      -- * Debugging helper
    , dumpDrawing

    ) where

import Control.Applicative( (<$>) )
import Control.Monad.Free( Free( .. ), liftF )
import Control.Monad.Free.Church( fromF )
import Control.Monad.ST( runST )
import Control.Monad.State( modify, execState )
import Data.Maybe( fromMaybe )
import Data.Monoid( Monoid( .. ), (<>) )
import Codec.Picture.Types( Image( .. ), Pixel( .. ) )

import qualified Data.Vector.Unboxed as VU
import Graphics.Rasterific.Compositor
import Graphics.Rasterific.Linear( V2( .. ), (^+^), (^-^), (^*) )
import Graphics.Rasterific.Rasterize
import Graphics.Rasterific.Texture
import Graphics.Rasterific.Shading
import Graphics.Rasterific.Types
import Graphics.Rasterific.Line
import Graphics.Rasterific.QuadraticBezier
import Graphics.Rasterific.CubicBezier
import Graphics.Rasterific.StrokeInternal
import Graphics.Rasterific.Transformations
import Graphics.Rasterific.PlaneBoundable
import Graphics.Rasterific.Immediate
import Graphics.Rasterific.PathWalker
import Graphics.Rasterific.Command
{-import Graphics.Rasterific.TensorPatch-}

import Graphics.Text.TrueType( Font, getStringCurveAtPoint )

{-import Debug.Trace-}
{-import Text.Printf-}

------------------------------------------------
----    Free Monad DSL section
------------------------------------------------

-- | Define the texture applyied to all the children
-- draw call.
--
-- > withTexture (uniformTexture $ PixelRGBA8 0 0x86 0xc1 255) $ do
-- >     fill $ circle (V2 50 50) 20
-- >     fill $ circle (V2 100 100) 20
-- >     withTexture (uniformTexture $ PixelRGBA8 0xFF 0x53 0x73 255)
-- >          $ circle (V2 150 150) 20
--
-- <<docimages/with_texture.png>>
--
withTexture :: Texture px -> Drawing px () -> Drawing px ()
withTexture texture subActions =
    liftF $ SetTexture texture subActions ()

-- | Draw all the sub drawing commands using a transformation.
withTransformation :: Transformation -> Drawing px () -> Drawing px ()
withTransformation trans sub =
    liftF $ WithTransform trans sub ()

-- | This command allows you to draw primitives on a given curve,
-- for example, you can draw text on a curve:
--
-- > let path = Path (V2 100 180) False
-- >                 [PathCubicBezierCurveTo (V2 20 20) (V2 170 20) (V2 300 200)] in
-- > stroke 3 JoinRound (CapStraight 0, CapStraight 0) $
-- >     pathToPrimitives path
-- > withTexture (uniformTexture $ PixelRGBA8 0 0 0 255) $
-- >   withPathOrientation path 0 $
-- >     printTextAt font 24 (V2 0 0) "Text on path"
--
-- <<docimages/text_on_path.png>>
--
-- You can note that the position of the baseline match the size of the
-- characters.
--
-- You are not limited to text drawing while using this function,
-- you can draw arbitrary geometry like in the following example:
--
-- > let path = Path (V2 100 180) False
-- >                 [PathCubicBezierCurveTo (V2 20 20) (V2 170 20) (V2 300 200)]
-- > withTexture (uniformTexture $ PixelRGBA8 0 0 0 255) $
-- >   stroke 3 JoinRound (CapStraight 0, CapStraight 0) $
-- >       pathToPrimitives path
-- > 
-- > withPathOrientation path 0 $ do
-- >   printTextAt font 24 (V2 0 0) "TX"
-- >   fill $ rectangle (V2 (-10) (-10)) 30 20
-- >   fill $ rectangle (V2 45 0) 10 20
-- >   fill $ rectangle (V2 60 (-10)) 20 20
-- >   fill $ rectangle (V2 100 (-15)) 20 50
--
-- <<docimages/geometry_on_path.png>>
--
withPathOrientation :: Path            -- ^ Path directing the orientation.
                    -> Float           -- ^ Basline Y axis position, used to align text properly.
                    -> Drawing px ()   -- ^ The sub drawings.
                    -> Drawing px ()
withPathOrientation path p sub =
    liftF $ WithPathOrientation path p sub ()

-- | Fill some geometry. The geometry should be "looping",
-- ie. the last point of the last primitive should
-- be equal to the first point of the first primitive.
--
-- The primitive should be connected.
--
-- > fill $ circle (V2 100 100) 75
--
-- <<docimages/fill_circle.png>>
--
fill :: [Primitive] -> Drawing px ()
fill prims = liftF $ Fill FillWinding prims ()

-- | This function let you choose how to fill the primitives
-- in case of self intersection. See `FillMethod` documentation
-- for more information.
fillWithMethod :: FillMethod -> [Primitive] -> Drawing px ()
fillWithMethod method prims =
    liftF $ Fill method prims ()

-- | Draw some geometry using a clipping path.
--
-- > withClipping (fill $ circle (V2 100 100) 75) $
-- >     mapM_ (stroke 7 JoinRound (CapRound, CapRound))
-- >       [line (V2 0 yf) (V2 200 (yf + 10))
-- >                      | y <- [5 :: Int, 17 .. 200]
-- >                      , let yf = fromIntegral y ]
--
-- <<docimages/with_clipping.png>>
--
withClipping
    :: (forall innerPixel. Drawing innerPixel ()) -- ^ The clipping path
    -> Drawing px () -- ^ The actual geometry to clip
    -> Drawing px ()
withClipping clipPath drawing =
    liftF $ WithCliping clipPath drawing ()

-- | Will stroke geometry with a given stroke width.
-- The elements should be connected
--
-- > stroke 5 JoinRound (CapRound, CapRound) $ circle (V2 100 100) 75
--
-- <<docimages/stroke_circle.png>>
--
stroke :: Float       -- ^ Stroke width
       -> Join        -- ^ Which kind of join will be used
       -> (Cap, Cap)  -- ^ Start and end capping.
       -> [Primitive] -- ^ List of elements to render
       -> Drawing px ()
stroke width join caping prims =
    liftF $ Stroke width join caping prims ()

-- | Draw a string at a given position.
-- Text printing imply loading a font, there is no default
-- font (yet). Below an example of font rendering using a
-- font installed on Microsoft Windows.
--
-- > import Graphics.Text.TrueType( loadFontFile )
-- > import Codec.Picture( PixelRGBA8( .. ), writePng )
-- > import Graphics.Rasterific
-- > import Graphics.Rasterific.Texture
-- >
-- > main :: IO ()
-- > main = do
-- >   fontErr <- loadFontFile "C:/Windows/Fonts/arial.ttf"
-- >   case fontErr of
-- >     Left err -> putStrLn err
-- >     Right font ->
-- >       writePng "text_example.png" .
-- >           renderDrawing 300 70 (PixelRGBA8 255 255 255 255)
-- >               . withTexture (uniformTexture $ PixelRGBA8 0 0 0 255) $
-- >                       printTextAt font 12 (V2 20 40)
-- >                            "A simple text test!"
--
-- <<docimages/text_example.png>>
--
-- You can use any texture, like a gradient while rendering text.
--
printTextAt :: Font            -- ^ Drawing font
            -> Int             -- ^ font Point size
            -> Point           -- ^ Drawing starting point (base line)
            -> String          -- ^ String to print
            -> Drawing px ()
printTextAt font pointSize point string =
    liftF $ TextFill point [description] ()
  where
    description = TextRange
        { _textFont    = font
        , _textSize    = pointSize
        , _text        = string
        , _textTexture = Nothing
        }

-- | Print complex text, using different texture font and
-- point size for different parts of the text.
--
-- <<docimages/text_complex_example.png>>
--
printTextRanges :: Point            -- ^ Starting point of the base line
                -> [TextRange px]   -- ^ Ranges description to be printed
                -> Drawing px ()
printTextRanges point ranges = liftF $ TextFill point ranges ()

data RenderContext px = RenderContext
    { currentClip           :: Maybe (Texture (PixelBaseComponent px))
    , currentTexture        :: Texture px
    , currentTransformation :: Maybe (Transformation, Transformation)
    }

-- | Function to call in order to start the image creation.
-- Tested pixels type are PixelRGBA8 and Pixel8, pixel types
-- in other colorspace will probably produce weird results.
renderDrawing
    :: forall px . (RenderablePixel px)
    => Int -- ^ Rendering width
    -> Int -- ^ Rendering height
    -> px  -- ^ Background color
    -> Drawing px () -- ^ Rendering action
    -> Image px
renderDrawing width height background drawing =
    runST $ runDrawContext width height background
          $ mapM_ fillOrder
          $ drawOrdersOfDrawing width height background drawing

-- | Transform a drawing into a serie of low-level drawing orders.
drawOrdersOfDrawing
    :: forall px . (RenderablePixel px) 
    => Int -- ^ Rendering width
    -> Int -- ^ Rendering height
    -> px  -- ^ Background color
    -> Drawing px () -- ^ Rendering action
    -> [DrawOrder px]
drawOrdersOfDrawing width height background drawing =
    go initialContext (fromF drawing) []
  where
    initialContext = RenderContext Nothing stupidDefaultTexture Nothing
    clipBackground = emptyValue :: PixelBaseComponent px
    clipForeground = fullValue :: PixelBaseComponent px

    clipRender =
      renderDrawing width height clipBackground
            . withTexture (uniformTexture clipForeground)

    textureOf ctxt@RenderContext { currentTransformation = Just (_, t) } =
        transformTexture t $ currentTexture ctxt
    textureOf ctxt = currentTexture ctxt

    geometryOf RenderContext { currentTransformation = Just (trans, _) } =
        transform (applyTransformation trans)
    geometryOf _ = id

    stupidDefaultTexture =
        uniformTexture $ colorMap (const clipBackground) background

    go :: RenderContext px -> Free (DrawCommand px) () -> [DrawOrder px]
       -> [DrawOrder px]
    go _ (Pure ()) rest = rest
    go ctxt (Free (WithPathOrientation path base sub next)) rest = final where
      final = orders <> go ctxt next rest
      images = go ctxt (fromF sub) []

      drawer trans _ order = modify $ \lst -> finalOrder : lst
        where
          toFinalPos = transform $ applyTransformation trans
          finalOrder =
            order { _orderPrimitives = toFinalPos $ _orderPrimitives order }
      orders = reverse $ execState (drawOrdersOnPath drawer 0 base path images) []

    go ctxt (Free (WithTransform trans sub next)) rest = final where
      trans'
        | Just (t, _) <- currentTransformation ctxt = t <> trans
        | otherwise = trans
      invTrans = fromMaybe mempty $ inverseTransformation trans'
      after = go ctxt next rest
      subContext =
          ctxt { currentTransformation = Just (trans', invTrans) }

      final = go subContext (fromF sub) after

    go ctxt (Free (Fill method prims next)) rest = order : after where
      after = go ctxt next rest
      order = DrawOrder 
            { _orderPrimitives = [geometryOf ctxt prims]
            , _orderTexture    = textureOf ctxt
            , _orderFillMethod = method
            , _orderMask       = currentClip ctxt
            }

    go ctxt (Free (Stroke w j cap prims next)) rest =
        go ctxt (Free $ Fill FillWinding prim' next) rest
            where prim' = listOfContainer $ strokize w j cap prims

    go ctxt (Free (SetTexture tx sub next)) rest =
        go (ctxt { currentTexture = tx }) (fromF sub) $ go ctxt next rest

    go ctxt (Free (DashedStroke o d w j cap prims next)) rest =
        foldr recurse after $ dashedStrokize o d w j cap prims
      where
        after = go ctxt next rest
        recurse sub =
            go ctxt (liftF $ Fill FillWinding sub ())

    go ctxt (Free (TextFill (V2 x y) descriptions next)) rest =
        go ctxt (sequence_ drawCalls) $ go ctxt next rest
      where
        floatCurves =
          getStringCurveAtPoint 90 (x, y)
            [(_textFont d, _textSize d, _text d) | d <- descriptions]

        linearDescriptions =
            concat [map (const d) $ _text d | d <- descriptions]

        drawCalls =
            [texturize d $ beziersOfChar curve
                | (curve, d) <- zip floatCurves linearDescriptions]

        texturize descr sub = case _textTexture descr of
            Nothing -> fromF sub
            Just t -> liftF $ SetTexture t sub ()

        beziersOfChar curves = liftF $ Fill FillWinding bezierCurves ()
          where
            bezierCurves = concat
              [map BezierPrim . bezierFromPath . map (uncurry V2)
                              $ VU.toList c | c <- curves]

    go ctxt (Free (WithCliping clipPath path next)) rest =
        go (ctxt { currentClip = newModuler }) (fromF path) $
            go ctxt next rest
      where
        modulationTexture :: Texture (PixelBaseComponent px)
        modulationTexture = RawTexture $ clipRender clipPath

        newModuler = Just . subModuler $ currentClip ctxt

        subModuler Nothing = modulationTexture
        subModuler (Just v) =
            modulateTexture v modulationTexture

-- | With stroke geometry with a given stroke width, using
-- a dash pattern.
--
-- > dashedStroke [5, 10, 5] 3 JoinRound (CapRound, CapStraight 0)
-- >        [line (V2 0 100) (V2 200 100)]
--
-- <<docimages/dashed_stroke.png>>
--
dashedStroke
    :: DashPattern -- ^ Dashing pattern to use for stroking
    -> Float       -- ^ Stroke width
    -> Join        -- ^ Which kind of join will be used
    -> (Cap, Cap)  -- ^ Start and end capping.
    -> [Primitive] -- ^ List of elements to render
    -> Drawing px ()
dashedStroke = dashedStrokeWithOffset 0.0

-- | With stroke geometry with a given stroke width, using
-- a dash pattern. The offset is there to specify the starting
-- point into the pattern, the value can be negative.
--
-- > dashedStrokeWithOffset 3 [5, 10, 5] 3 JoinRound (CapRound, CapStraight 0)
-- >        [line (V2 0 100) (V2 200 100)]
--
-- <<docimages/dashed_stroke_with_offset.png>>
--
dashedStrokeWithOffset
    :: Float       -- ^ Starting offset
    -> DashPattern -- ^ Dashing pattern to use for stroking
    -> Float       -- ^ Stroke width
    -> Join        -- ^ Which kind of join will be used
    -> (Cap, Cap)  -- ^ Start and end capping.
    -> [Primitive] -- ^ List of elements to render
    -> Drawing px ()
dashedStrokeWithOffset _ [] width join caping prims =
    stroke width join caping prims
dashedStrokeWithOffset offset dashing width join caping prims =
    liftF $ DashedStroke offset dashing width join caping prims ()

-- | Generate a list of primitive representing a circle.
--
-- > fill $ circle (V2 100 100) 75
--
-- <<docimages/fill_circle.png>>
--
circle :: Point -- ^ Circle center in pixels
       -> Float -- ^ Circle radius in pixels
       -> [Primitive]
circle center radius =
    CubicBezierPrim . transform mv <$> cubicBezierCircle
  where
    mv p = (p ^* radius) ^+^ center

-- | Generate a list of primitive representing an ellipse.
--
-- > fill $ ellipse (V2 100 100) 75 30
--
-- <<docimages/fill_ellipse.png>>
--
ellipse :: Point -> Float -> Float -> [Primitive]
ellipse center rx ry =
    CubicBezierPrim . transform mv <$> cubicBezierCircle
  where
    mv (V2 x y) = V2 (x * rx) (y * ry) ^+^ center

-- | Generate a strokable line out of points list.
-- Just an helper around `lineFromPath`.
--
-- > stroke 4 JoinRound (CapRound, CapRound) $
-- >    polyline [V2 10 10, V2 100 70, V2 190 190]
--
-- <<docimages/stroke_polyline.png>>
--
polyline :: [Point] -> [Primitive]
polyline = map LinePrim . lineFromPath

-- | Generate a fillable polygon out of points list.
-- Similar to the `polyline` function, but close the
-- path.
--
-- > fill $ polygon [V2 30 30, V2 100 70, V2 80 170]
--
-- <<docimages/fill_polygon.png>>
--
polygon :: [Point] -> [Primitive]
polygon [] = []
polygon [_] = []
polygon [_,_] = []
polygon lst@(p:_) = polyline $ lst ++ [p]

-- | Generate a list of primitive representing a
-- rectangle
--
-- > fill $ rectangle (V2 30 30) 150 100
--
-- <<docimages/fill_rect.png>>
--
rectangle :: Point -- ^ Corner upper left
          -> Float -- ^ Width in pixel
          -> Float -- ^ Height in pixel
          -> [Primitive]
rectangle p@(V2 px py) w h =
  LinePrim <$> lineFromPath
    [ p, V2 (px + w) py, V2 (px + w) (py + h), V2 px (py + h), p ]

-- | Simply draw an image into the canvas. Take into account
-- any previous transformation performed on the geometry.
--
-- > drawImage textureImage 0 (V2 30 30)
--
-- <<docimages/image_simple.png>>
--
drawImage :: ModulablePixel px
          => Image px       -- ^ Image to be drawn
          -> StrokeWidth    -- ^ Border size, drawn with current texture.
          -> Point          -- ^ Position of the corner upper left of the image.
          -> Drawing px ()
drawImage img@Image { imageWidth = w, imageHeight = h } s p =
    drawImageAtSize img s p (fromIntegral w) (fromIntegral h)

-- | Draw an image with the desired size
--
-- > drawImageAtSize textureImage 2 (V2 30 30) 128 128
--
-- <<docimages/image_resize.png>>
--
drawImageAtSize :: (Pixel px, Modulable (PixelBaseComponent px))
                => Image px    -- ^ Image to be drawn
                -> StrokeWidth -- ^ Border size, drawn with current texture.
                -> Point -- ^ Position of the corner upper left of the image.
                -> Float -- ^ Width of the drawn image
                -> Float -- ^ Height of the drawn image
                -> Drawing px ()
drawImageAtSize img@Image { imageWidth = w, imageHeight = h } borderSize ip
            reqWidth reqHeight
    | borderSize <= 0 =
        withTransformation (translate p <> scale scaleX scaleY) .
            withTexture (sampledImageTexture img) $ fill rect
    | otherwise = do
        withTransformation (translate p <> scale scaleX scaleY) $
            withTexture (sampledImageTexture img) $ fill rect
        stroke borderSize (JoinMiter 0)
               (CapStraight 0, CapStraight 0) rect'
        where
          p = ip ^-^ V2 0.5 0.5
          rect = rectangle (V2 0 0) rw rh
          rect' = rectangle p reqWidth reqHeight

          (rw, rh) = (fromIntegral w, fromIntegral h)
          scaleX | reqWidth == 0 = 1
                 | otherwise = reqWidth / rw

          scaleY | reqHeight == 0 = 1
                 | otherwise = reqHeight / rh

-- | Generate a list of primitive representing a rectangle
-- with rounded corner.
--
-- > fill $ roundedRectangle (V2 10 10) 150 150 20 10
--
-- <<docimages/fill_roundedRectangle.png>>
--
roundedRectangle :: Point -- ^ Corner upper left
                 -> Float -- ^ Width in pixel
                 -> Float -- ^ Height in pixel.
                 -> Float -- ^ Radius along the x axis of the rounded corner. In pixel.
                 -> Float -- ^ Radius along the y axis of the rounded corner. In pixel.
                 -> [Primitive]
roundedRectangle (V2 px py) w h rx ry =
    [ CubicBezierPrim . transform (^+^ V2 xFar yNear) $ cornerTopR
    , LinePrim $ Line (V2 xFar py) (V2 xNear py)
    , CubicBezierPrim . transform (^+^ V2 (px + rx) (py + ry)) $ cornerTopL
    , LinePrim $ Line (V2 px yNear) (V2 px yFar)
    , CubicBezierPrim . transform (^+^ V2 (px + rx) yFar) $ cornerBottomL
    , LinePrim $ Line (V2 xNear (py + h)) (V2 xFar (py + h))
    , CubicBezierPrim . transform (^+^ V2 xFar yFar) $ cornerBottomR
    , LinePrim $ Line (V2 (px + w) yFar) (V2 (px + w) yNear)
    ]
  where
   xNear = px + rx
   xFar = px + w - rx

   yNear = py + ry
   yFar = py + h - ry

   (cornerBottomR :
    cornerTopR     :
    cornerTopL  :
    cornerBottomL:_) = transform (\(V2 x y) -> V2 (x * rx) (y * ry)) <$> cubicBezierCircle

-- | Return a simple line ready to be stroked.
--
-- > stroke 17 JoinRound (CapRound, CapRound) $
-- >     line (V2 10 10) (V2 180 170)
--
-- <<docimages/stroke_line.png>>
--
line :: Point -> Point -> [Primitive]
line p1 p2 = [LinePrim $ Line p1 p2]

