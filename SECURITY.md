# Security Policy

## Supported Versions

We support the latest published release with security updates. Upgrade older versions to the latest release before deploying.

## Reporting a Vulnerability

**Please do not open public GitHub issues for security vulnerabilities.**

To report a security vulnerability, please email: **jaxernst@gmail.com**

What to include in your report:

- Description of the vulnerability
- Steps to reproduce
- Potential impact
- Suggested fix (if any)

## Security Considerations for Self-Hosting

When deploying Lasso RPC in production, follow these security best practices:

### 1. Environment Variables & Secrets

- Keep provider credentials, `SECRET_KEY_BASE`, and `RELEASE_COOKIE` out of version control, images, and logs.
- The Compose installation uses a private `.env` file. Keep it outside web-served directories, restrict it to the operator (`chmod 600 .env`), and protect backups.
- For managed deployments, inject these environment variables through your platform's secret manager. Docker administrators can inspect container environment variables; restrict host and Docker access.
- Preserve signing and distribution secrets across restarts. Rotate credentials deliberately; cluster members must share the same distribution cookie.

### 2. Network Security

- Deploy behind a reverse proxy (nginx, Caddy, Traefik)
- Enable TLS/SSL for all external traffic
- Use firewalls to restrict access to sensitive endpoints
- Consider network isolation for internal services

### 3. Authentication & Authorization

- Lasso has no built-in client authentication for RPC, metrics, or the dashboard
- The dashboard request tester sends real upstream requests; protect dashboard access as well as RPC access
- If you add admin API endpoints, **you must implement authentication**
- Recommended auth methods:
  - OAuth2 via reverse proxy (Cloudflare Access, Auth0, etc.)
  - mTLS for machine-to-machine communication
  - API key validation middleware
  - Network-level isolation (VPN, internal-only access)

### 4. RPC Provider Security

- Vet upstream RPC providers before adding them
- Use API keys for provider authentication when available
- Monitor provider responses for unexpected behavior
- Implement rate limiting at the proxy level

### 5. Docker Security

- Run containers as non-root user
- Keep base images updated
- Scan images for vulnerabilities
- Use read-only filesystems where possible

### 6. Monitoring & Observability

- Enable structured logging
- Monitor for unusual traffic patterns
- Set up alerts for circuit breaker trips
- Track rate limit violations

### 7. Rate Limiting

- Enforce client or per-IP request limits at the reverse proxy
- Profile `rps_limit` controls the dashboard tester; `burst_limit` is metadata. These settings do not enforce incoming RPC quotas in OSS
- Monitor for abuse patterns

## Known Security Considerations

### No Built-in Authentication

Lasso RPC does **not** include built-in authentication. The dashboard is designed for internal use or trusted environments. If you expose Lasso publicly, you **must**:

- Implement authentication at the reverse proxy level, OR
- Use network-level isolation (VPN, internal network only), OR
- Deliberately allow public access, including visible metrics and the ability to generate upstream traffic through RPC and the dashboard tester

## Disclosure Policy

When a security issue is reported and confirmed:

1. We will develop a fix and test it internally
2. We will coordinate with the reporter on disclosure timing
3. We will release a patch and publish a security advisory
4. We will credit the reporter (unless they prefer anonymity)

## Security Updates

Subscribe to security advisories:

- Watch this repository's security advisories on GitHub
- Follow releases for security patch notes

## Contact

For security concerns: jaxernst@gmail.com
For general questions: Open a GitHub issue
