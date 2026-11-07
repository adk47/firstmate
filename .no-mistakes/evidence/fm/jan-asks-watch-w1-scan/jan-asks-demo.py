import importlib.util, json, os, tempfile, time
ROOT='/home/aaron/.no-mistakes/worktrees/72295860b10d/01M6SQ3GCKEZKEKPKCEHNX5C2D'
def load(p,n):
    s=importlib.util.spec_from_file_location(n,p); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); return m
jw=load(ROOT+'/bin/fm-jan-asks-watch-remote.py','jw')
jl=load(ROOT+'/bin/fm-jan-asks-watch-lib.py','jl')
now=time.time(); ch='C0APB2CMM7C'; parent='%.6f'%(now-2400); reply='%.6f'%(now-2300)
hist={'messages':[{'ts':parent,'user':'U0NOTSTAFF','reply_count':1,'text':'here is the proof'}]}
thr={'messages':[{'ts':parent,'user':'U0NOTSTAFF','text':'here is the proof'},
                 {'ts':reply,'thread_ts':parent,'user':'U038BM16T7W','subtype':'file_share','text':'also review the proof for the user 12345'}]}
def api(token,method,timeout=20,**p):
    if method in ('conversations.list','users.conversations'): return {'ok':True,'channels':[{'id':ch,'name':'credit-verification'}]}
    if method=='conversations.history': return {'ok':True,'messages':list(hist['messages'])}
    if method=='conversations.replies': return {'ok':True,'messages':list(thr['messages'])}
    return {'ok':True}
jw.api=api
tmp=tempfile.mkdtemp(); env=os.path.join(tmp,'e.env'); open(env,'w').write('MUSO_SLACK_BOT_TOKEN_OPERATIONS=x\n')
cfg=jw.build_config(jw.parse_args(['--env-file',env,'--state',os.path.join(tmp,'s'),'--channels','credit-verification','--grace-min','30']))
st=jw.load_state(cfg.state)
r=jw.scan(cfg,st,time.time())
print('SCAN RESULT (durable queue handed to firstmate):')
print(json.dumps({'ok':r['ok'],'queue':r['queue'],'gaps':r['gaps']},indent=2))
print('\nLEDGER LINE WRITTEN FOR THE ASK:')
line=jl.ask_line(r['queue'][0],int(time.time()))
print(line)
opened,resolved,order=jl.parse_ledger([line])
print('\nLEDGER REPARSE -> opened:',list(opened),'resolved:',resolved)
print('\nSECOND POLL (ask already filed, not duplicated):')
r2=jw.scan(cfg,st,time.time())
print(json.dumps({'queue':r2['queue']},indent=2))
