"""Release UI acceptance helpers. Every tap is resolved from current UI XML."""
import datetime,json,re,time,urllib.request,urllib.error,uuid,sys
from android_ui import adb,state,label,tap,find_tap,screenshot,ROOT,login

def texts():return [label(n) for n in state() if label(n)]
def tap_text(text,scroll=False):
    for _ in range(6 if scroll else 1):
        nodes=state();matches=[n for n in nodes if text in label(n)]
        if matches:
            match=min(matches,key=lambda n:(n.get('clickable')!='true',len(label(n))))
            tap(match);return
        if scroll:adb('shell','input','swipe','270','650','270','480','450')
    raise RuntimeError('Missing current UI label: '+text)
def wait_text(expected,seconds=20):
    deadline=time.monotonic()+seconds
    while time.monotonic()<deadline:
        current=texts()
        if any(expected in text for text in current):return current
        time.sleep(.4)
    raise RuntimeError('UI deadline waiting for: '+expected+'; last='+repr(current))
def picker(name):
    current=texts()
    if not any(name in t for t in current):
        nodes=state();drawer=[n for n in nodes if label(n) in ('Show roots','Hiển thị gốc','Show navigation drawer')]
        if drawer:tap(drawer[0])
        current=texts()
        if any('Downloads' in t for t in current):tap_text('Downloads')
        elif any('Tải xuống' in t for t in current):tap_text('Tải xuống')
        else:raise RuntimeError('Downloads root not visible; '+repr(current))
    selected=False
    for _ in range(18):
        adb('shell','input','keyevent','61')
        nodes=state();targets=[n for n in nodes if label(n).startswith(name)]
        focused=[n for n in nodes if n.get('focused')=='true']
        for focus in focused:
            if focus.get('resource-id','').endswith('item_root') or label(focus).startswith(name):
                a=list(map(int,re.findall(r'\d+',focus['bounds'])))
                if any((lambda b:a[0]<=b[0] and a[1]<=b[1] and a[2]>=b[2] and a[3]>=b[3])(list(map(int,re.findall(r'\d+',target['bounds'])))) for target in targets):
                    adb('shell','input','keyevent','66');selected=True;break
        if selected:break
    if not selected:raise RuntimeError('Exact media not focused in DocumentsUI')
def choose(kind):
    tap_text('Chọn ảnh' if kind=='image' else 'Chọn video',scroll=True)
    picker('FruitVision-2.1-demo.png' if kind=='image' else 'FruitVision-2.1-demo.mp4')
    tap_text('Gửi phân tích',scroll=True)
    wait_text('Kết quả phân tích')
def wait_result(kind,seconds=170):
    deadline=time.monotonic()+seconds;observed=[]
    while time.monotonic()<deadline:
        current=texts();joined='\n'.join(current)
        if 'Không hoàn tất' in joined or 'Đã hủy' in joined:raise RuntimeError('AI job did not complete: '+joined)
        observed.extend(re.findall(r'(?:\d+%|Đang phân tích|Đang chờ xử lý)',joined))
        if 'Hoàn tất' in joined:
            screenshot('2.1-'+kind+'-completed')
            return {'kind':kind,'observedStatuses':list(dict.fromkeys(observed)),'completedLabels':current,
                    'atUtc':datetime.datetime.now(datetime.timezone.utc).isoformat()}
        time.sleep(1)
    raise RuntimeError('AI result UI deadline')
def save_report(part,result):
    p=ROOT/'verification/2.1/android-ai-ui.json';p.parent.mkdir(parents=True,exist_ok=True)
    report=json.loads(p.read_text(encoding='utf8')) if p.exists() else {'device':'HN_Final_API30/emulator5554','apk':'2.1.0+6001 release','actualApi':'public HTTPS/WSS; PC AI'}
    report[part]=result;p.write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf8')
if __name__=='__main__':
    mode=sys.argv[1]
    if mode=='image':
        tap_text('AI');wait_text('Chọn ảnh');screenshot('2.1-ai-ready')
        choose('image');save_report('image',wait_result('image',35));print('PASS real release UI image upload and PC result')
    elif mode=='video':
        adb('shell','input','keyevent','4');wait_text('Chọn video');choose('video')
        save_report('video',wait_result('video'));print('PASS real release UI full video upload and PC result')
    elif mode=='state':print(json.dumps(texts(),ensure_ascii=False,indent=2))
