# zetachain-docker

Docker compose for Zetachain.

Meant to be used with central-proxy-docker for traefik and Prometheus remote write; use :ext-network.yml in COMPOSE_FILE inside .env in that case.

## Version

Zetachain Docker uses a "semver-ish" scheme.

First digit, major shifts in how things work. The last one was Ethereum merge. I do not expect another shift that large.
Second through fourth digit, semver.

This is zetachain-docker v0.1
