"""Owned HTTPS replay-content binding regression, no credentials in output."""
import json,pathlib,time,urllib.request,urllib.error,uuid
root=pathlib.Path(__file__).resolve().parents[1]
base=json.loads((root/'.local/tunnel-state.json').read_text(encoding='utf-8-sig'))['publicUrl']
password=json.loads((root/'.local/runtime.json').read_text(encoding='utf-8-sig'))['Demo']['Password']
def call(path,body=None,token=None,content_type='application/json',key=None):
    headers={'Content-Type':content_type}
    if token:headers['Authorization']='Bearer '+token
    if key:headers['X-Client-Request-Id']=key
    try:response=urllib.request.urlopen(urllib.request.Request(base+path,data=body,headers=headers),timeout=20)
    except urllib.error.HTTPError as error:response=error
    with response:
        data=response.read();return response.status,json.loads(data) if data else None
code,session=call('/api/v1/auth/login',json.dumps({'email':'producer@fruitvision.test','password':password}).encode())
assert code==200;token=session['accessToken']
data=(root.parent/'app/android/app/src/main/assets/demo_multi_mango.png').read_bytes();key=uuid.uuid4().hex
code,job=call('/api/v1/ai/jobs?mediaType=image',data,token,'image/png',key);assert code==202
code,same=call('/api/v1/ai/jobs?mediaType=image',data,token,'image/png',key);assert code==200 and same['id']==job['id']
different=data[:-1]+bytes([data[-1]^1]);code,_=call('/api/v1/ai/jobs?mediaType=image',different,token,'image/png',key);assert code==409
for _ in range(15):
    code,current=call('/api/v1/ai/jobs/'+job['id'],token=token)
    if current['status']=='Succeeded':break
    time.sleep(.5)
assert current['status']=='Succeeded'
assert not (root/'.local/ai'/job['id'].replace('-','')/'input.png').exists()
code,same=call('/api/v1/ai/jobs?mediaType=image',data,token,'image/png',key);assert code==200 and same['id']==job['id']
call('/api/v1/auth/logout',b'',token)
receipt={'status':'PASS','sameBytesSameKey200':True,'changedBytesSameKey409':True,
         'retryAfterInputCleanup200':True,'originalInputRemoved':True,'jobId':job['id'],'baseUrl':base}
(root/'docs/ai-retry-https.json').write_text(json.dumps(receipt,indent=2),encoding='utf8')
print('PASS actual HTTPS same-byte replay, different-byte409, cleanup and retry-after-cleanup')
