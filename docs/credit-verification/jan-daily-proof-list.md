# Jan's daily proof list

Every morning at 08:00 CET you get a Slack message from the operations bot. It lists the claims
where the document sent in looks like it proves the credit. Nothing on the list is decided yet.
The list approves nothing, and nothing is sent to any customer.

Each line is one claim: the track, the person, the role, the kind of document, who issued it,
a link to the document (or the filing number when there is no link), and the request number.

1. Open the document from the link.
2. Check that it names the track, the person and the role, and that it looks like a real
   document.
3. Go to Muso admin, Credit requests, and find the request by its number.
4. Approve or reject it yourself. That records your decision.

Rules:
- One request at a time. Never in bulk.
- If a document looks wrong, reject it, or leave it and tell Ops.
- If a line has no link, tell Ops the filing number and wait for the document.
- If there is more than one message, they are parts of the same list. If the last message says
  how many more are not shown, they come on the next day's list.
- A message that says "nothing to review today" means the list ran and was empty.
- No message by 09:00 CET means the list did not run. Tell Ops.

To stop the list, ask Ops to switch it off.
