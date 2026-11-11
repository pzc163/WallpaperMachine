/* WallpaperMachine shader engine v1: WebGL2, HDR feedback, bounded render size. */
(()=>{'use strict';
 const canvas=document.getElementById('wm-canvas'),host=WallpaperHost,schema=JSON.parse(document.getElementById('wm-params').textContent);
 const sources={Image:document.getElementById('wm-image').textContent,BufferA:document.getElementById('wm-buffer')?.textContent};
 let gl,programs={},targets=[],displayTarget,read=0,width=1,height=1,time=0,frame=0,lost=false,stopped=false;
 const mouse={down:false,x:0,y:0},locations=new WeakMap();
 function location(program,name){let map=locations.get(program);if(!map){map=new Map();locations.set(program,map)}if(!map.has(name))map.set(name,gl.getUniformLocation(program,name));return map.get(name)}
 const fault=(code,pass='Image',line=1)=>{document.documentElement.setAttribute('data-wm-diagnostics',JSON.stringify([{pass,line:Math.max(1,Math.min(16384,line)),code}]));document.documentElement.setAttribute('data-creator-fault','shader')};
 const vertex='#version 300 es\nprecision highp float;const vec2 v[6]=vec2[6](vec2(-1,-1),vec2(1,-1),vec2(-1,1),vec2(-1,1),vec2(1,-1),vec2(1,1));void main(){gl_Position=vec4(v[gl_VertexID],0,1);}';
 function compile(kind,source,pass){const shader=gl.createShader(kind);gl.shaderSource(shader,source);gl.compileShader(shader);
   if(!gl.getShaderParameter(shader,gl.COMPILE_STATUS)){
     const log=(gl.getShaderInfoLog(shader)||'').slice(0,4096),match=log.match(/(?:ERROR:\s*\d+:|\d+\()\s*(\d+)/);
     fault(/undeclared|not declared/i.test(log)?'undeclared':/type|convert|overload/i.test(log)?'type':'syntax',pass,Number(match?.[1]||1));gl.deleteShader(shader);throw Error('shader_compile');
   }return shader;
 }
 function link(fragment,pass){const p=gl.createProgram(),vs=compile(gl.VERTEX_SHADER,vertex,pass),fs=compile(gl.FRAGMENT_SHADER,fragment,pass);gl.attachShader(p,vs);gl.attachShader(p,fs);gl.linkProgram(p);gl.deleteShader(vs);gl.deleteShader(fs);
   if(!gl.getProgramParameter(p,gl.LINK_STATUS)){fault('link',pass);gl.deleteProgram(p);throw Error('shader_link')}return p;
 }
 function author(source,pass){const declarations=schema.parameters.map(p=>'uniform '+(p.type==='color'?'vec3':p.type==='boolean'?'bool':'float')+' p_'+p.id+';').join('\n');
   return link('#version 300 es\nprecision highp float;precision highp int;uniform vec3 iResolution;uniform float iTime,iTimeDelta,iActive;uniform int iFrame;uniform vec4 iMouse,iCursor;uniform sampler2D iChannel0;out vec4 wmOutput;\n'+declarations+'\n#line 1\n'+source+'\nvoid main(){vec4 c=vec4(0);mainImage(c,gl_FragCoord.xy);wmOutput=(any(isnan(c))||any(isinf(c)))?vec4(1,0,1,0):c;}',pass);
 }
 const present='#version 300 es\nprecision highp float;uniform sampler2D picture;uniform vec2 size;out vec4 color;vec3 aces(vec3 x){return clamp((x*(2.51*x+.03))/(x*(2.43*x+.59)+.14),0.,1.);}void main(){vec4 c=texture(picture,gl_FragCoord.xy/size);if(c.a<.001&&c.r>.99&&c.b>.99){color=vec4(1,0,1,0);return;}vec3 a=aces(max(c.rgb,vec3(0)));a=mix(12.92*a,1.055*pow(a,vec3(1./2.4))-.055,step(vec3(.0031308),a));float d=fract(52.9829189*fract(dot(gl_FragCoord.xy,vec2(.06711056,.00583715))))-.5;color=vec4(clamp(a+d/255.,0.,1.),clamp(c.a,0.,1.));}';
 function releaseTargets(){for(const t of targets.concat(displayTarget?[displayTarget]:[])){gl.deleteTexture(t.texture);gl.deleteFramebuffer(t.fbo)}targets=[];displayTarget=null}
 function target(){const texture=gl.createTexture();gl.bindTexture(gl.TEXTURE_2D,texture);gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MIN_FILTER,gl.LINEAR);gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MAG_FILTER,gl.LINEAR);gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_WRAP_S,gl.CLAMP_TO_EDGE);gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_WRAP_T,gl.CLAMP_TO_EDGE);
   const hdr=!!gl.getExtension('EXT_color_buffer_float');gl.texImage2D(gl.TEXTURE_2D,0,hdr?gl.RGBA16F:gl.RGBA8,width,height,0,gl.RGBA,hdr?gl.HALF_FLOAT:gl.UNSIGNED_BYTE,null);
   const fbo=gl.createFramebuffer();gl.bindFramebuffer(gl.FRAMEBUFFER,fbo);gl.framebufferTexture2D(gl.FRAMEBUFFER,gl.COLOR_ATTACHMENT0,gl.TEXTURE_2D,texture,0);
   if(gl.checkFramebufferStatus(gl.FRAMEBUFFER)!==gl.FRAMEBUFFER_COMPLETE)throw Error('framebuffer_unavailable');gl.clearColor(0,0,0,1);gl.clear(gl.COLOR_BUFFER_BIT);return{texture,fbo};
 }
 function resize(){if(!gl||lost||stopped)return;const e=host.environment,s=Math.min(e.dpr,2,4096/Math.max(e.width,e.height),Math.sqrt(e.maxPixels/Math.max(1,e.width*e.height)));const w=Math.max(1,Math.floor(e.width*s)),h=Math.max(1,Math.floor(e.height*s));if(w===width&&h===height&&targets.length)return;
   width=w;height=h;canvas.width=1;canvas.height=1;canvas.width=w;canvas.height=h;releaseTargets();targets=[target(),target()];if(sources.BufferA)displayTarget=target();read=0;frame=0;draw(0);
 }
 function uniforms(p,dt){gl.useProgram(p);const uniform=(name,fn,...v)=>{const l=location(p,name);if(l!==null)gl[fn](l,...v)};const c=host.cursor;
   uniform('iResolution','uniform3f',width,height,host.environment.dpr);uniform('iTime','uniform1f',time);uniform('iTimeDelta','uniform1f',dt);uniform('iFrame','uniform1i',frame);uniform('iActive','uniform1f',c.active);uniform('iCursor','uniform4f',c.x,c.y,c.vx,c.vy);
   uniform('iMouse','uniform4f',c.x*width,(1-c.y)*height,(mouse.down?1:-1)*mouse.x,(mouse.down?1:-1)*mouse.y);uniform('iChannel0','uniform1i',0);
   const values=host.parameters;for(const def of schema.parameters){const value=values[def.id]??schema.values[def.id];if(def.type==='color'){const n=parseInt(value.slice(1),16);uniform('p_'+def.id,'uniform3f',((n>>16)&255)/255,((n>>8)&255)/255,(n&255)/255)}else uniform('p_'+def.id,def.type==='boolean'?'uniform1i':'uniform1f',value)}
 }
 function pass(program,into,input,dt){gl.bindFramebuffer(gl.FRAMEBUFFER,into.fbo);gl.viewport(0,0,width,height);gl.activeTexture(gl.TEXTURE0);gl.bindTexture(gl.TEXTURE_2D,input.texture);uniforms(program,dt);gl.drawArrays(gl.TRIANGLES,0,6)}
 function draw(dt){if(lost||stopped||!targets.length)return;time+=Math.min(.1,dt);const write=1-read;
   if(sources.BufferA){pass(programs.BufferA,targets[write],targets[read],dt);pass(programs.Image,displayTarget,targets[write],dt)}else pass(programs.Image,targets[write],targets[read],dt);
   gl.bindFramebuffer(gl.FRAMEBUFFER,null);gl.viewport(0,0,width,height);gl.useProgram(programs.present);gl.activeTexture(gl.TEXTURE0);gl.bindTexture(gl.TEXTURE_2D,(displayTarget||targets[write]).texture);gl.uniform1i(location(programs.present,'picture'),0);gl.uniform2f(location(programs.present,'size'),width,height);gl.drawArrays(gl.TRIANGLES,0,6);read=write;frame++;
 }
 function init(){gl=canvas.getContext('webgl2',{alpha:true,antialias:false,premultipliedAlpha:false,preserveDrawingBuffer:true});if(!gl)throw Error('webgl2_required');programs.Image=author(sources.Image,'Image');if(sources.BufferA)programs.BufferA=author(sources.BufferA,'BufferA');programs.present=link(present,'Image');resize()}
 function probe(){for(let i=0;i<3;i++)draw(1/30);const pixels=new Uint8Array(width*height*4);gl.bindFramebuffer(gl.FRAMEBUFFER,null);gl.readPixels(0,0,width,height,gl.RGBA,gl.UNSIGNED_BYTE,pixels);let nonfinite=0;
   for(let i=0;i<pixels.length;i+=4)if(pixels[i]>250&&pixels[i+1]<5&&pixels[i+2]>250&&pixels[i+3]<5)nonfinite++;
   if(nonfinite)fault('nonfinite');return{frames:frame,nonfinite,width,height};
 }
 init();const unsub=[host.onFrame(draw),host.onResize(resize),host.onParameters(()=>{if(targets.length)draw(0)})];
 Object.defineProperty(window,'__wmValidateFrame',{value:probe});
 addEventListener('pointerdown',e=>{mouse.down=true;mouse.x=e.clientX/innerWidth*width;mouse.y=(1-e.clientY/innerHeight)*height});addEventListener('pointerup',()=>{mouse.down=false});
 canvas.addEventListener('webglcontextlost',e=>{e.preventDefault();lost=true});canvas.addEventListener('webglcontextrestored',()=>{lost=false;targets=[];displayTarget=null;programs={};init()});
 addEventListener('pagehide',()=>{stopped=true;unsub.forEach(f=>f());if(!lost){releaseTargets();Object.values(programs).forEach(p=>gl.deleteProgram(p))}});
})();
