//! NAMESPACE=ol.renderer.webgl.tiledemlayer.shader
//! CLASS=ol.renderer.webgl.tiledemlayer.shader.

//! COMMON

// texture with encoded elevation values
uniform sampler2D u_texture;

// length of one tile in meter at equator
uniform float u_tileSizeM;

// temporary variable for coord transfer to fragment shader
varying vec2 v_texCoord;

// decodes input data elevation value and apply exaggeration
float decodeElevation(in vec4 colorChannels, in float exaggeration) {
    float elevationM = ((colorChannels.r*255.0 + (colorChannels.g*255.0)*256.0)-11000.0)/(10.0*exaggeration);
    return elevationM;
}

//! VERTEX

// vertex coordinates for tile mesh
attribute vec2 a_position;

// tile offset in current framebuffer view
uniform vec4 u_tileOffset;

// current shearing factor
uniform vec2 u_scaleFactor;

void main(void) { 

    // Orientation of coordinate system in vertex shader:
    // y
    // ^ 
    // |
    // |
    // ------>  x

    // pass current vertex coordinates to fragment shader
    v_texCoord = a_position;
    
    // compute y-flipped texture coordinates for further processing in fragment-shader
    v_texCoord.y = 1.0 - v_texCoord.y;

    // read and decode elevation for current vertex
    float absElevation = decodeElevation(texture2D(u_texture, v_texCoord.xy),1.0);
    
    // shift vertex positions by given scale factor (dependend of the plan oblique inclination)
    // direction of shift is always the top of the screen so it has to be adapted when the map view is rotated
    // z value has to be inverted to get a left handed coordinate system and to make the depth test work
    gl_Position = vec4((a_position+(absElevation * u_scaleFactor.xy) / u_tileSizeM) * u_tileOffset.xy + u_tileOffset.zw, 
                        1.0-abs(absElevation/u_tileSizeM), 
                        1.0);
}

//! FRAGMENT

// color ramp texture to look up hypsometric tints
uniform sampler2D u_colorRamp;

// texture with overlay map
uniform sampler2D u_overlayTexture;

// flag for coloring inland waterbodies
uniform bool u_waterBodies; 

// flag for hillShading
uniform bool u_hillShading; 

// flag for active overlay texture
uniform bool u_overlayActive;

// flag for testing mode
uniform bool u_testing;    

// scale threshold values to adapt color ramp 
// u_colorScale.x is lower threshold, u_colorScale.y is upper threshold
uniform vec2 u_colorScale;

// direction of light source
uniform vec3 u_light; 

// hillShading Opacity for Blending
uniform float u_hillShadingOpacity; 

// hillShading Exaggeration
uniform float u_hsExaggeration; 

// intensity of ambient light
uniform float u_ambient_light; 

// min Elevation in current Extent
uniform float u_minElevation; 

// max Elevation in current Extent
uniform float u_maxElevation;     

// assumed to be the highest elevation in the model
const float MAX_ELEVATION = 9000.0; 

// cellsize for tile resolution of 256x256 pixel = 1.0/256.0
const highp float CELLSIZE = 0.00390625; 

void main(void) {
  
    // read elevations from current cell and neighbours
        vec2 m_texCoord = v_texCoord;
        float exaggerationFactor = 1.0-u_hsExaggeration;

        // read and decode elevation values from tile texture
        float absElevation = decodeElevation(texture2D(u_texture, m_texCoord.xy),1.0);

        // read and decode exaggerated elevation values from tile texture
        float absElevationEx = decodeElevation(texture2D(u_texture, m_texCoord.xy),exaggerationFactor);

        // compute neighbouring vertices
            vec3 neighbourRight = vec3(m_texCoord.x+CELLSIZE, 1.0 - m_texCoord.y,0.0);
            vec3 neighbourAbove = vec3(m_texCoord.x, 1.0 - m_texCoord.y+CELLSIZE,0.0);  

            neighbourRight.z = decodeElevation(texture2D(u_texture, vec2(m_texCoord.x+CELLSIZE, m_texCoord.y)),exaggerationFactor);
            neighbourAbove.z = decodeElevation(texture2D(u_texture, vec2(m_texCoord.x, m_texCoord.y-CELLSIZE)),exaggerationFactor);

            // hack to avoid artifacts in tile borders
                if(m_texCoord.x >= 1.0-CELLSIZE){ // eastern border of tile
                    // use neighbour LEFT
                    neighbourRight = vec3(m_texCoord.x-CELLSIZE, 1.0 - m_texCoord.y,0.0);
                    neighbourRight.z = decodeElevation(texture2D(u_texture, vec2(m_texCoord.x-CELLSIZE, m_texCoord.y)),exaggerationFactor);
                }

                if(m_texCoord.y <= CELLSIZE){ // northern border of tile
                    // use neighbour BELOW
                    neighbourAbove = vec3(m_texCoord.x, 1.0 - (m_texCoord.y+CELLSIZE),0.0);
                    neighbourAbove.z = decodeElevation(texture2D(u_texture, vec2(m_texCoord.x, m_texCoord.y+CELLSIZE)),exaggerationFactor);
                }
          
    // texture
        vec4 fragColor;
        if(u_overlayActive){
             // use overlay color
             fragColor = texture2D(u_overlayTexture, m_texCoord);
        } else {
            // computation of hypsometric color
                
                // scaling of color ramp
                float elevationRange = u_maxElevation-u_minElevation;
                float colorMin = u_colorScale.x/elevationRange;
                float colorMax = u_colorScale.y/elevationRange;             
                float relativeElevation = ((absElevation/elevationRange) - colorMin) / (colorMax - colorMin);
                
                // read corresponding value from color ramp texture
                fragColor = abs(texture2D(u_colorRamp,vec2(0.5,relativeElevation)));

                // color for water surfaces in flat terrain
                if(neighbourRight.z == absElevationEx && neighbourAbove.z == absElevationEx){
                    
                    // sealevel (0.0m) or below (i.e. negative no data values)
                    if(absElevation <= 0.0){
                        fragColor = vec4(0.5058823529,0.7725490196,0.8470588235,1.0);   // set color to blue

                    // if not on sea-level and inland waterBody flag is true    
                    } else if(u_waterBodies) {

                        // doublecheck if this pixel really belongs to a larger surface with help of remaining two neighbours
                        //vec3 neighbourAbove = vec3(v_texCoord.x,v_texCoord.y-CELLSIZE/2.0,0.0);  
                        //vec3 neighbourLeft = vec3(v_texCoord.x+CELLSIZE/2.0,v_texCoord.y,0.0);  
                        //if(decodeElevation(texture2D(u_texture, neighbourAbove.xy)) == absElevation && decodeElevation(texture2D(u_texture, neighbourLeft.xy)) == absElevation){
                            fragColor = vec4(0.5058823529,0.7725490196,0.8470588235,1.0);   // set color to blue
                        //}
                    }
                } 
        }

    // computation of hillshading
        if(u_hillShading){
            // transform to meter coordinates for normal computation
            vec3 currentV = vec3(m_texCoord.x*u_tileSizeM,(1.0 - m_texCoord.y)*u_tileSizeM,absElevationEx);
            neighbourRight.xy *= u_tileSizeM;
            neighbourAbove.xy *= u_tileSizeM;

            // normal computation
            vec3 normal = normalize(cross(neighbourRight-currentV,neighbourAbove-currentV));

            if(m_texCoord.x >= 1.0-CELLSIZE){ // eastern border of tile
                 normal = normalize(cross(currentV-neighbourRight,neighbourAbove-currentV));
            }

            if(m_texCoord.y <= CELLSIZE){ // northern border of tile
                 normal = normalize(cross(currentV-neighbourRight,neighbourAbove-currentV));
            }

            // compute hillShade with help of u_light and normal and blend hypsocolor with hillShade
            float hillShade = clamp(u_ambient_light * 1.0+ max(dot(normal,normalize(u_light)),0.0),1.0-u_hillShadingOpacity,1.0);
            vec4 hillShadeC = vec4(hillShade,hillShade,hillShade,1.0);


            // float hillShadeD = clamp(hillShade,0.2,1.0);
            // vec4 hillShadeA = vec4(hillShadeD,hillShadeD,hillShadeD,1.0);

            // float hillShadeL = clamp(hillShade,0.1,0.4);
            // vec4 hillShadeB = vec4(hillShadeL,hillShadeL,hillShadeL,1.0);
     
            // vec4 zero = vec4(0,0,0,0);
            // vec4 one = vec4(1.0,1.0,1.0,1.0);
            // vec4 two = vec4(2.0,2.0,2.0,2.0);

            //https://en.wikipedia.org/wiki/Blend_modes

            //overlay mixing
            // if(hillShade < 0.5){
            //     gl_FragColor = two * hillShadeC * fragColor;
            // } else {
            //     gl_FragColor = one-two*(one-hillShadeC)*(one-fragColor);
            // }

            // hard light mixing
            // if(fragColor.x < 0.5 || fragColor.y < 0.5 || fragColor.z < 0.5){
            //     gl_FragColor = two * fragColor * hillShadeC;
            // } else {
            //     gl_FragColor = one-two*(one-fragColor)*(one-hillShadeC);
            // }
           
            //screen
            // gl_FragColor = one-(one-hillShadeC)*(one-fragColor);

            // multiply mixing
            // gl_FragColor = (fragColor * hillShadeA)*(one-(one-hillShadeB)*(one-fragColor));
            // gl_FragColor = (one-(one-hillShadeB)*(one-hillShadeA))*fragColor;


            gl_FragColor = hillShadeC*fragColor;

        } else {
            // apply hypsometric color without hillshading
            gl_FragColor = fragColor;
        }

    // testing mode
        if(u_testing){
            float lineWidth = 3.0 * CELLSIZE;
            if(m_texCoord.x >= 1.0-lineWidth){
                gl_FragColor = vec4(0.0,0.0,1.0,1.0);
            }
            if(m_texCoord.x <= lineWidth){
                gl_FragColor = vec4(1.0,0.0,0.0,1.0);
            }
            if(m_texCoord.y <= lineWidth){
                gl_FragColor = vec4(0.0,1.0,0.0,1.0);
            }
            if(m_texCoord.y >= 1.0-lineWidth){
                gl_FragColor = vec4(0.0,0.5,0.5,1.0);
            } 
            if(mod(m_texCoord.x,65.0*CELLSIZE) < CELLSIZE){
               gl_FragColor = vec4(0.9,0.9,0.9,0.1);
            }
            if(mod(m_texCoord.y,65.0*CELLSIZE) < CELLSIZE){
               gl_FragColor = vec4(0.9,0.9,0.9,0.1);
            }
        }
}
