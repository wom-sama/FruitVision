"use strict";
// Tokens are kept only in page memory; never storage, URLs or HTML attributes.
const $=id=>document.getElementById(id);
let access=null,refresh=null,me=null,challenge=null,refreshFlight=null;
let sessionGeneration=0,authAttempt=0,challengeTimer=null,pendingMessage=null;
let locationGeneration=0,countryController=null,provinceController=null;
let branchGeneration=0,branchController=null,releaseGeneration=0;
const allowedCountries=new Set(),allowedProvinces=new Set(),approvedBranches=new Set(),productsSet=new Set();
const roles={Admin:"Quản trị",Producer:"Nhà vườn",Trader:"Thương lái",Consumer:"Người tiêu dùng"};
const approvals={Pending:"Chờ duyệt",NeedsInformation:"Cần bổ sung",Approved:"Đã duyệt",Rejected:"Từ chối"};
const tokenPattern=/^[A-Za-z0-9_-]{43}$/;
function feedback(message,error=false){$("feedback").textContent=String(message).slice(0,500);$("feedback").classList.toggle("error",error);}
class ApiError extends Error{constructor(message,status=0,retryAfter=0){super(message);this.status=status;this.retryAfter=retryAfter;}}
function node(tag,text,cls){const el=document.createElement(tag);if(text!==undefined)el.textContent=text;if(cls)el.className=cls;return el;}
function placeholder(select,text){select.replaceChildren();const item=node("option",text);item.value="";select.append(item);select.value="";}
function option(select,value,label){const item=node("option",label);item.value=value;select.append(item);}
function isSeller(){return !!me&&me.approvalStatus==="Approved"&&(me.role==="Producer"||me.role==="Trader");}
async function readJson(response){
 const maximum=256*1024;let text="";
 if(response.body&&typeof response.body.getReader==="function"){
  const reader=response.body.getReader(),decoder=new TextDecoder();let length=0;
  try{while(true){const part=await reader.read();if(part.done)break;length+=part.value.byteLength;if(length>maximum){await reader.cancel();throw new ApiError("Phản hồi quá lớn. Hãy tải lại một trang dữ liệu nhỏ hơn.",response.status);}text+=decoder.decode(part.value,{stream:true});}text+=decoder.decode();}finally{reader.releaseLock();}
 }else{text=await response.text();if(text.length>maximum)throw new ApiError("Phản hồi quá lớn. Hãy tải lại.",response.status);}
 if(!text)return null;
 try{return JSON.parse(text);}catch{throw new ApiError("Máy chủ chưa trả về dữ liệu API hợp lệ. Hãy kiểm tra kết nối và thử lại.",response.status);}
}
async function requestJson(path,options={},token=null){
 if(typeof path!=="string"||!path.startsWith("/")||path.startsWith("//")||path.includes("\\")||path.includes("#"))throw new ApiError("Đường dẫn API không hợp lệ.");
 const target=new URL("/api/v1"+path,location.origin);if(target.origin!==location.origin)throw new ApiError("Chỉ kết nối API cùng máy chủ.");
 const {anonymous,signal,...init}=options,controller=new AbortController();
 const abort=()=>controller.abort();if(signal){if(signal.aborted)controller.abort();else signal.addEventListener("abort",abort,{once:true});}
 const timeout=setTimeout(abort,20000),headers={Accept:"application/json",...(options.headers||{})};
 if(init.body!==undefined)headers["Content-Type"]="application/json";
 delete headers.Authorization;if(token)headers.Authorization="Bearer "+token;
 try{
  const response=await fetch(target.pathname+target.search,{...init,headers,signal:controller.signal,credentials:"omit",redirect:"error"});
  if(controller.signal.aborted)throw new ApiError("Yêu cầu đã hủy hoặc quá thời gian. Vui lòng thử lại.");
  return{ok:response.ok,status:response.status,data:response.status===204?null:await readJson(response),headers:response.headers};
 }catch(error){if(error instanceof ApiError)throw error;throw new ApiError(controller.signal.aborted?"Yêu cầu đã hủy hoặc quá thời gian. Vui lòng thử lại.":"Không kết nối được máy chủ. Hãy kiểm tra mạng và địa chỉ API.");}
 finally{clearTimeout(timeout);if(signal)signal.removeEventListener("abort",abort);}
}
function failure(result){
 const data=result.data||{};let message=data.detail||data.title;
 if(!message&&data.errors)message=Object.values(data.errors).flat().filter(value=>typeof value==="string").slice(0,2).join(" ");
 const retry=Number(result.headers.get("Retry-After")||data.retryAfter||0);
 return new ApiError(typeof message==="string"?message.slice(0,400):"Không thể thực hiện yêu cầu. Vui lòng thử lại.",result.status,Number.isFinite(retry)?Math.min(3600,Math.max(0,retry)):0);
}
async function refreshTokens(){
 if(!refreshFlight){
  const generation=sessionGeneration,original=refresh;
  refreshFlight=(async()=>{
   const result=await requestJson("/auth/refresh",{method:"POST",body:JSON.stringify({refreshToken:original})});
   if(generation!==sessionGeneration||refresh!==original)throw new ApiError("Phiên đã thay đổi; yêu cầu cũ đã được bỏ qua.");
   if(!result.ok){if(result.status===401||result.status===403)clearSession();throw failure(result);}
   if(!tokenPattern.test(result.data?.accessToken)||!tokenPattern.test(result.data?.refreshToken))throw new ApiError("Phản hồi phiên đăng nhập không hợp lệ.");
   access=result.data.accessToken;refresh=result.data.refreshToken;
  })();
 }
 const flight=refreshFlight;try{await flight;}finally{if(refreshFlight===flight)refreshFlight=null;}
}
async function api(path,options={},retried=false){
 const generation=sessionGeneration,sent=options.anonymous?null:access,result=await requestJson(path,options,sent);
 if(sent&&generation!==sessionGeneration)throw new ApiError("Phiên đã thay đổi; yêu cầu cũ đã được bỏ qua.");
 if(result.status===401&&refresh&&!options.anonymous&&!retried&&!path.startsWith("/auth/")){await refreshTokens();return api(path,options,true);}
 if(!result.ok)throw failure(result);return result.data;
}
function bindForm(id,action){
 $(id).addEventListener("submit",async event=>{
  event.preventDefault();const form=event.currentTarget;if(form.dataset.busy==="true")return;
  const button=event.submitter||form.querySelector("button[type=submit]");form.dataset.busy="true";if(button)button.disabled=true;
  try{await action(Object.fromEntries(new FormData(form)));}catch(error){feedback(error.message,true);}
  finally{form.dataset.busy="false";if(button)button.disabled=false;syncForms();}
 });
}
function syncForms(){
 $("register-submit").disabled=$("register").dataset.busy==="true"||!allowedCountries.has($("register-country").value)||!allowedProvinces.has($("register-province").value)||$("register-province").disabled;
 $("post-submit").disabled=$("create-post").dataset.busy==="true"||!isSeller()||!approvedBranches.has($("post-branch").value)||!productsSet.has($("post-product").value);
 updateChallengeClock();
}
function clearChallenge(){challenge=null;if(challengeTimer!==null)clearInterval(challengeTimer);challengeTimer=null;$("mfa").reset();$("mfa").hidden=true;}
function clearSession(){
 sessionGeneration++;authAttempt++;access=null;refresh=null;me=null;refreshFlight=null;pendingMessage=null;clearChallenge();
 branchGeneration++;branchController?.abort();approvedBranches.clear();productsSet.clear();
 $("auth").hidden=false;$("account").hidden=true;$("create-post").hidden=true;$("account-name").textContent="";$("account-detail").textContent="";$("review-reason").textContent="";
 for(const id of ["messages","conversation","history-list","applications"])$(id).replaceChildren();
 for(const button of document.querySelectorAll("[data-panel]"))button.hidden=button.dataset.panel!=="posts";
 for(const panel of document.querySelectorAll(".panel"))panel.hidden=panel.id!=="posts";syncForms();
}
function renderAccount(){
 $("auth").hidden=true;$("account").hidden=false;$("account-name").textContent=me.displayName;
 $("account-detail").textContent=(roles[me.role]||me.role)+" · "+(approvals[me.approvalStatus]||me.approvalStatus)+(me.emailConfirmed?" · Email đã xác minh":" · Email chưa xác minh");
 $("review-reason").textContent=me.reviewReason||"";$("create-post").hidden=!isSeller();
 for(const button of document.querySelectorAll("[data-panel]")){const panel=button.dataset.panel;button.hidden=panel==="admin"?me.role!=="Admin"||me.approvalStatus!=="Approved":panel==="chat"?me.approvalStatus!=="Approved":false;}
 if(isSeller())loadSeller().catch(error=>feedback(error.message,true));else{branchGeneration++;branchController?.abort();approvedBranches.clear();productsSet.clear();}
 syncForms();
}
function signedIn(data){
 if(!tokenPattern.test(data?.accessToken)||!tokenPattern.test(data?.refreshToken)||!data.user||!roles[data.user.role])throw new ApiError("Chưa nhận được phiên đã xác minh. Hãy đăng nhập lại.");
 sessionGeneration++;authAttempt++;refreshFlight=null;access=data.accessToken;refresh=data.refreshToken;me=data.user;clearChallenge();renderAccount();feedback("Đăng nhập thành công.");
}
function beginChallenge(data){
 if(!tokenPattern.test(data?.challengeToken)||!["email","authenticator"].includes(data.method)||data.accessToken||data.refreshToken)throw new ApiError("Phản hồi xác thực không hợp lệ. Hãy đăng nhập lại.");
 clearChallenge();const email=data.method==="email",expires=Number(data.expiresIn);
 challenge={token:data.challengeToken,method:data.method,expiresAt:Date.now()+Math.max(0,Math.min(600,Number.isFinite(expires)?expires:0))*1000,resendAt:Date.now()+Math.max(0,Math.min(3600,Number(data.resendAfter)||60))*1000,busy:false};
 $("auth").hidden=true;$("mfa").hidden=false;$("mfa-title").textContent=email?"Xác minh mã email":"Mã ứng dụng xác thực";
 $("mfa-label").textContent=email?"Mã email 6 chữ số":"Mã từ ứng dụng xác thực";
 $("mfa-description").textContent=email?"Thư dùng kênh gửi chung, tiêu đề: "+String(data.mailSubject||"Mã xác thực Chấm công").slice(0,120)+". Kiểm tra hộp thư đã đăng ký và không chia sẻ mã.":"Nhập mã TOTP hiện tại từ ứng dụng xác thực của bạn. Không dùng mã email ở bước này.";
 $("resend-otp").hidden=!email;challengeTimer=setInterval(updateChallengeClock,1000);updateChallengeClock();feedback(email?"Nhập mã email để hoàn tất xác minh; chưa có phiên đăng nhập.":"Nhập mã từ ứng dụng xác thực; chưa có phiên đăng nhập.");
}
function updateChallengeClock(){
 if(!challenge)return;const expired=Date.now()>=challenge.expiresAt,wait=Math.max(0,Math.ceil((challenge.resendAt-Date.now())/1000));
 $("mfa-time").textContent=expired?"Phiên xác thực đã hết hạn. Chọn Đăng nhập lại để nhận yêu cầu mới.":"Còn "+Math.max(0,Math.ceil((challenge.expiresAt-Date.now())/1000))+" giây để xác thực.";
 $("verify-code").disabled=expired||$("mfa").dataset.busy==="true";
 $("resend-otp").disabled=expired||challenge.busy||wait>0;$("resend-otp").textContent=wait>0?"Gửi lại mã email ("+wait+"s)":"Gửi lại mã email";
}
async function startAuth(path,data){
 clearSession();const attempt=++authAttempt;
 const result=await api(path,{method:"POST",body:JSON.stringify(data),anonymous:true});
 if(attempt!==authAttempt)return;if(result?.requiresTwoFactor)beginChallenge(result);else signedIn(result);
}
bindForm("login",async data=>{try{await startAuth("/auth/login",{email:data.email,password:data.password});}finally{$("login").reset();}});
bindForm("register",async data=>{
 if(!allowedCountries.has(data.countryCode)||!allowedProvinces.has(data.provinceCode))throw new ApiError("Chọn quốc gia và tỉnh/thành hợp lệ trước khi đăng ký.");
 try{await startAuth("/auth/register",{displayName:data.displayName,email:data.email,password:data.password,countryCode:data.countryCode,provinceCode:data.provinceCode});}
 finally{$("register").reset();$("register-country").value="";resetProvince("Chọn quốc gia trước");}
});
bindForm("mfa",async data=>{
 const pending=challenge,attempt=authAttempt;if(!pending||Date.now()>=pending.expiresAt)throw new ApiError("Phiên xác thực đã hết hạn. Hãy đăng nhập lại.");
 if(!/^[0-9]{6}$/.test(data.code||""))throw new ApiError("Nhập mã gồm 6 chữ số.");
 const path=pending.method==="email"?"/auth/otp/verify":"/auth/mfa/login";
 const result=await api(path,{method:"POST",body:JSON.stringify({challengeToken:pending.token,code:data.code}),anonymous:true});
 if(attempt===authAttempt&&challenge===pending)signedIn(result);
});
$("cancel-mfa").onclick=()=>{authAttempt++;clearChallenge();$("auth").hidden=false;feedback("Đã hủy yêu cầu xác thực. Hãy đăng nhập lại khi cần.");};
$("resend-otp").onclick=async()=>{
 const pending=challenge,attempt=authAttempt;if(!pending||pending.method!=="email"||pending.busy||Date.now()<pending.resendAt||Date.now()>=pending.expiresAt)return;
 pending.busy=true;updateChallengeClock();
 try{const result=await api("/auth/otp/resend",{method:"POST",body:JSON.stringify({challengeToken:pending.token}),anonymous:true});if(attempt===authAttempt&&challenge===pending)beginChallenge(result);}
 catch(error){if(challenge===pending){if(error.status===429)pending.resendAt=Date.now()+(error.retryAfter||60)*1000;feedback(error.message,true);}}
 finally{if(challenge===pending){pending.busy=false;updateChallengeClock();}}
};
$("reload-profile").onclick=async()=>{const generation=sessionGeneration;try{const profile=await api("/auth/me");if(generation!==sessionGeneration||!access)return;me=profile;renderAccount();feedback("Đã cập nhật hồ sơ và quyền hiện tại.");}catch(error){feedback(error.message,true);}};
$("logout").onclick=async()=>{const token=access;clearSession();try{const result=await requestJson("/auth/logout",{method:"POST"},token);if(!result.ok)throw failure(result);feedback("Đã đăng xuất.");}catch(error){feedback("Đã xóa phiên trên trang này. "+error.message,true);}};
function resetProvince(text){allowedProvinces.clear();placeholder($("register-province"),text);$("register-province").disabled=true;syncForms();}
function locationInfo(data){return(data.stale?"Đang dùng cache còn hạn. ":"")+String(data.source||"Danh mục API").slice(0,180)+(data.asOf?" · Cập nhật: "+new Date(data.asOf).toLocaleString("vi-VN"):"");}
async function loadCountries(){
 const generation=++locationGeneration;countryController?.abort();provinceController?.abort();countryController=new AbortController();allowedCountries.clear();
 $("register-country").disabled=true;placeholder($("register-country"),"Đang tải quốc gia…");resetProvince("Chọn quốc gia trước");$("location-status").textContent="Đang tải danh mục địa điểm từ API…";
 try{const data=await api("/locations/countries",{anonymous:true,signal:countryController.signal});if(generation!==locationGeneration)return;
  const countries=Array.isArray(data?.items)?data.items.filter(item=>typeof item.code==="string"&&/^[A-Z]{2}$/.test(item.code)&&typeof item.name==="string"):[];
  if(!countries.length)throw new ApiError("Danh mục quốc gia đang trống. Chọn Tải lại; chưa thể đăng ký.");
  placeholder($("register-country"),"Chọn quốc gia");for(const item of countries){allowedCountries.add(item.code);option($("register-country"),item.code,item.name);}
  $("register-country").disabled=false;$("location-status").textContent=locationInfo(data);
 }catch(error){if(generation===locationGeneration)$("location-status").textContent=error.message;}finally{if(generation===locationGeneration)syncForms();}
}
async function loadProvinces(){
 const country=$("register-country").value,generation=++locationGeneration;provinceController?.abort();provinceController=new AbortController();resetProvince("Đang tải tỉnh/thành…");
 if(!allowedCountries.has(country)){resetProvince("Chọn quốc gia trước");return;}
 $("location-status").textContent="Đang tải tỉnh/thành…";
 try{const data=await api("/locations/provinces?country="+encodeURIComponent(country),{anonymous:true,signal:provinceController.signal});if(generation!==locationGeneration||country!==$("register-country").value)return;
  if(data.countryCode&&data.countryCode!==country)throw new ApiError("Danh mục tỉnh không khớp quốc gia. Hãy tải lại.");
  const provinces=Array.isArray(data?.items)?data.items.filter(item=>typeof item.code==="string"&&item.code.length>0&&item.code.length<=128&&typeof item.name==="string"):[];
  if(!provinces.length)throw new ApiError("Danh mục tỉnh/thành đang trống. Chưa thể gửi hồ sơ; hãy tải lại.");
  placeholder($("register-province"),"Chọn tỉnh / thành phố");for(const item of provinces){allowedProvinces.add(item.code);option($("register-province"),item.code,item.name);}
  $("register-province").disabled=false;$("location-status").textContent=locationInfo(data);
 }catch(error){if(generation===locationGeneration)$("location-status").textContent=error.message;}finally{if(generation===locationGeneration)syncForms();}
}
$("register-country").onchange=loadProvinces;$("register-province").onchange=syncForms;
$("retry-locations").onclick=()=>allowedCountries.has($("register-country").value)?loadProvinces():loadCountries();
async function loadSeller(){
 const generation=++branchGeneration,session=sessionGeneration;branchController?.abort();branchController=new AbortController();approvedBranches.clear();productsSet.clear();
 placeholder($("post-branch"),"Chọn chi nhánh đã duyệt");placeholder($("post-product"),"Đang tải nông sản…");placeholder($("post-purpose"),"Chọn mục đích");option($("post-purpose"),"Supply","Nguồn cung");
 if(me?.role==="Trader")option($("post-purpose"),"Demand","Nhu cầu");$("post-purpose").value=me?.role==="Trader"?"Demand":"Supply";$("branch-status").textContent="Đang tải chi nhánh đã duyệt…";syncForms();
 if(!isSeller())return;
 try{const [branches,catalog]=await Promise.all([api("/branches/mine?limit=50",{signal:branchController.signal}),api("/catalog/products",{signal:branchController.signal})]);
  if(generation!==branchGeneration||session!==sessionGeneration||!isSeller())return;
  for(const branch of branches.items||[])if(branch.status==="Approved"&&typeof branch.id==="string"){approvedBranches.add(branch.id);option($("post-branch"),branch.id,branch.name);}
  placeholder($("post-product"),"Chọn nông sản");for(const product of catalog.items||[])if(typeof product.code==="string"){productsSet.add(product.code);option($("post-product"),product.code,product.name);}
  $("post-product").value=[...productsSet][0]||"";
  $("branch-status").textContent=approvedBranches.size?"Chọn một chi nhánh đã được duyệt."+(branches.next?" Web chỉ tải 50 mục gần nhất; dùng app để xem đầy đủ.":""):"Chưa có chi nhánh đã duyệt trong danh sách tải về. Hãy quản lý/gửi chi nhánh trong app và chờ Admin duyệt.";
 }catch(error){if(generation===branchGeneration&&session===sessionGeneration)$("branch-status").textContent=error.message;}finally{if(generation===branchGeneration)syncForms();}
}
$("reload-branches").onclick=()=>loadSeller().catch(error=>feedback(error.message,true));$("post-branch").onchange=syncForms;$("post-product").onchange=syncForms;
bindForm("create-post",async data=>{
 if(!isSeller()||!approvedBranches.has(data.branchId)||!productsSet.has(data.productCode))throw new ApiError("Chọn chi nhánh đã duyệt và nông sản hợp lệ.");
 const quantity=Number(data.estimatedQuantityKg);if(!Number.isFinite(quantity)||quantity<0.001||quantity>1000000)throw new ApiError("Số kg dự kiến cần từ 0,001 đến 1.000.000.");
 const purpose=me.role==="Producer"?"Supply":data.purpose;if(!["Supply","Demand"].includes(purpose))throw new ApiError("Mục đích tin không hợp lệ.");
 await api("/posts",{method:"POST",body:JSON.stringify({title:data.title,body:data.body,productCode:data.productCode,estimatedQuantityKg:quantity,purpose,branchId:data.branchId})});
 $("create-post").reset();$("post-branch").value="";feedback("Đã gửi tin dự kiến cho Admin xét duyệt; tin chưa công khai.");await posts();
});
async function release(){
 const generation=++releaseGeneration,abi=$("apk-abi").value||"arm64-v8a";$("apk-link").hidden=true;$("apk-status").textContent="Đang kiểm tra gói phát hành…";
 if(!["arm64-v8a","armeabi-v7a","x86_64"].includes(abi))return;
 try{const data=await api("/mobile/update?versionCode=1&abi="+abi,{anonymous:true});if(generation!==releaseGeneration)return;
  const route="/api/v1/mobile/releases/"+data.latestVersionCode+"/"+abi+".apk";
  if(!data.updateServiceEnabled||!Number.isSafeInteger(data.latestVersionCode)||data.latestVersionCode<=0||data.downloadPath!==route||!/^\/[a-zA-Z0-9/_.-]+$/.test(route)||!Number.isSafeInteger(data.apkSizeBytes)||data.apkSizeBytes<1||data.apkSizeBytes>80*1024*1024||!/^([a-fA-F0-9]{64})$/.test(data.sha256||"")){$("apk-status").textContent="Chưa có gói APK hợp lệ cho kiến trúc này trên máy chủ.";return;}
  $("apk-link").href=route;$("apk-link").textContent="Tải APK "+String(data.latestVersionName||data.latestVersionCode).slice(0,100)+" · "+(data.apkSizeBytes/1024/1024).toFixed(1)+" MiB";$("apk-link").hidden=false;$("apk-status").textContent="Gói đang được phát hành cho "+abi+". Kiểm tra thiết bị trước khi cài.";
 }catch(error){if(generation===releaseGeneration)$("apk-status").textContent=error.message;}
}
$("apk-abi").onchange=release;
async function posts(){const data=await api("/posts?limit=12",{anonymous:true});$("post-list").replaceChildren();for(const p of data.items||[]){const card=node("article",undefined,"post");card.append(node("h3",p.title),node("p",p.body),node("p",p.estimatedQuantityKg+" kg dự kiến · Chưa mở đặt hàng","muted"),node("p",p.author.displayName+" · "+p.author.region,"muted"));$("post-list").append(card);}if(!data.items?.length)$("post-list").append(node("p","Chưa có tin được công bố."));}
async function conversations(){const data=await api("/conversations?limit=50");$("conversation").replaceChildren();for(const c of data.items){const item=node("option",c.title);item.value=c.id;$("conversation").append(item);}await messages();}
async function messages(){const id=$("conversation").value;$("messages").replaceChildren();if(!id){$("messages").append(node("p","Chưa có hội thoại."));return;}const data=await api("/conversations/"+encodeURIComponent(id)+"/messages?limit=30");for(const m of data.items.reverse())$("messages").append(node("div",(m.sender?.displayName||"Thành viên")+(m.sender?.role?" · "+(roles[m.sender.role]||m.sender.role):"")+"\n"+m.text+"\n"+new Date(m.createdAt).toLocaleString("vi-VN"),"message"));}
bindForm("send-message",async data=>{const id=$("conversation").value;if(!id)throw new ApiError("Hãy chọn hội thoại.");if(!pendingMessage||pendingMessage.id!==id||pendingMessage.text!==data.text)pendingMessage={id,text:data.text,key:crypto.randomUUID().replaceAll("-","")};await api("/conversations/"+encodeURIComponent(id)+"/messages",{method:"POST",body:JSON.stringify({clientMessageId:pendingMessage.key,text:data.text})});pendingMessage=null;$("send-message").reset();await messages();feedback("Tin nhắn đã được lưu.");});
async function history(){const data=await api("/history?limit=30");$("history-list").replaceChildren();for(const h of data.items){const row=node("div",undefined,"message");row.append(node("strong",h.title),node("p",h.body),node("small",(h.isDemo?"Dữ liệu mẫu · ":"")+new Date(h.createdAt).toLocaleString("vi-VN")));$("history-list").append(row);}}
async function applications(){const data=await api("/admin/applications?limit=50");$("applications").replaceChildren();for(const u of data.items){const row=node("div",undefined,"application");row.append(node("h3",u.displayName),node("p",u.email+" · "+roles[u.role]+" · "+approvals[u.approvalStatus]));const select=node("select");for(const s of ["Approved","NeedsInformation","Rejected"]){const item=node("option",approvals[s]);item.value=s;select.append(item);}select.setAttribute("aria-label","Kết quả duyệt "+u.displayName);const reason=node("input");reason.placeholder="Lý do xét duyệt (bắt buộc)";reason.minLength=3;reason.maxLength=1000;reason.setAttribute("aria-label","Lý do duyệt "+u.displayName);const save=node("button","Lưu kết quả");save.onclick=async()=>{save.disabled=true;try{await api("/admin/applications/"+u.id+"/review",{method:"POST",body:JSON.stringify({status:select.value,reason:reason.value})});feedback("Đã lưu trạng thái tài khoản; không tự thay đổi vai trò kinh doanh.");await applications();}catch(error){feedback(error.message,true);}finally{save.disabled=false;}};row.append(select,reason,save);$("applications").append(row);}}
for(const button of document.querySelectorAll("[data-panel]"))button.onclick=async()=>{for(const panel of document.querySelectorAll(".panel"))panel.hidden=panel.id!==button.dataset.panel;try{await({posts,chat:conversations,history,admin:applications}[button.dataset.panel])();}catch(error){feedback(error.message,true);}};
$("reload-posts").onclick=()=>posts().catch(error=>feedback(error.message,true));$("reload-messages").onclick=()=>messages().catch(error=>feedback(error.message,true));$("conversation").onchange=()=>messages().catch(error=>feedback(error.message,true));
loadCountries();release();posts().catch(error=>feedback(error.message,true));
