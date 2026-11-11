import Foundation

enum CreatorTemplateWebGLKernel {
    static let source = #"""
    const canvas=document.getElementById('canvas'),hud=document.getElementById('hud'),digits=document.getElementById('digits'),date=document.getElementById('date');
    const clamp=(v,a,b)=>Math.max(a,Math.min(b,v)),tau=Math.PI*2;
    const stats={revision:3,backend:'pending',frames:0,lost:0,restored:0,particles:0,meteors:0,stopped:false};window.__creatorRenderer=stats;
    let gl=null,program=null,buffer=null,locations={},fallback=null,ctx=null,lost=false;
    let paused=false,ended=false,raf=0,redrawTimer=0,lastPaint=null,previous=null,time=0,dirty=true,fps=budget.maxFPS,nextWidth=1,nextHeight=1;
    function fallbackContext(){
      if(ctx)return ctx;
      if(gl){fallback=document.createElement('canvas');fallback.id='fallback';canvas.after(fallback);canvas.width=canvas.height=1;}
      else fallback=canvas;
      ctx=fallback.getContext('2d',{alpha:false});stats.backend='fallback';return ctx;
    }
    function setup(){
      const compile=(type,source)=>{const shader=gl.createShader(type);gl.shaderSource(shader,source);gl.compileShader(shader);
        if(!gl.getShaderParameter(shader,gl.COMPILE_STATUS)){gl.deleteShader(shader);throw Error('template_shader_compile');}return shader;};
      let vs=null,fs=null;
      try{
        vs=compile(gl.VERTEX_SHADER,vertex);fs=compile(gl.FRAGMENT_SHADER,fragment);
        program=gl.createProgram();gl.attachShader(program,vs);gl.attachShader(program,fs);gl.linkProgram(program);
        if(!gl.getProgramParameter(program,gl.LINK_STATUS))throw Error('template_shader_link');
        gl.useProgram(program);buffer=gl.createBuffer();gl.bindBuffer(gl.ARRAY_BUFFER,buffer);
        gl.bufferData(gl.ARRAY_BUFFER,new Float32Array([-1,-1,1,-1,-1,1,-1,1,1,-1,1,1]),gl.STATIC_DRAW);
        const attribute=gl.getAttribLocation(program,'position');gl.enableVertexAttribArray(attribute);gl.vertexAttribPointer(attribute,2,gl.FLOAT,false,0,0);
        for(const key of ['resolution','time','kind',...Object.keys(rules)])locations[key]=gl.getUniformLocation(program,key);
        gl.disable(gl.BLEND);gl.disable(gl.DEPTH_TEST);stats.backend='webgl';
        if(fallback && fallback!==canvas){fallback.width=fallback.height=1;fallback.remove();}fallback=null;ctx=null;
      }catch(error){if(program)gl.deleteProgram(program);program=null;fallbackContext();}
      finally{if(vs)gl.deleteShader(vs);if(fs)gl.deleteShader(fs);}
    }
    try{gl=canvas.getContext('webgl',{alpha:false,antialias:false,depth:false,stencil:false,preserveDrawingBuffer:true,powerPreference:'low-power'});}catch(error){}
    stats.contextAvailable=!!gl;
    if(gl)setup();else fallbackContext();
    canvas.addEventListener('webglcontextlost',event=>{event.preventDefault();if(ended)return;lost=true;stats.lost++;program=null;buffer=null;fallbackContext();invalidate();});
    canvas.addEventListener('webglcontextrestored',()=>{if(ended)return;lost=false;stats.restored++;setup();invalidate();});
    let seed=budget.seed;const random=()=>{seed=(Math.imul(seed,1664525)+1013904223)>>>0;return seed/4294967296;};
    const stars=Array.from({length:budget.maxParticles},()=>({x:random(),y:random(),size:random(),phase:random()*tau}));
    function paintFallback(w,h){
      const c=fallbackContext();if(fallback.width!==w)fallback.width=w;if(fallback.height!==h)fallback.height=h;
      const speed=kind==='clock'?p.backgroundMotion:p.motionSpeed;
      const pulse=kind==='gradient'?Math.sin(time*p.breathingHz*tau)*4:0;
      c.fillStyle=kind==='gradient'?`hsl(${p.primaryHue},60%,${18+pulse}%)`:'#010208';c.fillRect(0,0,w,h);
      for(let i=0;i<3;i++){
        const scale=kind==='gradient'?p.waveScale:1,phase=time*speed*.12+i*2.1;
        const x=w*(.5+Math.cos(phase)*.3),y=h*(.5+Math.sin(phase*.7)*.35),r=Math.max(w,h)*(.5+scale*.06);
        const g=c.createRadialGradient(x,y,0,x,y,r);g.addColorStop(0,`hsla(${i%2?p.primaryHue:p.secondaryHue},75%,${kind==='gradient'?55:20}%,${kind==='gradient'?.5:.08})`);g.addColorStop(1,'transparent');c.fillStyle=g;c.fillRect(0,0,w,h);
      }
      if(kind==='stars')for(let i=0;i<stats.particles;i++){
        const s=stars[i],depth=(i%p.parallaxLayers+1)/p.parallaxLayers;
        const x=((s.x+time*speed*.025*depth)%1)*w,y=s.y*h,r=(.6+s.size*p.starSizeSpread*2.2)*Math.max(.6,h/720);
        c.fillStyle=`rgba(230,240,255,${.64+.36*Math.sin(time*p.twinkleHz*tau+s.phase)})`;c.beginPath();c.arc(x,y,r,0,tau);c.fill();
      }
    }
    const anchors={topLeft:[0,0],topCenter:[.5,0],topRight:[1,0],middleLeft:[0,.5],center:[.5,.5],middleRight:[1,.5],bottomLeft:[0,1],bottomCenter:[.5,1],bottomRight:[1,1]};
    const fonts={system:'system-ui,-apple-system,sans-serif',serif:'Georgia,serif',monospace:'Menlo,monospace'};
    let lastClock='';
    function clock(){
      const visible=kind==='clock'||kind==='stars'&&p.clockVisible;hud.hidden=!visible;if(!visible)return;
      const isClock=kind==='clock',now=new Date(),showDate=isClock&&p.showDate;
      const text=now.toLocaleTimeString(undefined,{hour:'2-digit',minute:'2-digit',second:isClock&&p.showSeconds?'2-digit':undefined,hour12:isClock&&p.hourFormat==='12h'});
      const dateText=showDate?now.toLocaleDateString(undefined,{weekday:'short',month:'short',day:'numeric'}):'';
      if(digits.textContent!==text)digits.textContent=text;if(date.textContent!==dateText)date.textContent=dateText;date.hidden=!showDate;
      const signature=JSON.stringify([text,dateText,innerWidth,innerHeight,p.clockScale,p.clockAnchor,p.font,p.glow,p.primaryHue,p.secondaryHue]);
      if(signature===lastClock)return;lastClock=signature;
      const small=Math.min(innerWidth,innerHeight),margin=Math.max(12,small*.065);
      const availableW=Math.max(1,innerWidth-2*margin),availableH=Math.max(1,innerHeight-2*margin);
      hud.style.fontFamily=fonts[isClock?p.font:'system'];hud.style.fontWeight='300';hud.style.fontSize=`${small*(isClock?.105:.075)*p.clockScale}px`;
      hud.style.transform='none';hud.style.left='0px';hud.style.top='0px';
      hud.style.color=`hsl(${p.primaryHue},28%,95%)`;
      const glow=isClock?p.glow:.15;hud.style.textShadow=`0 0 ${small*.012*glow}px hsla(${p.secondaryHue},70%,70%,.5),0 0 ${small*.04*glow}px hsla(${p.secondaryHue},70%,60%,.2)`;
      const rect=hud.getBoundingClientRect(),fit=Math.min(1,availableW/Math.max(1,rect.width),availableH/Math.max(1,rect.height));
      const [ax,ay]=anchors[p.clockAnchor];hud.style.left=`${margin+(availableW-rect.width*fit)*ax}px`;hud.style.top=`${margin+(availableH-rect.height*fit)*ay}px`;hud.style.transform=`scale(${fit})`;
    }
    function draw(){
      stats.particles=kind==='stars'?Math.floor(p.starDensity*budget.maxParticles):0;stats.meteors=0;
      if(kind==='stars'&&p.meteorRate>0)for(let i=0;i<budget.maxMeteors;i++){const period=60/p.meteorRate,shifted=time-i*period;if(shifted>=0&&shifted%(period*budget.maxMeteors)<1.8)stats.meteors++;}
      if(gl && program && !lost){
        if(canvas.width!==nextWidth)canvas.width=nextWidth;if(canvas.height!==nextHeight)canvas.height=nextHeight;
        gl.viewport(0,0,canvas.width,canvas.height);gl.useProgram(program);
        gl.uniform2f(locations.resolution,canvas.width,canvas.height);gl.uniform1f(locations.time,time);gl.uniform1f(locations.kind,{gradient:0,stars:1,clock:2}[kind]);
        for(const [key,value] of Object.entries(p))if(typeof value==='number'&&locations[key]!==undefined)gl.uniform1f(locations[key],value);
        gl.drawArrays(gl.TRIANGLES,0,6);gl.flush();
      }else paintFallback(nextWidth,nextHeight);
      clock();stats.frames++;
    }
    function schedule(){if(!ended&&!raf&&!paused)raf=requestAnimationFrame(frame);}
    function paint(now){
      if(lastPaint!==null&&now-lastPaint+.001<1000/fps)return false;
      if(!paused&&previous!==null)time+=clamp((now-previous)/1000,0,.1);previous=paused?null:now;
      draw();dirty=false;lastPaint=now;if(redrawTimer)clearTimeout(redrawTimer);redrawTimer=0;return true;
    }
    function flushDirty(){if(ended||!dirty)return;const now=performance.now();if(paint(now))return;
      if(!redrawTimer)redrawTimer=setTimeout(()=>{redrawTimer=0;flushDirty();},Math.max(1,1000/fps-(now-lastPaint)));}
    function invalidate(){dirty=true;flushDirty();schedule();}
    function frame(now){raf=0;if(ended)return;if(dirty||!paused)paint(now);schedule();}
    function resize(){
      const w=clamp(Number.isFinite(innerWidth)?innerWidth:1,1,65536),h=clamp(Number.isFinite(innerHeight)?innerHeight:1,1,65536);
      const dpr=clamp(Number.isFinite(devicePixelRatio)?devicePixelRatio:1,.1,budget.maxDeviceScale);
      const scale=Math.min(dpr,budget.maxDimension/w,budget.maxDimension/h,Math.sqrt(budget.maxPixels/(w*h)));
      nextWidth=Math.max(1,Math.floor(w*scale));nextHeight=Math.max(1,Math.floor(h*scale));lastClock='';invalidate();
    }
    window.wallpaperPropertyListener={
      applyUserProperties(properties){let changed=false;for(const [key,rule] of Object.entries(rules)){
        const value=properties[key]?.value;if(typeof value!==rule.type)continue;
        if(rule.type==='number'&&(!Number.isFinite(value)||value<rule.min||value>rule.max||rule.integer&&!Number.isInteger(value)))continue;
        if(rule.choices&&!rule.choices.includes(value))continue;if(p[key]!==value){p[key]=value;changed=true;}
      }if(changed)invalidate();},
      applyGeneralProperties(properties){if(typeof properties.fps==='number'&&Number.isFinite(properties.fps)&&properties.fps>=0)fps=properties.fps===0?budget.maxFPS:clamp(properties.fps,1,budget.maxFPS);},
      setPaused(value){paused=!!value;previous=null;if(raf)cancelAnimationFrame(raf);raf=0;schedule();}
    };
    addEventListener('resize',resize);
    addEventListener('pagehide',()=>{ended=true;stats.stopped=true;if(raf)cancelAnimationFrame(raf);if(redrawTimer)clearTimeout(redrawTimer);raf=redrawTimer=0;
      if(gl){if(buffer)gl.deleteBuffer(buffer);if(program)gl.deleteProgram(program);gl.getExtension('WEBGL_lose_context')?.loseContext();}if(fallback){fallback.width=fallback.height=1;}});
    resize();
    """#
}
