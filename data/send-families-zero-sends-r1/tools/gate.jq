def gate:
  (.reason // "") as $r
  | if   ($r|test("c2_signed_only")) then "c2_signed_only"
    elif ($r|test("r1_receipted_in_thread")) then "r1_receipted_in_thread"
    elif ($r|test("r1_filing_class_unknown")) then "r1_filing_class_unknown"
    elif ($r|test("r1_unreadable_filing")) then "r1_unreadable_filing"
    elif ($r|test("filing_muso_ui\\)|screenshot of Muso")) then "r1_muso_ui_screenshot"
    elif ($r|test("core_notice_within_7d")) then "core_notice_within_7d"
    elif ($r|test("messaged_7d")) then "messaged_7d"
    elif ($r|test("reask|asked_90d|90 days|90d")) then "reask_lock_90d"
    elif ($r|test("no_channel")) then "no_channel"
    elif ($r|test("comm_state|R8_account_hold")) then "comm_state"
    elif ($r|test("copy|verdict")) then "copy_verdict"
    elif ($r|test("gate_timeout")) then "gate_timeout(unmeasured)"
    elif ($r|test("run_size|daily_cap")) then $r
    elif ($r|test("Intercom users|external_id")) then "intercom_identity"
    elif ($r|test("^G[0-9]")) then ($r|.[0:2]) + "_render_guard"
    else "other: " + ($r|gsub("[0-9]+";"N")|.[0:90]) end;
[.outcomes[] | {k: ((.result) + " / " + gate)}] | group_by(.k) | map({k: .[0].k, n: length}) | sort_by(-.n) | .[] | "\(.n)\t\(.k)"
