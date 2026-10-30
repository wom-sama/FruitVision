"use strict";
// Tokens are intentionally kept in memory, never localStorage or HTML attributes.
const $ = id => document.getElementById(id);
let access = null, refresh = null, me = null, challenge = null, refreshFlight = null;
const roles = {Admin:"Quản trị",Producer:"Nhà sản xuất",Trader:"Thương lái",Consumer:"Người tiêu dùng"};
const approvals = {Pending:"Chờ duyệt",NeedsInformation:"Cần bổ sung",Approved:"Đã duyệt",Rejected:"Từ chối"};
function feedback(message, error=false){$("feedback").textContent=message;$("feedback").classList.toggle("error",error);}
async function api(path, options={}, retried=false){
 const headers={"Content-Type":"application/json",...(options.headers||{})};if(access)headers.Authorization="Bearer "+access;
 let response=await fetch("/api/v1"+path,{...options,headers,credentials:"omit"});
 if(response.status===401 && refresh && !retried && !path.startsWith("/auth/")){
  if(!refreshFlight)refreshFlight=fetch("/api/v1/auth/refresh",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({refreshToken:refresh})}).then(async r=>{if(!r.ok)throw Error("Phiên đã hết hiệu lực. Hãy đăng nhập lại.");const data=await r.json();access=data.accessToken;refresh=data.refreshToken;}).finally(()=>refreshFlight=null);
  await refreshFlight;return api(path,options,true);
 }
 if(response.status===204)return null;
 const data=await response.json();if(!response.ok)throw Error(data.detail||data.title||"Không thể thực hiện yêu cầu.");return data;
}
function node(tag,text,cls){const el=document.createElement(tag);if(text!==undefined)el.textContent=text;if(cls)el.className=cls;return el;}
function bindForm(id,action){$(id).addEventListener("submit",async event=>{event.preventDefault();const button=event.submitter;button.disabled=true;try{await action(Object.fromEntries(new FormData(event.currentTarget)));}catch(e){feedback(e.message,true);}finally{button.disabled=false;}});}
function signedIn(data){access=data.accessToken;refresh=data.refreshToken;me=data.user;$("auth").hidden=true;$("mfa").hidden=true;$("account").hidden=false;$("account-name").textContent=me.displayName;$("account-detail").textContent=roles[me.role]+" · "+approvals[me.approvalStatus];$("review-reason").textContent=me.reviewReason||"";
 for(const b of document.querySelectorAll("[data-panel]")){const p=b.dataset.panel;b.hidden=p==="admin"?me.role!=="Admin":p==="chat"?me.approvalStatus!=="Approved":false;}
 feedback("Đăng nhập thành công.");}
bindForm("login",async data=>{const r=await api("/auth/login",{method:"POST",body:JSON.stringify(data)});$("login").reset();if(r.requiresTwoFactor){challenge=r.challengeToken;$("auth").hidden=true;$("mfa").hidden=false;feedback("Nhập mã xác thực hai bước.");}else signedIn(r);});
bindForm("register",async data=>{const r=await api("/auth/register",{method:"POST",body:JSON.stringify(data)});$("register").reset();feedback("Đã tạo hồ sơ "+r.displayName+". Bạn có thể đăng nhập để theo dõi kết quả duyệt.");});
bindForm("mfa",async data=>signedIn(await api("/auth/mfa/login",{method:"POST",body:JSON.stringify({challengeToken:challenge,code:data.code})})));
$("cancel-mfa").onclick=()=>{challenge=null;$("mfa").reset();$("mfa").hidden=true;$("auth").hidden=false;};
$("reload-profile").onclick=async()=>{try{signedIn({accessToken:access,refreshToken:refresh,user:await api("/auth/me")});feedback("Đã cập nhật trạng thái hồ sơ.");}catch(e){feedback(e.message,true);}};
$("logout").onclick=async()=>{try{await api("/auth/logout",{method:"POST"});}catch(e){feedback(e.message,true);}finally{access=null;refresh=null;me=null;location.reload();}};
async function posts(){const data=await api("/posts?limit=12");$("post-list").replaceChildren();for(const p of data.items){const card=node("article",undefined,"post");card.append(node("h3",p.title),node("p",p.body),node("p",p.estimatedQuantityKg+" kg dự kiến · Chưa mở đặt hàng","muted"),node("p",p.author.displayName+" · "+p.author.region,"muted"));$("post-list").append(card);}}
async function conversations(){const data=await api("/conversations?limit=50");$("conversation").replaceChildren();for(const c of data.items){const option=node("option",c.title);option.value=c.id;$("conversation").append(option);}await messages();}
async function messages(){const id=$("conversation").value;$("messages").replaceChildren();if(!id){$("messages").append(node("p","Chưa có hội thoại."));return;}const data=await api("/conversations/"+encodeURIComponent(id)+"/messages?limit=30");for(const m of data.items.reverse())$("messages").append(node("div",m.text+"\n"+new Date(m.createdAt).toLocaleString("vi-VN"),"message"));}
bindForm("send-message",async data=>{const id=$("conversation").value;if(!id)throw Error("Hãy chọn hội thoại.");await api("/conversations/"+encodeURIComponent(id)+"/messages",{method:"POST",body:JSON.stringify({clientMessageId:crypto.randomUUID().replaceAll("-",""),text:data.text})});$("send-message").reset();await messages();feedback("Tin nhắn đã được lưu.");});
async function history(){const data=await api("/history?limit=30");$("history-list").replaceChildren();for(const h of data.items){const row=node("div",undefined,"message");row.append(node("strong",h.title),node("p",h.body),node("small",(h.isDemo?"Dữ liệu mẫu · ":"")+new Date(h.createdAt).toLocaleString("vi-VN")));$("history-list").append(row);}}
async function applications(){const data=await api("/admin/applications?limit=50");$("applications").replaceChildren();for(const u of data.items){const row=node("div",undefined,"application");row.append(node("h3",u.displayName),node("p",u.email+" · "+roles[u.role]+" · "+approvals[u.approvalStatus]));const select=node("select");for(const s of ["Approved","NeedsInformation","Rejected"]){const option=node("option",approvals[s]);option.value=s;select.append(option);}select.setAttribute("aria-label","Kết quả duyệt "+u.displayName);const reason=node("input");reason.placeholder="Lý do xét duyệt (bắt buộc)";reason.minLength=3;reason.maxLength=1000;reason.setAttribute("aria-label","Lý do duyệt "+u.displayName);const save=node("button","Lưu kết quả");save.onclick=async()=>{save.disabled=true;try{await api("/admin/applications/"+u.id+"/review",{method:"POST",body:JSON.stringify({status:select.value,reason:reason.value})});feedback("Đã lưu kết quả xét duyệt.");await applications();}catch(e){feedback(e.message,true);}finally{save.disabled=false;}};row.append(select,reason,save);$("applications").append(row);}}
for(const b of document.querySelectorAll("[data-panel]"))b.onclick=async()=>{for(const p of document.querySelectorAll(".panel"))p.hidden=p.id!==b.dataset.panel;try{await ({posts,chat:conversations,history,admin:applications}[b.dataset.panel])();}catch(e){feedback(e.message,true);}};
$("reload-posts").onclick=()=>posts().catch(e=>feedback(e.message,true));$("reload-messages").onclick=()=>messages().catch(e=>feedback(e.message,true));$("conversation").onchange=()=>messages().catch(e=>feedback(e.message,true));
posts().catch(e=>feedback(e.message,true));
