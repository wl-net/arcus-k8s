# Unauthorized Access Attempt

Severity **warning** · group Service Health · fires as soon as client-bridge refuses a session's request: a place, person or role it may not use, or no place chosen yet.
Rule `unauthorized-access` in [`config/grafana/alerting.yaml`](../../config/grafana/alerting.yaml).

## What it means

client-bridge checks every request a logged-in app or web session sends
(arcusplatform's `RoleAuthorizer`) and counts each refusal by reason; the
alert carries the reason. api-bridge checks API keys another way and counts
nothing, so the job is always client-bridge.

| Reason | The session sent | Usually |
|---|---|---|
| `noplace` | a request before `sess:SetActivePlace`. Every login and session restore starts with no place, and only a short list of requests (invitations, address validation, ping, a person's own devices and places) is allowed before one is chosen | a client bug: it fetched something first. The new web app's profile fetch did this on every login and restore (2026-10-24) |
| `wrongplace` | a request for a place it has no access to | a stale session after the person was removed from a place, or a cached place ID; probing when many places are tried |
| `wrongperson` | a request about another person's own account (mobile devices, security answers, available places, login) | probing; the apps only ask about the signed-in person |
| `notowner` | an owner-only request (billing, adding or deleting a place) from someone who isn't the account owner. An owner who sends one before choosing a place lands here too | a member trying an owner action the app offered them |
| `supportrequest` | a notify, email, refund or credit request | never sent by the apps: a modified client or someone scripting the API |

Volume and spread tell a stale session or client bug from someone
enumerating places or persons with a valid login, which is a break-in
attempt.

## Confirm

The reason is on the alert. The notification's Panel link opens the
Authorization panel on the overview dashboard, the rate by reason over time.
For a longer window, in Grafana Explore on Prometheus:

```promql
sum by (reason) (increase(label_replace({__name__=~"bridge_authz_unauthorized_.+"},
  "reason", "$1", "__name__", "bridge_authz_unauthorized_(.+)")[6h:15s]))
```

The person and source address come from the logs, in Grafana Explore on Loki
around the alert time:

```logql
{app="client-bridge", level="warn"}
```

Arcus log lines carry `<place:…> <by:…> <ip:…>` after the thread name: the
place, the person's login and the client address of the request being
handled. client-bridge 2026.10.2 and earlier log nothing about a refusal at
info or above (only a debug line without the reason), so on those builds the
reason is all there is.

- `noplace` from many people, each right after logging in: a client bug.
- One person, one place, a few attempts: stale session.
- One source, many places or persons: probing.

## Fix

Client bug: fix the client so it sends `sess:SetActivePlace` before anything
else; the server needs nothing.

Stale session: nothing, or tell the person to sign out and in.

Probing: the session is authenticated, so the credential is compromised.
Treat the account as in [Password Changed](password-changed.md) (reset the
password, drop sessions with `./arcuscmd.sh deletepod client-bridge`), and
block the source address at the router or in Traefik if it keeps coming.

## Related alerts

- [Password Changed](password-changed.md), [Unexpected Hub Connections](unexpected-hubs.md).
