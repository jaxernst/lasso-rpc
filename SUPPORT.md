# Support

Lasso RPC is an open source project maintained on a best-effort basis. There is
no guaranteed response time or production support SLA for this repository.

## Start here

- Follow the [Quick Start](README.md#quick-start) for a first installation.
- Use the [migration guide](docs/MIGRATION.md) when replacing a direct provider
  URL or an existing RPC gateway.
- Check [Troubleshooting](README.md#troubleshooting),
  [Deployment](docs/DEPLOYMENT.md), and [Configuration](docs/CONFIGURATION.md).
- Check existing [issues](https://github.com/jaxernst/lasso-rpc/issues) before
  filing a new one.

Use the repository's issue forms for reproducible Core bugs, operational help,
documentation problems, and feature proposals. Questions about Lasso Cloud
accounts, billing, or hosted service operation belong to the hosted product,
whose documentation is at <https://docs.lasso.sh>.

## Useful diagnostic evidence

Include the smallest redacted example that reproduces the problem:

- Lasso version or exact Git commit and installation method;
- operating system, architecture, Elixir/OTP versions when running from source;
- route, chain, JSON-RPC method, and HTTP or WebSocket transport;
- expected and observed behavior, including the complete safe-to-share error;
- a minimal profile with credentials, tokens, private URLs, and customer data
  removed;
- relevant logs and an approximate timestamp with time zone; and
- whether the behavior reproduces against one upstream directly.

Do not post provider credentials, client tokens, cookies, private endpoints, or
unredacted request data. A passing `/api/health` response establishes application
health; it does not establish upstream RPC availability, so include a bounded RPC
probe when that distinction matters.

## Security reports

Do not open a public issue for a suspected vulnerability. Follow the private
reporting instructions in [SECURITY.md](SECURITY.md).
