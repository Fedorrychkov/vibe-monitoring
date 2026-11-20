# Quickping desktop integration

In Settings, enter your Quickping HTTPS origin and choose **Sign in with Quickping**. The system browser opens the server's consent page. After normal sign-in (including MFA, when configured), approve read-only access. VibeMonitoring never receives your password or browser session cookies.

This requires a Quickping server update. A server without these endpoints cannot be connected yet; the app does not fall back to extracting browser cookies or copying full-access site tokens. This is an Authorization Code flow with PKCE S256, not an MCP connection.

## Contract

- Client: `vibe-monitoring`, redirect URI: `dev.vibemonitoring.app://quickping/callback`.
- Scope: `monitoring:read`, exclusively on the integration's monitoring/revocation endpoints.
- Browser: `GET /integrations/vibe-monitoring` with `response_type=code`, `client_id`, `redirect_uri`, `scope`, `state`, `code_challenge`, `code_challenge_method=S256`.
- Explicit consent: same-origin authenticated `POST /api/v1/integrations/authorize`. Redirects back with a one-use 60-second code and the original state, or `error=access_denied`.
- Exchange: `POST /api/v1/integrations/token`, JSON `{grant_type, client_id, redirect_uri, code, code_verifier}`. Returns `{access_token, token_type:"Bearer", scope:"monitoring:read", expires_in}`. Current grants expire in 30 days. No refresh token or client secret.
- Read: `GET /api/v1/integrations/monitoring`, bearer token, JSON below.
- Disconnect: `POST /api/v1/integrations/revoke`, bearer token. The user can also revoke connections at `/integrations` in the browser, including after losing access to the Mac.

```json
{
  "sampledAt": "2026-11-20T14:00:00.000Z",
  "truncated": false,
  "services": [{
    "id": "example-service",
    "name": "Orbit API",
    "status": "degraded",
    "lastCheckedAt": "2026-11-20T13:59:55.000Z",
    "latencyMs": 142,
    "openIncidents": [{"id":"example-incident","reason":"slow","openedAt":"2026-11-20T13:50:00.000Z"}]
  }]
}
```

Service states: `operational`, `degraded`, `down`, `pending`, `unknown`. Results older than the server's allowed check interval are `unknown`, never silently green. At most 100 services and 5 open incidents per service are returned. `truncated=true` must be shown when more services exist. No target URLs, check credentials or unrelated account data are returned.

The app polls every 30 seconds, retains previous data on failure, and labels reports older than two minutes stale. Local network failure does not turn remote services into `down`. The API client accepts HTTPS (loopback HTTP is allowed for local development), rejects redirects and limits response bodies to 1 MiB.

## Security boundaries

The server stores hashes of opaque codes/tokens. Code consumption must be atomic and include expiry and PKCE verification. A browser login JWT and a desktop grant are not interchangeable. Check token scope, expiry, revocation and current user status on each read. Owner filtering belongs in database queries, including revocation; it must not depend on a client-provided owner ID.

Consent/revocation forms require the configured site Origin. Set Quickping's existing `NEXT_PUBLIC_SITE_URL` to its actual external origin. Authorization, token and monitoring responses must be `Cache-Control: no-store`. Tokens never appear in a browser URL.

A local disconnect deletes Keychain access immediately and attempts server revocation. Offline revocation cannot be guaranteed; the UI points to the server's Connected apps page. Ad-hoc app updates may cause macOS to request Keychain access again.

Browser/Keychain interaction still needs a live check after deploying the matching backend. Synthetic HTTP tests and an isolated MongoDB integration test cover the protocol and access controls, not that deployment.

References: [OAuth for native apps](https://www.rfc-editor.org/rfc/rfc8252), [PKCE](https://www.rfc-editor.org/rfc/rfc7636), [ASWebAuthenticationSession](https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession).
