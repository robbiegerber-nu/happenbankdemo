// Recaptures Home page previews (docs/assets/home/*.jpg, 1120 x 664, light theme).
// Serve docs/ first (launch entry "dashboard-2", port 8767), then: node tools/home-previews.mjs <out-folder> [page ...]
// Look at the pictures before copying them to docs/assets/home, then raise ?v= on the image links in docs/index.html.
// Pages not listed in P yet: workforce. Add a line that matches the current picture's framing.
import {spawn} from 'child_process';import fs from 'fs';
const S=process.argv[2],only=process.argv.slice(3),B='http://127.0.0.1:8767/';
const P={ // viewport width, clip width, anchor, offset above
 executive:[1180,1148,"document.querySelector('.tile')",16],
 service:[1280,1248,"[...document.querySelectorAll('h2,h3')].find(h=>/^Service level by day/.test(h.textContent)).closest('section,.card')",6],
 coaching:[960,928,"[...document.querySelectorAll('h2,h3')].find(h=>/gap to the group, by team/.test(h.textContent)).closest('section,.card')",8],
 drivers:[1280,1248,"[...document.querySelectorAll('h2,h3')].find(h=>/rose|fell|unchanged/.test(h.textContent)).closest('section,.card')",2],
 launch:[1280,1248,"document.querySelector('.tile')",2],cx:[1280,1248,"document.querySelector('.tile')",2],
 stability:[1280,1248,"document.querySelector('#t-main').closest('section,.card')",0],
 personas:[1280,602,"document.querySelector('#c-tr')",8,9],
 selfservice:[1280,1248,"document.querySelector('#t-mix').closest('section')",6],
 quality:[1280,1248,"document.querySelector('.tile')",8],
 chat:[1280,880,"document.querySelector('main h1')",8,24]};
const p=spawn('C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',['--headless=new','--disable-gpu','--remote-debugging-port=9333','--user-data-dir='+S+'/../edge-profile','about:blank'],{stdio:'ignore'});
const sl=ms=>new Promise(r=>setTimeout(r,ms));let t;for(let i=0;i<40&&!t;i++){await sl(500);try{t=(await(await fetch('http://127.0.0.1:9333/json')).json()).find(x=>x.type==='page')}catch{}}
const ws=new WebSocket(t.webSocketDebuggerUrl);await new Promise(r=>ws.onopen=r);let id=0;const w=new Map();ws.onmessage=m=>{const d=JSON.parse(m.data);if(w.has(d.id)){w.get(d.id)(d.result||d);w.delete(d.id)}};
const c=(method,params={})=>new Promise(r=>{w.set(++id,r);ws.send(JSON.stringify({id,method,params}))});
await c('Emulation.setScrollbarsHidden',{hidden:true});
await c('Emulation.setEmulatedMedia',{features:[{name:'prefers-color-scheme',value:'light'}]});
for(const[k,[vw,cw,a,off,dx]]of Object.entries(P)){if(only.length&&!only.includes(k))continue;
 await c('Emulation.setDeviceMetricsOverride',{width:vw,height:4000,deviceScaleFactor:2,mobile:false});
 await c('Page.navigate',{url:B+k+'.html'});await sl(6000);await c('Runtime.evaluate',{expression:'document.fonts.ready',awaitPromise:true});
 const e=await c('Runtime.evaluate',{returnByValue:true,expression:`(()=>{const r=(${a}).getBoundingClientRect();return [r.left+scrollX,r.top+scrollY,document.body.innerText.match(/\b(better|worse)\b/gi)]})()`});
 const v=e.result.value;console.log(k,v||JSON.stringify(e));if(!v)continue;
 const s=await c('Page.captureScreenshot',{format:'jpeg',quality:86,captureBeyondViewport:true,clip:{x:v[0]-(dx??8),y:v[1]-off,width:cw,height:cw*664/1120,scale:1120/cw/2}});
 fs.writeFileSync(`${S}/${k}.jpg`,Buffer.from(s.data,'base64'))}
await c('Browser.close');p.kill();
