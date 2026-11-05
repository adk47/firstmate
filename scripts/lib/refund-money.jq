# refund-money.jq - THE one place a refund amount becomes a number a customer reads.
#
# QA 2026-11-04 (zero-decimal finding): Stripe amounts are MINOR units and the minor unit is a property of the CURRENCY,
# not of money in general. The send path divided every amount by 100, so a 500 JPY refund would have been rendered as
# "5.00 JPY" - a false financial confirmation to a customer, produced by our own code, with the ledger recording it as
# verified. Stripe's rule (docs.stripe.com/currencies): "Currencies are two-decimal currencies unless otherwise
# specified", with a zero-decimal list and a three-decimal list. ISK and UGX are zero-decimal CURRENCIES that Stripe
# still expects in a two-decimal representation (5 ISK is `500`), so they are 2 here on purpose.
#
# Integer string math, never floats: a note about money does not round a customer's refund, and `(x / 100)` in jq goes
# through a double. Both jq programs in scripts/intercom-verify-request.sh include this module, so the comparison the
# gate refuses on and the sentence it renders can never drift apart - there is exactly one formatter.
#
#   refund_money(1250; "usd") -> "12.50"      refund_money(500; "jpy")  -> "500"
#   refund_money(5;    "usd") -> "0.05"       refund_money(1234; "kwd") -> "1.234"
#   refund_money(500;  "isk") -> "5.00"       refund_money(0; "usd")    -> "0.00"

def refund_cur_exp($c):
  ($c | ascii_upcase) as $u
  | if (["BIF", "CLP", "DJF", "GNF", "JPY", "KMF", "KRW", "MGA", "PYG", "RWF", "VND", "VUV", "XAF", "XOF", "XPF"]
        | index($u)) != null then 0
    elif (["BHD", "IQD", "JOD", "KWD", "LYD", "OMR", "TND"] | index($u)) != null then 3
    else 2 end;

def refund_money($minor; $c):
  refund_cur_exp($c) as $e
  | ($minor | tostring) as $s
  | (if ($s | length) <= $e then ("0" * ($e - ($s | length) + 1)) + $s else $s end) as $p
  | if $e == 0 then $p
    else ($p[0:($p | length) - $e]) + "." + ($p[($p | length) - $e:]) end;
