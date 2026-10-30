const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const vm=require('node:vm');
const html=fs.readFileSync(path.join(__dirname,'../../src/FruitVision.Api/wwwroot/index.html'),'utf8');
const script=fs.readFileSync(path.join(__dirname,'../../src/FruitVision.Api/wwwroot/site.js'),'utf8');
const user={id:'11111111-1111-4111-8111-111111111111',displayName:'Portal fixture',role:'Consumer',approvalStatus:'Approved',emailConfirmed:true};
const tokens={accessToken:'A'.repeat(43),refreshToken:'R'.repeat(43),user};
const challenge=method=>({requiresTwoFactor:true,method,challengeToken:'C'.repeat(43),expiresIn:600,resendAfter:60,mailSubject:'Mã xác thực Chấm công',emailHint:'***'});
const approved='22222222-2222-4222-8222-222222222222';
function deferred(){let resolve;const promise=new Promise(r=>resolve=r);return{promise,resolve};}
class Element {
 constructor(tag='div'){this.tagName=tag.toUpperCase();this.children=[];this.listeners={};this.dataset={};this.value='';this.textContent='';this.hidden=false;this.disabled=false;this.classList={toggle(){}};}
 append(...nodes){this.children.push(...nodes);}
 replaceChildren(...nodes){this.children=[...nodes];}
 addEventListener(type,fn){this.listeners[type]=fn;}
 setAttribute(name,value){this[name]=value;}
 reset(){this.data={};}
 querySelector(){return this.submitButton||(this.submitButton=new Element('button'));}
}
function response(status,data){return{status,ok:status>=200&&status<300,body:null,headers:{get:name=>name.toLowerCase()==='content-type'?'application/json':null},json:async()=>data,text:async()=>data==null?'':JSON.stringify(data)};}
async function harness(route=()=>undefined){
 const elements=new Map();
 for(const m of html.matchAll(/<([a-z]+)[^>]*\bid="([^"]+)"[^>]*>/gi)){const e=new Element(m[1]);e.id=m[2];e.hidden=/\bhidden\b/.test(m[0]);elements.set(e.id,e);}
 const panels=[...elements.values()].filter(e=>['posts','chat','history','admin'].includes(e.id));
 const buttons=[...html.matchAll(/data-panel="([^"]+)"/g)].map(m=>{const e=new Element('button');e.dataset.panel=m[1];return e;});
 const calls=[];let now=Date.now();const intervals=new Map();let timerId=0;
 const defaults=url=>url.includes('/locations/countries')?{items:[{code:'VN',name:'Việt Nam'},{code:'US',name:'Hoa Kỳ'}],source:'fixture',asOf:new Date(now).toISOString(),stale:false}:url.includes('/locations/provinces')?{items:[{code:'79',name:'Tỉnh thử'}],countryCode:'VN',source:'fixture'}:url.includes('/mobile/update')?{updateServiceEnabled:false}:url.includes('/catalog/products')?{items:[{code:'mango',name:'Xoài'}]}:url.includes('/branches/mine')?{items:[{id:approved,name:'Approved fixture',status:'Approved'},{id:'33333333-3333-4333-8333-333333333333',name:'Pending fixture',status:'Pending'}]}:{items:[]};
 const sandbox={document:{getElementById:id=>elements.get(id)||null,createElement:tag=>new Element(tag),querySelectorAll:selector=>selector==='[data-panel]'?buttons:selector==='.panel'?panels:[]},
  fetch:async(url,options={})=>{url=String(url);calls.push({url,options});const custom=route(url,options);return custom===undefined?response(200,defaults(url)):await custom;},
  FormData:class{constructor(form){this.data=form.data||{};}*[Symbol.iterator](){yield*Object.entries(this.data);}},
  location:{origin:'https://portal.test',reload(){}},URL,AbortController,TextDecoder,Uint8Array,Headers,crypto:require('node:crypto').webcrypto,
  setTimeout,clearTimeout,setInterval:fn=>{intervals.set(++timerId,fn);return timerId;},clearInterval:id=>intervals.delete(id),
  Date:class extends Date{static now(){return now;}},console};
 const context=vm.createContext(sandbox);vm.runInContext(script,context);
 const settle=async()=>{for(let i=0;i<6;i++)await new Promise(resolve=>setImmediate(resolve));};
 await settle();
 return{elements,calls,context,settle,get:id=>elements.get(id),state:expression=>vm.runInContext(expression,context),advance:ms=>{now+=ms;for(const fn of intervals.values())fn();},
  async submit(id,data){const form=elements.get(id);assert.ok(form?.listeners.submit,`${id} must bind a submit handler`);form.data=data;await form.listeners.submit({preventDefault(){},currentTarget:form,submitter:form.querySelector('button')});await settle();}};
}
test('signup HTML fixes Consumer role and uses API location and approved-branch selects',()=>{
 assert.doesNotMatch(html,/name="role"/);assert.doesNotMatch(html,/<input[^>]+name="region"/);
 assert.match(html,/<select[^>]+name="countryCode"/);assert.match(html,/<select[^>]+name="provinceCode"/);
 assert.match(html,/<select[^>]+name="branchId"/);assert.match(html,/href="\/v1\/index\.html"/);
});
test('registration201 email challenge never signs in before OTP and posts only current contract',async()=>{
 const h=await harness(url=>url.endsWith('/auth/register')?response(201,challenge('email')):undefined);
 assert.ok(h.get('register-country'));
 h.get('register-country').value='VN';await h.get('register-country').onchange();
 h.get('register-province').value='79';h.get('register-province').onchange();
 await h.submit('register',{displayName:'Fixture',email:'fixture@example.invalid',password:'Aa9!'+ 'x'.repeat(12),countryCode:'VN',provinceCode:'79'});
 const call=h.calls.find(c=>c.url.endsWith('/auth/register'));
 assert.deepEqual(Object.keys(JSON.parse(call.options.body)).sort(),['countryCode','displayName','email','password','provinceCode']);
 assert.equal(h.get('mfa').hidden,false);assert.equal(h.get('account').hidden,true);assert.equal(h.state('access'),null);
 assert.match(h.get('mfa-description').textContent,/Chấm công/);
});
test('email and authenticator verification use their separate endpoints',async()=>{
 for(const [method,endpoint] of [['email','/auth/otp/verify'],['authenticator','/auth/mfa/login']]){
  const h=await harness(url=>url.endsWith('/auth/login')?response(200,challenge(method)):url.endsWith(endpoint)?response(200,tokens):undefined);
  await h.submit('login',{email:'fixture@example.invalid',password:'Aa9!'+ 'x'.repeat(12)});
  assert.equal(h.state('access'),null);await h.submit('mfa',{code:'123456'});
  assert.ok(h.calls.some(c=>c.url.endsWith(endpoint)));assert.equal(h.state('access'),tokens.accessToken);assert.equal(h.get('account').hidden,false);
 }
});
test('email resend waits60 seconds and cancelled verification cannot resurrect a session',async()=>{
 const verification=deferred();
 const h=await harness(url=>url.endsWith('/auth/login')?response(200,challenge('email')):url.endsWith('/auth/otp/resend')?response(200,challenge('email')):url.endsWith('/auth/otp/verify')?verification.promise:undefined);
 await h.submit('login',{email:'fixture@example.invalid',password:'Aa9!'+ 'x'.repeat(12)});
 assert.ok(h.get('resend-otp'));assert.equal(h.get('resend-otp').disabled,true);
 h.advance(61000);assert.equal(h.get('resend-otp').disabled,false);await h.get('resend-otp').onclick();
 assert.equal(h.calls.filter(c=>c.url.endsWith('/auth/otp/resend')).length,1);
 const pending=h.submit('mfa',{code:'123456'});await h.settle();h.get('cancel-mfa').onclick();verification.resolve(response(200,tokens));await pending;
 assert.equal(h.state('access'),null);assert.equal(h.get('auth').hidden,false);
});
test('switching country clears province and ignores a late previous response',async()=>{
 const vietnam=deferred();
 const h=await harness(url=>url.includes('/locations/provinces?country=VN')?vietnam.promise:url.includes('/locations/provinces?country=US')?response(200,{items:[{code:'CA',name:'California'}],countryCode:'US'}):undefined);
 assert.ok(h.get('register-country'));h.get('register-country').value='VN';const first=h.get('register-country').onchange();await h.settle();
 h.get('register-country').value='US';await h.get('register-country').onchange();
 assert.equal(h.get('register-province').value,'');vietnam.resolve(response(200,{items:[{code:'79',name:'Late fixture'}],countryCode:'VN'}));await first;
 assert.ok(h.get('register-province').children.some(e=>e.value==='CA'));assert.ok(!h.get('register-province').children.some(e=>e.value==='79'));
 assert.equal(h.get('register-submit').disabled,true);
});
test('only Seller portal loads approved owned branches and post includes mandatory branchId',async()=>{
 const h=await harness(url=>url.endsWith('/posts')?response(201,{status:'AwaitingReview'}):undefined);
 h.context.authFixture={...tokens,user:{...user,role:'Producer'}};h.state('signedIn(authFixture)');await h.settle();
 assert.ok(h.get('create-post'),'Seller portal must have a branch-bound submission form');
 assert.equal(h.get('create-post').hidden,false);assert.equal(h.get('post-branch').children.filter(e=>e.value).length,1);
 h.get('post-branch').value=approved;
 await h.submit('create-post',{title:'Fixture supply',body:'Fixture supply description.',productCode:'mango',estimatedQuantityKg:'20',purpose:'Supply',branchId:approved});
 const body=JSON.parse(h.calls.find(c=>c.url.endsWith('/posts')&&c.options.method==='POST').options.body);
 assert.equal(body.branchId,approved);assert.equal(body.estimatedQuantityKg,20);assert.equal(body.purpose,'Supply');assert.ok(!('region'in body));
});
test('refresh503 retains credentials and a refresh completed after logout cannot restore them',async()=>{
 const h=await harness(url=>url.endsWith('/history')?response(401,{title:'Expired'}):url.endsWith('/auth/refresh')?response(503,{title:'Temporarily unavailable'}):undefined);
 h.context.authFixture=tokens;h.state('signedIn(authFixture)');
 await assert.rejects(h.state('api("/history")'),/Temporarily unavailable/);assert.equal(h.state('access'),tokens.accessToken);assert.equal(h.state('refresh'),tokens.refreshToken);
 const rotation=deferred();const g=await harness(url=>url.endsWith('/history')?response(401,{title:'Expired'}):url.endsWith('/auth/refresh')?rotation.promise:url.endsWith('/auth/logout')?response(204,null):undefined);
 g.context.authFixture=tokens;g.state('signedIn(authFixture)');const pending=g.state('api("/history")');const rejected=assert.rejects(pending,/Phiên đã thay đổi/);await g.settle();await g.get('logout').onclick();rotation.resolve(response(200,{...tokens,accessToken:'B'.repeat(43)}));await rejected;
 assert.equal(g.state('access'),null);assert.equal(g.state('refresh'),null);assert.equal(g.get('auth').hidden,false);
});
test('location outage and empty province list disable signup without stale selections',async()=>{
 let empty=false;
 const h=await harness(url=>url.includes('/locations/provinces')?empty?response(200,{items:[],countryCode:'VN'}):response(503,{title:'Location unavailable'}):undefined);
 h.get('register-country').value='VN';await h.get('register-country').onchange();assert.equal(h.get('register-submit').disabled,true);assert.equal(h.get('register-province').value,'');assert.match(h.get('location-status').textContent,/Location unavailable/);
 empty=true;await h.get('retry-locations').onclick();assert.equal(h.get('register-submit').disabled,true);assert.match(h.get('location-status').textContent,/trống/);
});
test('Consumer does not load Seller branches and release links reject external targets',async()=>{
 const h=await harness(url=>url.includes('/mobile/update')?response(200,{updateServiceEnabled:true,latestVersionCode:7000,latestVersionName:'Fixture',apkSizeBytes:1024,sha256:'a'.repeat(64),downloadPath:'https://other.invalid/private.apk'}):undefined);
 h.context.authFixture=tokens;h.state('signedIn(authFixture)');await h.settle();assert.equal(h.get('create-post').hidden,true);assert.ok(!h.calls.some(call=>call.url.includes('/branches/mine')));assert.equal(h.get('apk-link').hidden,true);
 assert.ok(h.calls.every(call=>call.url.startsWith('/api/v1/')));
});
test('non-JSON upstream errors stay friendly and oversized response text is rejected',async()=>{
 const h=await harness(url=>url.endsWith('/broken')?{...response(503,null),text:async()=>'<html>upstream unavailable</html>'}:url.endsWith('/oversized')?{...response(200,null),text:async()=> 'x'.repeat(300000)}:undefined);
 await assert.rejects(h.state('api("/broken",{anonymous:true})'),/dữ liệu API hợp lệ/);await assert.rejects(h.state('api("/oversized",{anonymous:true})'),/Phản hồi quá lớn/);
});
