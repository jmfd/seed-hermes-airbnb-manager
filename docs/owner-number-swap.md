# Owner phone-number swap (move the owner's approval/conversation channel)

Move ONLY the owner's plow_chat approval channel to a NEW phone. Everything else
(Hostex account/token, properties, team, brain) stays. After the swap the owner
chats/approves on the NEW number, is recognized as owner on inbound, and approved
replies are delivered to the guest on Airbnb.

`$SC` = the seed-hermes scaffold dir (e.g. `.../seed-hermes/hermes-agent`).
`$OWNER_PROFILE` = the owner profile handle. `$PROJECT` = the compose project name.

## 0. Backup (this is the rollback path)
```bash
cp -av "$SC/data/profiles/$OWNER_PROFILE/.env" "$SC/data/profiles/$OWNER_PROFILE/.env.bak-ownerswap"
cp -av "$SC/data/profiles/$OWNER_PROFILE/pairing" "$SC/data/profiles/$OWNER_PROFILE/pairing.bak-ownerswap"
grep -E 'PLOW_CHAT_CHAT_UID' "$SC/data/profiles/$OWNER_PROFILE/.env"   # note the OLD uid
```

## 1. Re-bind plow_chat to the NEW phone (device-code)
```bash
tmux new-session -d -s owner-rebind \
  "bash $WORK/seed-hermes-plow-chat/ref/scripts/create_plow_chat_curl.sh \
   --scaffold $SC --profile $OWNER_PROFILE --display-name Owner-Swap --timeout 1800 \
   > /tmp/owner-rebind.log 2>&1"
sleep 8 && cat /tmp/owner-rebind.log    # prints: Text "Plow Activate: <CODE>" from iMessage to <NUMBER>
```
The owner sends that iMessage from the NEW phone. On verify, the helper writes the new
`PLOW_CHAT_CHAT_UID/TOKEN/HOME_CHANNEL` into `profiles/$OWNER_PROFILE/.env`.
> `--display-name` must be ONE token (no spaces). Quick codes are single-use + expire (~minutes); re-run if needed.

## 2. ⚠️ Propagate the new channel to ALL baked locations (NOT just .env)
The helper only writes `.env`. The old channel stays baked in 3 more places the runtime reads;
if you skip this, the bot mirrors approvals to the OLD channel. Replace OLD uid -> NEW uid in:
- `profiles/$OWNER_PROFILE/webhook_subscriptions.json`  (the `chat_id=` inside the prompt)
- `profiles/$OWNER_PROFILE/channel_directory.json`       (`plow_chat[].id`)
- `profiles/$OWNER_PROFILE/.env`                          (`AIRBNB_OWNER_MIRROR_SESSION_KEY=...:dm:<uid>`)
- `data/.airbnb-courier.env`                             (`AIRBNB_OWNER_MIRROR_SESSION_KEY`)
```bash
OLD=<old_chat_uid>; NEW=<new_chat_uid>
for f in "$SC/data/profiles/$OWNER_PROFILE/webhook_subscriptions.json" \
         "$SC/data/profiles/$OWNER_PROFILE/channel_directory.json" \
         "$SC/data/profiles/$OWNER_PROFILE/.env" \
         "$SC/data/.airbnb-courier.env"; do
  cp -a "$f" "$f.bak-ownerswap"; sed -i "s/$OLD/$NEW/g" "$f"
done
# sanity: Hostex token untouched
grep -c 'HOSTEX_ACCESS_TOKEN=' "$SC/data/profiles/$OWNER_PROFILE/.env"
```

## 3. ⚠️ Authorize the NEW number's identity on INBOUND (pairing)
Inbound auth is keyed by the sender's `cp_` participant id, NOT the chat uid. The NEW number is
not yet approved, so the bot replies "I don't recognize you / pairing code?" and creates a pending.
```bash
# the new number sends ANY message once -> creates a pending; then read its cp_ id:
docker exec ${PROJECT}-hermes-owner hermes -p $OWNER_PROFILE pairing list
```
Approve it. (The `hermes pairing approve` CLI uppercases the code and fails, so add the id directly:)
```bash
AP="$SC/data/profiles/$OWNER_PROFILE/pairing/plow_chat-approved.json"
PEND="$SC/data/profiles/$OWNER_PROFILE/pairing/plow_chat-pending.json"
NEWID=<cp_id_of_new_number>
python3 - "$AP" "$NEWID" <<'PY'
import json,sys,time
p,n=sys.argv[1],sys.argv[2]
d=json.load(open(p)); d[n]={"user_name":"Owner","approved_at":time.time()}
json.dump(d,open(p,"w"),indent=2)
PY
echo '{}' > "$PEND"
```
> Optional clean swap: `hermes -p $OWNER_PROFILE pairing revoke` the OLD number's cp_ ids after confirming the new one.

## 4. Restart so the runtime reloads
```bash
cd "$SC" && docker compose restart hermes-owner airbnb-courier
docker exec ${PROJECT}-hermes-owner hermes -p $OWNER_PROFILE pairing list   # new cp_ in Approved
```

## 5. Verify BOTH directions for real
- **Inbound:** the owner sends from the NEW number -> bot responds normally (does NOT ask for a pairing code).
- **Outbound to guest:** a guest message -> draft mirrored to the NEW number -> owner approves -> the reply
  must appear in the Airbnb conversation as `sender_role: host`. Confirm on Hostex itself (source of truth),
  do NOT trust the bot's "Sent" alone:
```bash
TOKEN=$(grep '^HOSTEX_ACCESS_TOKEN=' "$SC/data/profiles/$OWNER_PROFILE/.env" | cut -d= -f2)
curl -sS -H "Hostex-Access-Token: $TOKEN" -H 'User-Agent: curl/8.7.1' \
  "https://api.hostex.io/v3/conversations/<conversation_id>" \
 | python3 -c "import json,sys;[print(m['created_at'],m['sender_role'],m['content'][:70]) for m in json.load(sys.stdin)['data']['messages'][:3]]"
```
The owner-approve ship is handled by `ref/courier/ship-reply.sh` (deterministic: POST + verify-on-Hostex
before marking delivered). See CHANGELOG 0.3.0.

## Rollback
```bash
cp -av "$SC/data/profiles/$OWNER_PROFILE/.env.bak-ownerswap" "$SC/data/profiles/$OWNER_PROFILE/.env"
for f in webhook_subscriptions.json channel_directory.json; do
  cp -av "$SC/data/profiles/$OWNER_PROFILE/$f.bak-ownerswap" "$SC/data/profiles/$OWNER_PROFILE/$f"; done
cp -av "$SC/data/.airbnb-courier.env.bak-ownerswap" "$SC/data/.airbnb-courier.env"
rm -rf "$SC/data/profiles/$OWNER_PROFILE/pairing" && \
  cp -av "$SC/data/profiles/$OWNER_PROFILE/pairing.bak-ownerswap" "$SC/data/profiles/$OWNER_PROFILE/pairing"
cd "$SC" && docker compose restart hermes-owner airbnb-courier
```
> Scope: only the owner plow_chat channel + inbound identity change. Hostex/properties/team/brain untouched.
