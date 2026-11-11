import Foundation

/// Fixed, bounded GLSL. No model text or remote resources enter a trusted renderer.
enum CreatorTemplateShaders {
    static let vertex = "attribute vec2 position; void main(){gl_Position=vec4(position,0.0,1.0);}"
    static let fragment = #"""
    precision highp float;
    uniform vec2 resolution;
    uniform float time,kind,primaryHue,secondaryHue,angle,contrast,motionSpeed,waveScale,waveStrength,grainAmount,breathingHz,vignette;
    uniform float starDensity,starSizeSpread,trailLength,parallaxLayers,twinkleHz,meteorRate,backgroundMotion;
    const float TAU=6.28318530718;
    float hash(vec2 p){return fract(sin(dot(p,vec2(127.1,311.7)))*43758.5453);}
    vec2 gradient(vec2 p){float a=hash(p)*TAU;return vec2(cos(a),sin(a));}
    // Simplex noise, a fixed three-corner footprint rather than periodic wave bands.
    float noise(vec2 p){
      const float F=.36602540378,G=.21132486540;
      vec2 i=floor(p+(p.x+p.y)*F),a=p-i+(i.x+i.y)*G;
      vec2 j=a.x>a.y?vec2(1,0):vec2(0,1),b=a-j+G,c=a-1.0+2.0*G;
      vec3 t=max(.5-vec3(dot(a,a),dot(b,b),dot(c,c)),0.0);t*=t;t*=t;
      return 70.0*dot(t,vec3(dot(a,gradient(i)),dot(b,gradient(i+j)),dot(c,gradient(i+1.0))));
    }
    float fbm(vec2 p){float n=0.0,a=.5;for(int i=0;i<4;i++){n+=a*noise(p);p=mat2(.8,-.6,.6,.8)*p*2.03+17.1;a*=.5;}return n;}
    vec3 lab(float hue,float light,float chroma){float a=hue*TAU/360.0;return vec3(light,cos(a)*chroma,sin(a)*chroma);}
    vec3 rgb(vec3 c){
      vec3 lms=vec3(c.x+.3963377774*c.y+.2158037573*c.z,c.x-.1055613458*c.y-.0638541728*c.z,c.x-.0894841775*c.y-1.291485548*c.z);
      lms=lms*lms*lms;
      vec3 v=vec3(dot(lms,vec3(4.0767416621,-3.3077115913,.2309699292)),dot(lms,vec3(-1.2684380046,2.6097574011,-.3413193965)),dot(lms,vec3(-.0041960863,-.7034186147,1.707614701)));
      return pow(clamp(v,0.0,1.0),vec3(1.0/2.2));
    }
    vec3 palette(float t,float light,float chroma){
      float delta=mod(secondaryHue-primaryHue+540.0,360.0)-180.0;
      return rgb(lab(primaryHue+delta*clamp(t,0.0,1.0),light,chroma));
    }
    vec3 aurora(vec2 uv){
      float a=angle*TAU/360.0,tm=time*motionSpeed*.12;
      vec2 p=mat2(cos(a),-sin(a),sin(a),cos(a))*uv*(.9+waveScale*.65);
      vec2 flow=vec2(fbm(p+vec2(tm,0)),fbm(p+vec2(3.1,-tm*.7)));
      float field=fbm(p+flow*waveStrength*2.8+vec2(tm*.6,tm*.4));
      float blend=smoothstep(-.7,.7,field*.8+p.x*.35+flow.y*.5);
      float fold=pow(.5+.5*field,1.1),pulse=sin(time*breathingHz*TAU)*.035;
      float light=clamp(.46+fold*.3+contrast*(fold-.5)*.35+pulse,.24,.88);
      vec3 col=palette(blend,light,.105+contrast*.045);
      col*=1.0-vignette*smoothstep(.15,1.35,length(uv))*.7;
      return col+(hash(gl_FragCoord.xy)-.5)*(1.0+grainAmount*3.0)/255.0;
    }
    vec3 nebula(vec2 uv,float motion){
      float f=fbm(uv*2.1+vec2(time*motion*.015,7.2));
      float g=fbm(uv*1.3+f*.7+vec2(5.0,-time*motion*.012));
      return palette(.5+g,.6,.12)*pow(clamp(.35+f*.5+g*.25,0.0,1.0),3.0)*.19;
    }
    vec3 starfield(vec2 uv){
      vec3 col=vec3(.0005,.001,.002)+nebula(uv,motionSpeed);
      float total=floor(starDensity*384.0),layers=parallaxLayers;
      for(int layer=0;layer<4;layer++){
        float l=float(layer);if(l>=layers)break;
        float count=floor((total+layers-1.0-l)/layers);if(count<1.0)continue;
        float columns=max(1.0,ceil(sqrt(count*resolution.x/resolution.y))),rows=ceil(count/columns);
        vec2 grid=vec2(columns,rows),depth=vec2((l+1.0)/layers);
        vec2 position=(uv*vec2(resolution.y/resolution.x,1.0)+.5)*grid;
        position.x-=time*motionSpeed*.025*depth.x*grid.x;
        vec2 cell=floor(position);
        // Nine adjacent cells per layer: at most 36 star evaluations per pixel.
        for(int y=-1;y<=1;y++)for(int x=-1;x<=1;x++){
          vec2 key=mod(cell+vec2(float(x),float(y)),grid);float index=key.y*columns+key.x;
          if(index>=count)continue;
          vec2 seed=vec2(index+l*103.0,37.0),offset=vec2(hash(seed),hash(seed+19.7))*.7+.15;
          vec2 d=(cell+vec2(float(x),float(y))+offset-position)/grid*resolution;
          float spread=hash(seed+7.1),radius=(.6+spread*starSizeSpread*2.2)*(.6+depth.x*.4)*max(.6,resolution.y/720.0);
          float twinkle=.64+.36*sin(time*twinkleHz*TAU+hash(seed+2.3)*TAU);
          float core=exp(-dot(d,d)/(radius*radius));
          float glow=.12*exp(-length(d)/max(radius*2.5,.5));
          float rays=.045*exp(-abs(d.x)*2.5/radius-abs(d.y)/radius/3.0)+.045*exp(-abs(d.y)*2.5/radius-abs(d.x)/radius/3.0);
          float tail=trailLength*resolution.y*.045*depth.x*(.25+motionSpeed);
          float trail=tail>0.0 && d.x>0.0?exp(-abs(d.y)/radius)*exp(-d.x/max(tail,1.0))*.25*trailLength:0.0;
          col+=(vec3(.8)+palette(spread,.8,.06)*.2)*(core+glow+rays+trail)*twinkle;
        }
      }
      if(meteorRate>0.0){
        float period=60.0/meteorRate;
        for(int slot=0;slot<2;slot++){
          float shifted=time-float(slot)*period;if(shifted<0.0)continue;
          float age=mod(shifted,period*2.0);if(age>=1.8)continue;
          vec2 seed=vec2(floor(shifted/(period*2.0)),float(slot)+15.0);
          vec2 head=vec2(hash(seed)*.7,hash(seed+7.0)*.45)+age*vec2(.3,.18);
          vec2 delta=(vec2(uv.x*resolution.y/resolution.x+.5,.5-uv.y)-head)*resolution;
          vec2 direction=normalize(vec2(.3,.18)*resolution),normal=vec2(-direction.y,direction.x);
          float behind=-dot(delta,direction),width=max(.8,resolution.y/540.0);
          float streak=behind>=0.0?exp(-behind/(resolution.y*.095))*exp(-pow(dot(delta,normal)/width,2.0)):0.0;
          col+=palette(.7,.93,.035)*streak*sin(age/1.8*3.14159265);
        }
      }
      return col+(hash(gl_FragCoord.xy)-.5)/510.0;
    }
    void main(){
      vec2 uv=(gl_FragCoord.xy-.5*resolution)/resolution.y;
      vec3 col;
      if(kind<.5)col=aurora(uv);
      else if(kind<1.5)col=starfield(uv);
      else{
        float ambient=.5+.5*fbm(uv*1.3+vec2(time*backgroundMotion*.025,3.7));
        col=vec3(.005,.007,.012)+palette(.3+ambient*.5,.58,.09)*(.012+.065*ambient*ambient);
      }
      gl_FragColor=vec4(clamp(col,0.0,1.0),1.0);
    }
    """#
}
