import json, pathlib, re, shlex, subprocess, sys, time, xml.etree.ElementTree as ET
ROOT=pathlib.Path(__file__).resolve().parents[1]
ADB=pathlib.Path.home()/'AppData/Local/Android/Sdk/platform-tools/adb.exe'
PACKAGE='vn.mangodemo.mango_offline'
def adb(*args, timeout=15):
    return subprocess.run([str(ADB),'-s','emulator-5554',*args],capture_output=True,check=True,timeout=timeout).stdout
def state():
    path='/sdcard/fv-client-ui-'+str(time.monotonic_ns())+'.xml'
    try:
        result=adb('shell','uiautomator','dump',path)
        if b'UI hierchary dumped to:' not in result and b'UI hierarchy dumped to:' not in result:
            raise RuntimeError('UI snapshot did not finish; never use stale XML')
        xml=adb('shell','cat',path)
        return [dict(n.attrib) for n in ET.fromstring(xml).iter('node')]
    finally:
        adb('shell','rm','-f',path)
def label(n): return n.get('text','') or n.get('content-desc','')
def tap(n):
    nums=list(map(int,re.findall(r'\d+',n['bounds'])))
    x,y=(nums[0]+nums[2])//2,(nums[1]+nums[3])//2
    adb('shell','input','tap',str(x),str(y))
def find_tap(text,scroll=False):
    for _ in range(4 if scroll else 1):
        nodes=state(); matches=[n for n in nodes if text in label(n) and n.get('clickable')=='true']
        if matches: tap(min(matches,key=lambda n:len(label(n))));return
        if scroll:adb('shell','input','swipe','270','670','270','280','180')
    raise RuntimeError('Missing clickable '+text+'; labels='+repr([label(n) for n in nodes if label(n)]))
def type_text(value):
    adb('shell','input','text',shlex.quote(value.replace(' ','%s')))
def screenshot(name):
    (ROOT/'verification'/f'{name}.png').write_bytes(adb('exec-out','screencap','-p'))
def login(role):
    rows=json.loads((ROOT.parent/'server/.local/demo-accounts.json').read_text(encoding='utf-8-sig'))
    row=next(r for r in rows if r['Email']==role+'@fruitvision.test')
    nodes=state();fields=[n for n in nodes if n.get('class')=='android.widget.EditText']
    assert len(fields)==2,[(n.get('class'),label(n)) for n in nodes if label(n)]
    tap(fields[0]);type_text(row['Email'])
    adb('shell','input','keyevent','61');type_text(row['Password']);adb('shell','input','keyevent','4')
    find_tap('Đăng nhập',scroll=True)
    time.sleep(1.5)
    nodes=state();assert any('Tài khoản' in label(n) for n in nodes),[label(n) for n in nodes if label(n)]
    screenshot(role)
    print('LOGIN PASS',role)
def logout():
    find_tap('Tài khoản');find_tap('Đăng xuất',scroll=True)
    time.sleep(.3)
    assert any('Chào mừng' in label(n) for n in state())
    print('LOGOUT PASS')
if __name__=='__main__':
    action=sys.argv[1]
    if action=='state': print(json.dumps([{k:n[k] for k in ('class','text','content-desc','clickable','bounds') if k in n} for n in state() if label(n) or n.get('class')=='android.widget.EditText'],ensure_ascii=False,indent=2))
    elif action=='login':login(sys.argv[2])
    elif action=='logout':logout()
    elif action=='shot':screenshot(sys.argv[2])
