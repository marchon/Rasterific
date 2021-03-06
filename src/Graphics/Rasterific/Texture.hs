{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- | Module describing the various filling method of the
-- geometric primitives.
--
-- All points coordinate given in this module are expressed
-- final image pixel coordinates.
module Graphics.Rasterific.Texture
    ( Texture
    , Gradient
    , withSampler
    , uniformTexture
      -- * Texture kind
    , linearGradientTexture
    , radialGradientTexture
    , radialGradientWithFocusTexture
    , sampledImageTexture

      -- * Texture manipulation
    , modulateTexture
    , transformTexture 
    ) where


import Codec.Picture.Types( Pixel( .. )
                          , Image( .. )
                          )
import Graphics.Rasterific.Types( Point, SamplerRepeat( .. ), Line( .. ) )
import Graphics.Rasterific.Shading
import Graphics.Rasterific.Transformations

-- | Set the repeat pattern of the texture (if any).
-- With padding:
--
-- > withTexture (sampledImageTexture textureImage) $
-- >   fill $ rectangle (V2 0 0) 200 200
--
-- <<docimages/sampled_texture_pad.png>>
--
-- With repeat:
--
-- > withTexture (withSampler SamplerRepeat $
-- >                 sampledImageTexture textureImage) $
-- >     fill $ rectangle (V2 0 0) 200 200
--
-- <<docimages/sampled_texture_repeat.png>>
--
-- With reflect:
--
-- > withTexture (withSampler SamplerReflect $
-- >                 sampledImageTexture textureImage) $
-- >     fill $ rectangle (V2 0 0) 200 200
--
-- <<docimages/sampled_texture_reflect.png>>
--
withSampler :: SamplerRepeat -> Texture px -> Texture px
withSampler = WithSampler

-- | Transform the coordinates used for texture before applying
-- it, allow interesting transformations.
--
-- > withTexture (withSampler SamplerRepeat $
-- >             transformTexture (rotateCenter 1 (V2 0 0) <> 
-- >                               scale 0.5 0.25)
-- >             $ sampledImageTexture textureImage) $
-- >     fill $ rectangle (V2 0 0) 200 200
--
-- <<docimages/sampled_texture_scaled.png>>
--
transformTexture :: Transformation -> Texture px -> Texture px
transformTexture = WithTextureTransform

-- | The uniform texture is the simplest texture of all:
-- an uniform color.
uniformTexture :: px -- ^ The color used for all the texture.
               -> Texture px
uniformTexture = SolidTexture

-- | Linear gradient texture.
--
-- > let gradDef = [(0, PixelRGBA8 0 0x86 0xc1 255)
-- >               ,(0.5, PixelRGBA8 0xff 0xf4 0xc1 255)
-- >               ,(1, PixelRGBA8 0xFF 0x53 0x73 255)] in
-- > withTexture (linearGradientTexture SamplerPad gradDef
-- >                        (V2 40 40) (V2 130 130)) $
-- >    fill $ circle (V2 100 100) 100
--
-- <<docimages/linear_gradient.png>>
--
linearGradientTexture :: Gradient px -- ^ Gradient description.
                      -> Point       -- ^ Linear gradient start point.
                      -> Point       -- ^ Linear gradient end point.
                      -> Texture px
linearGradientTexture gradient start end =
    LinearGradientTexture gradient (Line start end)

-- | Use another image as a texture for the filling.
-- Contrary to `imageTexture`, this function perform a bilinear
-- filtering on the texture.
--
sampledImageTexture :: Image px -> Texture px
sampledImageTexture = SampledTexture

-- | Radial gradient texture
--
-- > let gradDef = [(0, PixelRGBA8 0 0x86 0xc1 255)
-- >               ,(0.5, PixelRGBA8 0xff 0xf4 0xc1 255)
-- >               ,(1, PixelRGBA8 0xFF 0x53 0x73 255)] in
-- > withTexture (radialGradientTexture gradDef
-- >                    (V2 100 100) 75) $
-- >    fill $ circle (V2 100 100) 100
--
-- <<docimages/radial_gradient.png>>
--
radialGradientTexture :: Gradient px -- ^ Gradient description
                      -> Point       -- ^ Radial gradient center
                      -> Float       -- ^ Radial gradient radius
                      -> Texture px
radialGradientTexture = RadialGradientTexture

-- | Radial gradient texture with a focus point.
--
-- > let gradDef = [(0, PixelRGBA8 0 0x86 0xc1 255)
-- >               ,(0.5, PixelRGBA8 0xff 0xf4 0xc1 255)
-- >               ,(1, PixelRGBA8 0xFF 0x53 0x73 255)] in
-- > withTexture (radialGradientWithFocusTexture gradDef
-- >                    (V2 100 100) 75 (V2 70 70) ) $
-- >    fill $ circle (V2 100 100) 100
--
-- <<docimages/radial_gradient_focus.png>>
--
radialGradientWithFocusTexture
    :: Gradient px -- ^ Gradient description
    -> Point      -- ^ Radial gradient center
    -> Float      -- ^ Radial gradient radius
    -> Point      -- ^ Radial gradient focus point
    -> Texture px
radialGradientWithFocusTexture = RadialGradientWithFocusTexture

-- | Perform a multiplication operation between a full color texture
-- and a greyscale one, used for clip-path implementation.
modulateTexture :: (Pixel px)
                => Texture px                       -- ^ The full blown texture.
                -> Texture (PixelBaseComponent px)  -- ^ A greyscale modulation texture.
                -> Texture px                       -- ^ The resulting texture.
modulateTexture = ModulateTexture

