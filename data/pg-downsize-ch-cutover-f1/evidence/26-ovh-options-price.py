"""Read-only (GET only). For the boxes this plan names: base plan price + every option
service price (/services/{id}/options), so the monthly figure is the plan plus its options,
pre-tax. Also resolves the three servers with no OVH display name to a k3s node by matching
the server's public IP against `kubectl get node -o wide` (IPs are compared, never stored)."""
import os, sys, json, datetime, subprocess, concurrent.futures as cf
from ovh import Client
env = {}
for line in open(os.path.expanduser("~/.config/muso/ovh-api.env")):
    line = line.strip()
    if line.startswith("export "):
        k, _, v = line[7:].partition("="); env[k] = v.strip().strip('"').strip("'")
c = Client(endpoint="ovh-us", application_key=env["OVH_APP_KEY"],
           application_secret=env["OVH_APP_SECRET"], consumer_key=env["OVH_CONSUMER_KEY"])
inv = json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "25-ovh-servers.json")))["servers"]
kn = subprocess.run(["ssh", "-o", "BatchMode=yes", "root@135.148.169.37",
                     "kubectl get nodes -o json | jq -r '.items[] | [.metadata.name, (.status.addresses|map(.address)|join(\",\")), (.metadata.labels[\"node.muso.ai/analytics-ch\"] // \"\"), (.metadata.annotations[\"flannel.alpha.coreos.com/public-ip\"] // \"\")] | @tsv'"],
                    capture_output=True, text=True).stdout.splitlines()
def one(r):
    out = {"service": r["service"], "node": r.get("node"), "range": r.get("range"), "rack": r.get("rack"),
           "base": (r.get("price") or {}).get("value"), "nextBilling": r.get("nextBilling"),
           "deleteAtExpiration": (r.get("renew") or {}).get("deleteAtExpiration"),
           "terminationDate": (r.get("engagement") or {}).get("terminationDate") if isinstance(r.get("engagement"), dict) else None}
    try:
        opts = c.get(f"/services/{r['serviceId']}/options")
        ol = []
        for o in opts:
            b = o.get("billing", {})
            ol.append({"name": (b.get("plan") or {}).get("invoiceName"), "price": ((b.get("pricing") or {}).get("price") or {}).get("value")})
        out["options"] = [o for o in ol if o["price"]]
        out["options_total"] = round(sum(o["price"] or 0 for o in ol), 2)
        out["monthly_pre_tax"] = round((out["base"] or 0) + out["options_total"], 2)
    except Exception as e:
        out["options_err"] = str(e)[:160]
    if not (r.get("node") or "").lower().startswith("node-"):
        try:
            d = c.get(f"/dedicated/server/{r['service']}")
            ips = set(c.get(f"/dedicated/server/{r['service']}/ips")) | {d.get("ip")}
            ips = {str(i).split("/")[0] for i in ips if i and ":" not in str(i)}
            out["k3s_node_by_ip"] = [l.split("\t")[0] + (" analytics-ch=" + l.split("\t")[2] if l.split("\t")[2] else "") for l in kn if any(i in l.split("\t")[1].split(",") + [l.split("\t")[3]] for i in ips)] or "no k3s node has this address"
        except Exception as e:
            out["ip_err"] = str(e)[:160]
    return out
with cf.ThreadPoolExecutor(8) as ex:
    rows = list(ex.map(one, inv))
print(json.dumps({"run_at_utc": datetime.datetime.now(datetime.timezone.utc).strftime("%FT%TZ"), "note": "prices pre-tax USD/month; OVH US adds sales tax on the invoice", "servers": rows}, indent=1, default=str))
