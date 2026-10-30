import datetime,json,re,time
from android_ui import adb,state,label,login,logout,screenshot,ROOT

checks=[]
def check(name,passed):
    checks.append({'check':name,'pass':bool(passed)})
    assert passed,name
def memory():
    text=adb('shell','dumpsys','meminfo','vn.mangodemo.mango_offline').decode(errors='replace')
    match=re.search(r'TOTAL PSS:\s*(\d+)',text)
    return int(match.group(1)) if match else None

try:
    # Admin was signed in using the release APK, then a real process restart.
    adb('shell','am','force-stop','vn.mangodemo.mango_offline')
    adb('shell','am','start','-n','vn.mangodemo.mango_offline/.MainActivity')
    time.sleep(1.5)
    check('Keystore session survives process restart', any('Quản trị demo FruitVision' in label(n) for n in state()))
    screenshot('admin-restored')
    logout()
    memory_by_role={}
    for role,title,nav in [('producer','Nhà sản xuất','Tin của tôi'),('trader','Thương lái','Nguồn cung'),('consumer','Người tiêu dùng','Khám phá')]:
        login(role)
        labels=[label(n) for n in state()]
        check(role+' receives server-backed role UI',any(title in l for l in labels) and any(nav in l for l in labels))
        check(role+' has no admin review action',not any('Quản trị hồ sơ' in l for l in labels))
        memory_by_role[role]=memory()
        logout()
    receipt={'atUtc':datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'device':'existing HN_Final_API30 emulator-5554/API30/1536MiB/2CPU/540x960',
        'build':'actual release 2.0.0+6000 x86_64','backend':'public HTTPS temporary tunnel',
        'checks':checks,'totalPssKiB':memory_by_role,'allPassed':True,
        'limits':'Emulator, not physical device; MFA and registration/review separately verified by widget/session and actual HTTPS API tests.'}
    (ROOT/'verification/android-ui-smoke.json').write_text(json.dumps(receipt,ensure_ascii=False,indent=2),encoding='utf8')
    print('PASS release emulator4roles, Keystore persistence, role UI, logout; receipt saved')
except Exception:
    (ROOT/'verification/android-ui-partial.json').write_text(json.dumps({'checks':checks,'allPassed':False},indent=2),encoding='utf8')
    raise
