/* WallpaperMachine host API v1. No timers or polling without a live frame subscriber. */
(()=>{if(window.top===window||window.WallpaperHost)return;
 const frames=new Set(),resizes=new Set(),params=new Set(),pauses=new Set();
 let token=0,last=0,time=0,frame=0,paused=false,definitions=[],values=Object.create(null);
 let target={x:.5,y:.5,active:0},cursor={x:.5,y:.5,vx:0,vy:0,active:0},environment;
 const readEnvironment=()=>Object.freeze({width:innerWidth,height:innerHeight,dpr:devicePixelRatio||1,screenWidth:screen.width,screenHeight:screen.height,dark:matchMedia('(prefers-color-scheme:dark)').matches,maxFPS:30,maxPixels:2073600});
 const notify=(set,value)=>{for(const f of [...set])f(value)};
 const schedule=()=>{if(frames.size&&!token&&!paused)token=requestAnimationFrame(tick)};
 function tick(now){token=0;if(paused)return;const dt=last?Math.min(.1,(now-last)/1000):1/30;last=now;time+=dt;frame++;
   const previous=cursor,k=1-Math.exp(-dt*9),x=previous.x+(target.x-previous.x)*k,y=previous.y+(target.y-previous.y)*k;
   cursor=Object.freeze({x,y,vx:(x-previous.x)/dt,vy:(y-previous.y)/dt,active:previous.active+(target.active-previous.active)*(1-Math.exp(-dt*4))});
   target.active*=Math.exp(-dt*.8);for(const f of [...frames])f(dt,time,frame);schedule();
 }
 function subscription(set,f){if(typeof f!=='function'||set.size>=32)throw Error('host_subscription_limit');set.add(f);schedule();return()=>{set.delete(f);if(!frames.size&&token){cancelAnimationFrame(token);token=0;last=0}}}
 function apply(input){for(const p of definitions){let v=input[p.id]?.value;if(v===undefined)continue;
   if(p.type==='number'&&Number.isFinite(v)&&v>=p.min&&v<=p.max)values[p.id]=v;
   else if(p.type==='boolean'&&typeof v==='boolean')values[p.id]=v;
   else if(p.type==='color'&&typeof v==='string'){
     if(/^#[\da-f]{6}$/i.test(v))values[p.id]=v;
     else {const c=v.trim().split(/\s+/).map(Number);if(c.length===3&&c.every(x=>Number.isFinite(x)&&x>=0&&x<=1))values[p.id]='#'+c.map(x=>Math.round(x*255).toString(16).padStart(2,'0')).join('')}
   }
 }notify(params,Object.freeze({...values}));}
 function load(){const node=document.getElementById('wm-params');if(node){const schema=JSON.parse(node.textContent);definitions=schema.parameters;values=Object.assign(Object.create(null),schema.values)}notify(params,Object.freeze({...values}));}
 const host=Object.freeze({version:1,get cursor(){return cursor},get environment(){return environment},get parameters(){return Object.freeze({...values})},get paused(){return paused},get frame(){return frame},
   onFrame:f=>subscription(frames,f),onResize:f=>{const off=subscription(resizes,f);f(environment);return off},onParameters:f=>{const off=subscription(params,f);f(Object.freeze({...values}));return off},onPause:f=>subscription(pauses,f)});
 Object.defineProperty(window,'WallpaperHost',{value:host,writable:false,configurable:false});
 Object.defineProperty(window,'__wmParameters',{value:apply,writable:false,configurable:false});
 Object.defineProperty(window,'__wmPause',{value:value=>{paused=!!value;target.active=0;if(token)cancelAnimationFrame(token);token=0;last=0;notify(pauses,paused);schedule()},writable:false,configurable:false});
 Object.defineProperty(window,'__wmCursor',{value:(x,y,active)=>{target={x:Math.max(0,Math.min(1,x)),y:Math.max(0,Math.min(1,y)),active:active?1:0}},writable:false,configurable:false});
 environment=readEnvironment();
 addEventListener('resize',()=>{environment=readEnvironment();notify(resizes,environment)});
 matchMedia('(prefers-color-scheme:dark)').addEventListener('change',()=>{environment=readEnvironment();notify(resizes,environment)});
 addEventListener('pointermove',e=>window.__wmCursor(e.clientX/Math.max(1,innerWidth),e.clientY/Math.max(1,innerHeight),true),true);
 addEventListener('pointerleave',()=>{target.active=0},true);
 addEventListener('pagehide',()=>{paused=true;if(token)cancelAnimationFrame(token);token=0;frames.clear();resizes.clear();params.clear();pauses.clear()});
 if(document.readyState==='loading')addEventListener('DOMContentLoaded',load,{once:true});else load();
})();
