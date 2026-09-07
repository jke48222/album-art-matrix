import requests,re,json,concurrent.futures,pathlib,html
R=pathlib.Path(__file__).parent
asins=['B084Q4W1PW','B0981YTS3D','B072BYGKZZ','B0CF1N8FM8','B0FGV5FCBN','B005PUC4KE','B0DVK1V768','B0CMR2RY9Y','B07RSRBZZD','B07426WCLM','B0DX5HCDHM','B0DSCGW488','B081VD1NNT']
def fetch(a):
 try:
  t=requests.get('https://www.amazon.com/dp/'+a,timeout=20).text
  (R/(a+'.html')).write_text(t)
  clean=re.sub('<(script|style)\\b[^>]*>.*?</\\1>','',t,flags=re.S|re.I)
  clean=html.unescape(re.sub('<[^>]+>',' ',clean));clean=re.sub(r'\s+',' ',clean)
  (R/(a+'.txt')).write_text(clean)
  pics=list(dict.fromkeys(re.findall(r'"hiRes"\s*:\s*"([^"]+)"',t)))
  (R/(a+'-images.json')).write_text(json.dumps(pics))
  snippets=[]
  for m in re.finditer(r'Product Dimensions|Mounting Size|Total Size|Overall Size|Item Dimensions|inch|mm',clean,re.I):
   q=clean[max(0,m.start()-80):m.start()+180]
   if len(snippets)<10: snippets.append(q)
  return {'asin':a,'bytes':len(t),'images':len(pics),'dimensions':snippets}
 except Exception as e:return {'asin':a,'error':str(e)}
with concurrent.futures.ThreadPoolExecutor(max_workers=8) as ex:
 data=list(ex.map(fetch,asins))
(R/'amazon-extract.json').write_text(json.dumps(data,indent=2));print(json.dumps(data,indent=2))
