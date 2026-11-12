import Foundation

/// Small native-owned author surface. Resource violations are failures, never extra capabilities.
enum CreatorCodeSDK {
    static var source: String { base + CreatorLibrary.hostScript }
    private static let base = #"""
    (()=>{if(window.top===window)return;
      let paused=false,last=-Infinity,next=0,raf=0;const pending=new Map(),nativeRAF=requestAnimationFrame.bind(window),nativeCancel=cancelAnimationFrame.bind(window);
      const nativeAttribute=Element.prototype.setAttribute,nativeJSON=JSON.stringify.bind(JSON);let reported=null;
      const publish=()=>{const element=document.documentElement;if(element&&reported){nativeAttribute.call(element,'data-creator-detail',nativeJSON(reported.detail));nativeAttribute.call(element,'data-creator-fault',reported.kind)}};
      const report=(kind,detail={code:kind})=>{if(reported)return;reported={kind,detail};publish()};
      addEventListener('DOMContentLoaded',publish,{once:true});
      const detail=(e,event)=>{const names={SyntaxError:'syntax',ReferenceError:'reference',TypeError:'type',RangeError:'range'};const prefix=String(event?.message||'').match(/^(?:Uncaught )?(SyntaxError|ReferenceError|TypeError|RangeError)\b/);const d={code:names[e?.name]||names[prefix?.[1]]||'script'};
        if(event?.filename==='about:srcdoc'){d.source=event.filename;d.line=event.lineno;d.column=event.colno}
        else {const match=String(e?.stack||'').slice(0,2048).match(/about:srcdoc:(\d+):(\d+)/);if(match){d.source='about:srcdoc';d.line=Number(match[1]);d.column=Number(match[2])}}
        return d};
      addEventListener('error',e=>{const d=detail(e.error,e);report(d.code==='syntax'?'syntax':'script',d)},true);
      addEventListener('unhandledrejection',e=>{const d=detail(e.reason);d.code='unhandled';report('unhandled',d)},true);
      function frame(now){raf=0;if(paused)return;if(now-last>=1000/30-.001){last=now;const batch=[...pending.values()];pending.clear();for(const f of batch){try{f(now)}catch(e){report('script',detail(e))}}}schedule();}
      function schedule(){if(!paused&&pending.size&&!raf)raf=nativeRAF(frame);}
      Object.defineProperty(window,'requestAnimationFrame',{value:f=>{if(typeof f!=='function')throw TypeError();if(pending.size>=64){report('resource',{code:'animationQueue'});return 0;}pending.set(++next,f);schedule();return next;},writable:false,configurable:false});
      Object.defineProperty(window,'cancelAnimationFrame',{value:id=>pending.delete(id),writable:false,configurable:false});
      Object.defineProperty(window,'__creatorNativePaused',{value:value=>{paused=!!value;window.__wmPause?.(paused);if(raf)nativeCancel(raf);raf=0;last=-Infinity;window.wallpaperPropertyListener?.setPaused?.(paused);schedule();},writable:false,configurable:false});
      const descriptors={width:Object.getOwnPropertyDescriptor(HTMLCanvasElement.prototype,'width'),height:Object.getOwnPropertyDescriptor(HTMLCanvasElement.prototype,'height')};
      for(const key of ['width','height']){
        const descriptor=descriptors[key],other=key==='width'?'height':'width';
        Object.defineProperty(HTMLCanvasElement.prototype,key,{get:descriptor.get,set(value){
          value=Number(value);if(!Number.isFinite(value)||value<1||value>4096){report('resource',{code:'canvasDimensions'});return;}if(value*this[other]>2073600){report('resource',{code:'canvasPixels'});return;}
          descriptor.set.call(this,Math.floor(value));
        },configurable:false});
      }
      if('OffscreenCanvas' in window)Object.defineProperty(window,'OffscreenCanvas',{value:undefined,writable:false,configurable:false});
      if(HTMLCanvasElement.prototype.transferControlToOffscreen)Object.defineProperty(HTMLCanvasElement.prototype,'transferControlToOffscreen',{value:()=>{report('resource',{code:'unsupportedCanvas'});throw Error('offline_canvas_only')},writable:false,configurable:false});
      const attribute=Element.prototype.setAttribute;
      Object.defineProperty(HTMLCanvasElement.prototype,'setAttribute',{value:function(name,value){
        const key=String(name).toLowerCase();if(key==='width'||key==='height'){this[key]=value;return;}return attribute.call(this,name,value);
      },writable:false,configurable:false});
      // Also catch mutation paths that bypass the ordinary property/attribute setters.
      new MutationObserver(records=>{for(const r of records){const c=r.target;if(c instanceof HTMLCanvasElement&&(c.width*c.height>2073600||Math.max(c.width,c.height)>4096)){const code=Math.max(c.width,c.height)>4096?'canvasDimensions':'canvasPixels';descriptors.width.set.call(c,1);descriptors.height.set.call(c,1);report('resource',{code});}}}).observe(document,{subtree:true,attributes:true,attributeFilter:['width','height']});
      const contexts=new WeakSet();let contextCount=0;
      const get=HTMLCanvasElement.prototype.getContext;
      Object.defineProperty(HTMLCanvasElement.prototype,'getContext',{value:function(kind,...options){
        if(!contexts.has(this)){if(contextCount>=1||this.width*this.height>2073600||Math.max(this.width,this.height)>4096){report('resource',{code:contextCount>=1?'canvasCount':Math.max(this.width,this.height)>4096?'canvasDimensions':'canvasPixels'});return null;}contexts.add(this);contextCount++;}
        if(kind==='webgl'||kind==='webgl2'||kind==='experimental-webgl')options[0]={...(options[0]||{}),preserveDrawingBuffer:true,powerPreference:'low-power'};
        return get.call(this,kind,...options);
      },writable:false,configurable:false});
      for(const api of [window.WebGLRenderingContext,window.WebGL2RenderingContext].filter(Boolean)){
        for(const [name,query,status] of [['compileShader','getShaderParameter','COMPILE_STATUS'],['linkProgram','getProgramParameter','LINK_STATUS']]){
          const original=api.prototype[name];Object.defineProperty(api.prototype,name,{value:function(object){const r=original.call(this,object);if(!this[query](object,this[status]))report('shader',{code:name==='compileShader'?'shaderCompile':'shaderLink'});return r;},writable:false,configurable:false});
        }
      }
      // Console payloads never reach native logs or retain unbounded buffers.
      let logs=0;for(const name of ['log','info','debug','warn','error','trace','dir','table'])Object.defineProperty(console,name,{value:()=>{if(++logs===257)report('resource',{code:'consoleLimit'});},writable:false,configurable:false});
      const position=(x,y,active)=>Object.freeze({x,y,normalizedX:innerWidth?x/innerWidth:0,normalizedY:innerHeight?y/innerHeight:0,active});
      let cursor=position(0,0,false);
      Object.defineProperty(window,'wallpaperCursor',{get:()=>cursor,configurable:false});
      addEventListener('pointermove',e=>{cursor=position(e.clientX,e.clientY,true)},true);
      addEventListener('pointerleave',()=>{cursor=position(cursor.x,cursor.y,false)},true);
      Object.defineProperty(window,'__creatorCursor',{value:(nx,ny,active)=>{
        const x=nx*innerWidth,y=ny*innerHeight;cursor=position(x,y,!!active);window.__wmCursor?.(nx,ny,active);if(paused||!active)return;
        const target=document.elementFromPoint(x,y)||window;
        target.dispatchEvent(new PointerEvent('pointermove',{clientX:x,clientY:y,bubbles:true,pointerType:'mouse',isPrimary:true}));
        target.dispatchEvent(new MouseEvent('mousemove',{clientX:x,clientY:y,bubbles:true}));
      },writable:false,configurable:false});
    })();
    """#
}
