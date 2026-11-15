"""Read-only OVH inventory: GET only. Lists each dedicated server with its
reverse name, commercial range, rack, renewal date, lifecycle flags and the
recurring price OVH's /services API reports. No write call is made."""
import sys, json, datetime, concurrent.futures as cf
import os
from ovh import Client  # official package; credentials file is read, never printed
env = {}
for line in open(os.path.expanduser("~/.config/muso/ovh-api.env")):
    line = line.strip()
    if line.startswith("export "):
        k, _, v = line[7:].partition("=")
        env[k] = v
c = Client(endpoint="ovh-us", application_key=env["OVH_APP_KEY"],
           application_secret=env["OVH_APP_SECRET"], consumer_key=env["OVH_CONSUMER_KEY"])
names = c.get("/dedicated/server")
def one(n):
    row = {"service": n}
    try:
        d = c.get(f"/dedicated/server/{n}")
        row.update(reverse=d.get("reverse"), range=d.get("commercialRange"), rack=d.get("rack"),
                   dc=d.get("datacenter"), state=d.get("state"),
                   node=(d.get("iam") or {}).get("displayName"))
        s = c.get(f"/dedicated/server/{n}/serviceInfos")
        row.update(expiration=s.get("expiration"), status=s.get("status"), creation=s.get("creation"),
                   engagedUpTo=s.get("engagedUpTo"), renew=s.get("renew"), serviceId=s.get("serviceId"))
        try:
            sv = c.get(f"/services/{s['serviceId']}")
            b = sv.get("billing", {})
            row.update(price=(b.get("pricing") or {}).get("price"), priceInterval=(b.get("pricing") or {}).get("interval"),
                       nextBilling=b.get("nextBillingDate"), lifecycle=(b.get("lifecycle") or {}).get("current"),
                       engagement=b.get("engagement"), planCode=(b.get("plan") or {}).get("code"),
                       invoiceName=(b.get("plan") or {}).get("invoiceName"))
        except Exception as e:
            row["services_err"] = str(e)[:120]
    except Exception as e:
        row["err"] = str(e)[:160]
    return row
with cf.ThreadPoolExecutor(8) as ex:
    rows = list(ex.map(one, names))
print(json.dumps({"run_at_utc": datetime.datetime.now(datetime.timezone.utc).strftime("%FT%TZ"), "count": len(rows), "servers": rows}, indent=1, default=str))
