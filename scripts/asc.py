import json,base64,time,subprocess,sys,urllib.request
# Tiny App Store Connect API client: python3 scripts/asc.py GET /v1/apps
# Reads ASC_KEY_ID / ASC_ISSUER_ID from ~/.appstoreconnect/yui.env.
import os
env=dict(l.strip().split("=",1) for l in open(os.path.expanduser("~/.appstoreconnect/yui.env")) if "=" in l)
KID=env["ASC_KEY_ID"]; ISS=env["ASC_ISSUER_ID"]
KEY=f"/Users/urzas/.appstoreconnect/private_keys/AuthKey_{KID}.p8"
b=lambda d: base64.urlsafe_b64encode(d).rstrip(b"=")
h=b(json.dumps({"alg":"ES256","kid":KID,"typ":"JWT"}).encode()); now=int(time.time())
p=b(json.dumps({"iss":ISS,"iat":now,"exp":now+900,"aud":"appstoreconnect-v1"}).encode())
der=subprocess.run(["openssl","dgst","-sha256","-sign",KEY],input=h+b"."+p,capture_output=True).stdout
# DER ECDSA -> raw r||s
i=2+(1 if der[1]>=0x80 else 0)
assert der[i]==2; rl=der[i+1]; r=der[i+2:i+2+rl]; j=i+2+rl; sl=der[j+1]; s=der[j+2:j+2+sl]
sig=r.lstrip(b"\0").rjust(32,b"\0")+s.lstrip(b"\0").rjust(32,b"\0")
tok=(h+b"."+p+b"."+b(sig)).decode()
method,path=sys.argv[1],sys.argv[2]; data=sys.argv[3].encode() if len(sys.argv)>3 else None
req=urllib.request.Request("https://api.appstoreconnect.apple.com"+path,data=data,method=method,headers={"Authorization":"Bearer "+tok,"Content-Type":"application/json"})
try: print(urllib.request.urlopen(req).read().decode())
except urllib.error.HTTPError as e: print(e.code,e.read().decode())
