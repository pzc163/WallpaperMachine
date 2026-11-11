/* WallpaperMachine Three engine v1. Procedural light, bounded pixels, no asset loader. */
(()=>{'use strict';
 const {THREE:T,RoomEnvironment,EffectComposer,RenderPass,UnrealBloomPass,OutputPass}=WMLib;
 const host=WallpaperHost,canvas=document.getElementById('wm-canvas'),schema=JSON.parse(document.getElementById('wm-params').textContent);
 let renderer,scene,camera,composer,bloom,environment,api,lost=false,stopped=false,time=0,frames=0;
 const target=new T.Vector3(0,0,0),basePosition=new T.Vector3(0,0,8),disposers=[];
 function fault(){document.documentElement.setAttribute('data-wm-diagnostics',JSON.stringify([{pass:'Image',line:1,code:'nonfinite'}]));document.documentElement.setAttribute('data-creator-fault','shader')}
 function parameters(){return Object.assign({},schema.values,host.parameters)}
 function resize(){if(!renderer||lost||stopped)return;const e=host.environment,s=Math.min(e.dpr,2,4096/Math.max(e.width,e.height),Math.sqrt(e.maxPixels/Math.max(1,e.width*e.height))),w=Math.max(1,Math.floor(e.width*s)),h=Math.max(1,Math.floor(e.height*s));
   canvas.width=1;canvas.height=1;renderer.setPixelRatio(1);renderer.setSize(w,h,false);composer.setPixelRatio(1);composer.setSize(w,h);camera.aspect=e.width/e.height;camera.updateProjectionMatrix();if(api)draw(0);
 }
 function finite(){let ok=true,count=0;scene.traverse(o=>{count++;if(count>4096||![...o.position,...o.scale,...o.quaternion].every(Number.isFinite))ok=false});return ok&&[...camera.position,...camera.projectionMatrix.elements].every(Number.isFinite)}
 function draw(dt){if(lost||stopped||!api)return;dt=Math.min(.1,Math.max(0,dt));time+=dt;api.parameters=parameters();api.cursor=host.cursor;api.environment=host.environment;api.time=time;
   updateScene(api,dt);const p=api.parameters,amount=Number.isFinite(p.parallax)?p.parallax:.35,c=api.cursor;
   camera.position.set(basePosition.x+(c.x-.5)*amount,basePosition.y-(c.y-.5)*amount,basePosition.z);camera.lookAt(target);
   bloom.strength=Number.isFinite(p.bloom)?p.bloom:.28;composer.render(dt);frames++;
 }
 function init(){renderer=new T.WebGLRenderer({canvas,antialias:true,alpha:false,preserveDrawingBuffer:true,powerPreference:'low-power'});
   renderer.setClearColor(0x030509,1);renderer.toneMapping=T.ACESFilmicToneMapping;renderer.toneMappingExposure=1;renderer.outputColorSpace=T.SRGBColorSpace;
   scene=new T.Scene();camera=new T.PerspectiveCamera(42,1,.05,160);camera.position.copy(basePosition);
   const room=new RoomEnvironment(),pmrem=new T.PMREMGenerator(renderer);environment=pmrem.fromScene(room,.04,.1,100,{size:128});scene.environment=environment.texture;room.dispose();pmrem.dispose();
   composer=new EffectComposer(renderer);composer.addPass(new RenderPass(scene,camera));bloom=new UnrealBloomPass(new T.Vector2(1,1),.28,.6,.65);composer.addPass(bloom);composer.addPass(new OutputPass());
   api={THREE:T,scene,camera,renderer,composer,bloom,parameters:parameters(),cursor:host.cursor,environment:host.environment,time:0,state:{},target,basePosition,onDispose:f=>{if(typeof f==='function'&&disposers.length<32)disposers.push(f)}};
   const state=setupScene(api);if(state!==undefined)api.state=state;resize();
 }
 function dispose(){disposers.splice(0).forEach(f=>f());if(scene){const geometries=new Set(),materials=new Set();scene.traverse(o=>{if(o.geometry)geometries.add(o.geometry);for(const m of (Array.isArray(o.material)?o.material:[o.material]))if(m)materials.add(m)});geometries.forEach(g=>g.dispose());materials.forEach(m=>m.dispose())}composer?.passes.forEach(p=>p.dispose?.());composer?.dispose();environment?.dispose();renderer?.dispose()}
 function probe(){for(let i=0;i<3;i++)draw(1/30);const valid=finite();if(!valid)fault();return{frames,nonfinite:valid?0:1,width:canvas.width,height:canvas.height}}
 init();const unsub=[host.onFrame(draw),host.onResize(resize),host.onParameters(()=>draw(0))];
 Object.defineProperty(window,'__wmValidateFrame',{value:probe});
 canvas.addEventListener('webglcontextlost',e=>{e.preventDefault();lost=true});canvas.addEventListener('webglcontextrestored',()=>{dispose();lost=false;init()});
 addEventListener('pagehide',()=>{stopped=true;unsub.forEach(f=>f());dispose()});
})();
