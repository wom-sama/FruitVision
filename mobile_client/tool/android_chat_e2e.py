"""Post via desktop HTTPS API, assert release mobile chat changes without refresh."""
import json,time,urllib.request,uuid,datetime
from android_ai_e2e import ROOT,adb,tap_text,texts,wait_text,screenshot,save_report
project=ROOT.parent
private=project/'server/.local'
base=json.loads((private/'tunnel-state.json').read_text(encoding='utf-8-sig'))['publicUrl']
password=json.loads((private/'runtime.json').read_text(encoding='utf-8-sig'))['Demo']['Password']
def api(path,body=None,token=None):
    headers={'Content-Type':'application/json'}
    if token:headers['Authorization']='Bearer '+token
    data=None if body is None else json.dumps(body).encode()
    with urllib.request.urlopen(urllib.request.Request(base+'/api/v1'+path,data=data,headers=headers),timeout=12) as response:
        payload=response.read();return json.loads(payload) if payload else None
session=api('/auth/login',{'email':'producer@fruitvision.test','password':password})
token=session['accessToken']
try:
    conversation=api('/conversations',token=token)['items'][0]
    if any('Kết quả phân tích' in text for text in texts()):adb('shell','input','keyevent','4')
    tap_text('Trao đổi');wait_text(conversation['title']);tap_text(conversation['title'])
    wait_text('Đã kết nối')
    marker='Realtime APK21 '+uuid.uuid4().hex[:8]
    message=api('/conversations/'+conversation['id']+'/messages',{'clientMessageId':uuid.uuid4().hex,'text':marker},token)
    started=time.monotonic();visible=wait_text(marker,seconds=15)
    screenshot('2.1-chat-realtime')
    save_report('chat',{'automaticWithoutManualRefresh':True,'secondsUntilVisible':round(time.monotonic()-started,2),
        'messageId':message['id'],'marker':marker,'conversationId':conversation['id'],'visibleLabels':visible,
        'atUtc':datetime.datetime.now(datetime.timezone.utc).isoformat()})
    print('PASS actual release chat automatic update from independent HTTPS request')
finally:api('/auth/logout',{},token)
