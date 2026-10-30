"""Actual owned HTTPS -> PostgreSQL -> Python/ORT -> SignalR acceptance probe.

Never tunes model/policy, prints credentials, or treats detections as ground truth.
"""
from pathlib import Path
import datetime, hashlib, http.client, json, os, time, urllib.error, urllib.parse, urllib.request, uuid
from websockets.sync.client import connect

ROOT=Path(__file__).resolve().parents[1]
PROJECT=ROOT.parent
state=json.loads((ROOT/'.local/tunnel-state.json').read_text(encoding='utf-8-sig'))
BASE=state['publicUrl']
assert BASE.startswith('https://') and urllib.parse.urlparse(BASE).hostname.endswith('.trycloudflare.com')
settings=json.loads((ROOT/'.local/runtime.json').read_text(encoding='utf-8-sig'))
PASSWORD=settings['Demo']['Password']
checks=[]
report={'startedUtc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'baseUrl':BASE,'checks':checks,
        'scope':'Actual public HTTPS/WSS, private PostgreSQL, current pinned CPU ONNX worker. Not model accuracy qualification.'}

def check(name,value):
    checks.append({'name':name,'pass':bool(value)})
    assert value,name
def request(path,data=None,token=None,method=None,raw=None,content_type='application/json',headers=None):
    h={'Content-Type':content_type,**(headers or {})}
    if token:h['Authorization']='Bearer '+token
    body=raw if raw is not None else (json.dumps(data).encode() if data is not None else None)
    req=urllib.request.Request(BASE+path,data=body,headers=h,method=method)
    try:r=urllib.request.urlopen(req,timeout=25)
    except urllib.error.HTTPError as e:r=e
    with r:
        payload=r.read()
        result=json.loads(payload) if payload and 'json' in r.headers.get('Content-Type','') else payload
        return r.status,result
def login(role):
    code,data=request('/api/v1/auth/login',{'email':role+'@fruitvision.test','password':PASSWORD})
    check(role+' login',code==200 and 'accessToken' in data)
    return data['accessToken']
def frames(ws,timeout=8):
    packet=ws.recv(timeout=timeout)
    return [json.loads(frame) for frame in packet.split('\x1e') if frame]
def send(ws,body):ws.send(json.dumps(body)+'\x1e')
def upload(path,kind,token,key=None):
    key=key or uuid.uuid4().hex
    content_type='video/mp4' if kind=='video' else ('image/png' if path.suffix.lower()=='.png' else 'image/jpeg')
    url=urllib.parse.urlparse(BASE)
    client=http.client.HTTPSConnection(url.hostname,timeout=90)
    client.putrequest('POST','/api/v1/ai/jobs?mediaType='+kind)
    for k,v in {'Authorization':'Bearer '+token,'Content-Type':content_type,
                'Content-Length':str(path.stat().st_size),'X-Client-Request-Id':key}.items():client.putheader(k,v)
    client.endheaders()
    with path.open('rb') as file:
        while block:=file.read(65536):client.send(block)
    response=client.getresponse();payload=response.read();code=response.status;client.close()
    return code,json.loads(payload),key
def wait_job(ws,job_id,token,max_seconds=175):
    deadline=time.monotonic()+max_seconds;events=[];snapshot=None
    while time.monotonic()<deadline:
        send(ws,{'type':6})
        try:
            for frame in frames(ws,timeout=4):
                if frame.get('target')=='AiJobChanged' and frame['arguments'][0]['id']==job_id:events.append(frame['arguments'][0])
        except TimeoutError:pass
        code,snapshot=request('/api/v1/ai/jobs/'+job_id,token=token)
        check('job snapshot authenticated',code==200)
        if snapshot['status'] in ('Succeeded','Failed','Cancelled'):return snapshot,events
    raise TimeoutError('Owned AI job deadline')

try:
    check('AI ready on owned PC',request('/health/ready')[1]['aiReady'] is True)
    producer=login('producer');consumer=login('consumer');trader=login('trader')
    check('anonymous job history denied',request('/api/v1/ai/jobs')[0]==401)
    socket_url=BASE.replace('https://','wss://')+'/hubs/fruitvision'
    with connect(socket_url,additional_headers={'Authorization':'Bearer '+producer},proxy=None,open_timeout=10,close_timeout=3,max_size=65536) as ws:
        send(ws,{'protocol':'json','version':1})
        check('actual WSS SignalR handshake',frames(ws)[0]=={})
        bad=request('/api/v1/ai/jobs?mediaType=image',token=producer,method='POST',raw=b'not-a-png',content_type='image/png',headers={'X-Client-Request-Id':uuid.uuid4().hex})
        check('bad magic rejected before inference',bad[0]==400)
        image=PROJECT/'app/android/app/src/main/assets/demo_multi_mango.png'
        code,job,key=upload(image,'image',producer)
        check('raw image accepted as202',code==202)
        job_id=job['id']
        check('other user cannot read job',request('/api/v1/ai/jobs/'+job_id,token=consumer)[0]==404)
        check('other user cannot preview job',request('/api/v1/ai/jobs/'+job_id+'/preview',token=consumer)[0]==404)
        check('other user cannot cancel job',request('/api/v1/ai/jobs/'+job_id+'/cancel',token=consumer,method='POST')[0]==404)
        image_job,image_events=wait_job(ws,job_id,producer)
        check('actual ORT image succeeded',image_job['status']=='Succeeded')
        check('image event arrived on WSS',len(image_events)>0)
        check('image result has pinned model',image_job['result']['modelSha256']=='8a69c66a9444c18c98a7e3e58a44f4dddda9eb4583dd4448f430ff9e8db27c41')
        code,preview=request('/api/v1/ai/jobs/'+job_id+'/preview',token=producer)
        check('authorized annotated JPEG served',code==200 and preview.startswith(b'\xff\xd8\xff'))
        (ROOT/'docs/ai-image-preview.jpg').write_bytes(preview)
        code,repeated,_=upload(image,'image',producer,key)
        check('request ID retry creates no duplicate job',code==200 and repeated['id']==job_id)
        video=Path('E:/Downloads/1791976881101_60159301540236327_8706827019393545510.mp4')
        code,video_job,_=upload(video,'video',producer)
        check('user supplied video accepted',code==202)
        video_job,video_events=wait_job(ws,video_job['id'],producer)
        check('actual full video completed',video_job['status']=='Succeeded')
        check('real video progress events received',len(video_events)>=2)
        check('video counted decoded frames',video_job['result']['framesProcessed']>100)
        check('max-visible and confirmed-tracks separate',all(k in video_job['result'] for k in ('maxVisibleCount','confirmedTrackCount','lineCrossingCount')))
        report['imageResult']=image_job['result'];report['videoResult']=video_job['result']
        report['videoSourceSha256']=hashlib.sha256(video.read_bytes()).hexdigest()
        report['imageEvents']=image_events;report['videoEvents']=video_events
        report['jobIds']=[image_job['id'],video_job['id']]
        # SignalR chat requires an authorized conversation group and persists before broadcast.
        code,rows=request('/api/v1/conversations',token=producer);conversation=rows['items'][0]['id']
        send(ws,{'type':1,'invocationId':'join-probe','target':'JoinConversation','arguments':[conversation]})
        deadline=time.monotonic()+8;joined=False
        while time.monotonic()<deadline and not joined:
            for frame in frames(ws):
                if frame.get('invocationId')=='join-probe':joined='error' not in frame
        check('chat group membership accepted',joined)
        key=uuid.uuid4().hex
        code,message=request('/api/v1/conversations/'+conversation+'/messages',{'clientMessageId':key,'text':'Kiểm tra AI và realtime APK 2.1 (dữ liệu demo).'},producer)
        check('chat persisted through API',code==201)
        deadline=time.monotonic()+8;delivered=False
        while time.monotonic()<deadline and not delivered:
            for frame in frames(ws):
                if frame.get('target')=='MessageCreated' and frame['arguments'][0]['id']==message['id']:delivered=True
        check('chat delivered on actual WSS',delivered)
    for token in (producer,consumer,trader):request('/api/v1/auth/logout',token=token,method='POST')
    report['status']='PASS'
except Exception as error:
    report['status']='FAIL';report['errorType']=type(error).__name__;raise
finally:
    report['finishedUtc']=datetime.datetime.now(datetime.timezone.utc).isoformat()
    (ROOT/'docs/ai-https-e2e.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf8')
    print(json.dumps({'status':report['status'],'checks':len(checks),'receipt':'server/docs/ai-https-e2e.json'}))
