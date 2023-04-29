# certificate-manager
Manage certificates for Docker containers automatically, issuing and renewing them via the ACME protocol (Let's Encrypt).

## Getting Started

Let's create a simple docker-compose.yml file to get started.

```yaml
services:
  app:
    image: wordpress:latest
	labels:
	  sh.acme.domains: example.com,www.example.com
	  sh.acme.reload_command: apache2ctl -k graceful
	  sh.acme.certificate_path: /etc/ssl/certs
  mail:
    image: axigen:latest
	labels:
	  sh.acme.domains: mail.example.com
	  sh.acme.reload_command: docker compose restart mail
	  sh.acme.certificate_path: /opt/axigen/data/certs
	  sh.acme.deploy: pem
  acme:
	image: ghcr.io/nbish11/certificate-manager:latest
	depends_on:
	  - app
	  - mail
	volumes:
	  - /var/run/docker.sock:/var/run/docker.sock:ro
	  - acme:/acme.sh
	environment:
	  ACME_MAIN_DOMAIN: example.com
	  ACME_EMAIL: me@example.com
	  ACME_DNS_PROVIDER: cloudflare
	  CF_Key: <your cloudflare api key>
	  CF_Email: <your cloudflare email address>
volumes:
  acme:
```

That's it!

The above docker compose file will create 3 services: "app", "mail", and "acme". The "app" service is a WordPress container, and the "mail" service is an Axigen mail server container. The "acme" service is the certificate manager, which will automatically issue, renew, and deploy certificates for the "app" and "mail" services.

Axigen requires the certificate, private key, and CA chain to be concatonated as one file in the PEM format, so we set the "sh.acme.deploy" label to "pem" for the "mail" service. Apache requires the certificates as separate ccertificate and key files in the PEM format, and as this is the default, we do not need to set the "sh.acme.deploy" label for the "app" service.

The "acme" service depends on the "app" and "mail" services, so that the certificate manager will wait for the containers to start before attempting to deploy certificates. The "acme" service also mounts the Docker socket, so that it can communicate with the Docker daemon, and the "acme" service mounts a volume to store the acme.sh data. In reality, the wordpress and axigen containers should also mount their own volumes to persist their data, but we are trying to keep things simple for this example.

Apache can easily be restarted from within the container, so we set the "sh.acme.reload_command" label to "apache2ctl -k graceful" for the "app" service. Restarting the Axigen container is a little more complicated (and outside the scope of this example), so we set the "sh.acme.reload_command" label to "docker compose restart mail" for the "mail" service. (In practice, you would not restart an entire mail server during production.) The certificate manager will detect that the command starts with "docker", and will run the command on the host, rather than inside the container.

## Environment variables

### Required

- `ACME_MAIN_DOMAIN` - The main/primary domain which you would have registered to represent you organisation. A certificate is always issued for this domain, but will only be deployed to containers that have this domain in their "sh.acme.domains" label.
- `ACME_EMAIL` - Email address to use for registration and recovery contact.
- `ACME_DNS_PROVIDER` - DNS provider to use for DNS-01 challenge. See acme.sh documentation, [DNS Providers 1](https://github.com/acmesh-official/acme.sh/wiki/dnsapi) and [DNS Providers 2](https://github.com/acmesh-official/acme.sh/wiki/dnsapi2) for supported providers.

In addition, you must set the required environment variables for the DNS provider you are using, which are given in the DNS Providers lists.

### Optional

- `ACME_STAGING` - Set to "true" to use the staging server for the chose CA. This is useful for testing, as the staging server does not have rate limits, and does not issue valid certificates. The default value is "false".
- `ACME_CA` - The CA to use. The default value is "letsencrypt".

## Docker labels

- `sh.acme.domains` - A comma-separated list of domains that you want the certificate manager to manage for this container. The certificate manager will issue a certificate for each domain in the list, and deploy it to the container (one certificate per domain).
- `sh.acme.reload_command` - The command to run after all certificates have been deployed to the container. If the command starts with "docker" (either in quotes or not) the certificate manager will run the docker command on the host, allowing you to issue commands like `docker restart` (the container id will be appended to the command). If the command does not start with "docker", the certificate manager will run the command inside the container, executing with the "/bin/sh" shell. This is useful if you want to reload a service from within the container, such as Apache `apachectl -k graceful`. Do not provide a label if you do not want the certificate manager to run a command after deploying certificates.
- `sh.acme.certificate_path` - The directory within the container that the certificates should be deployed to. If this is not set, certificates will be deployed to the root directory, in the "certs" folder. E.g. "/certs".
- `sh.acme.deploy` - One or more of the following values as a comma-separated list:
  - `pem` - Deploy the certiicate, key, and CA chain as a single file, with the domain name as the file name. E.g. "example.com.pem".
  - `crt` - Deploy the certificate as a separate file, with the domain name as the file name. E.g. "example.com.crt".
  - `key` - Deploy the private key as a separate file, with the domain name as the file name. E.g. "example.com.key".
  - `ca` - Deploy the CA chain as a separate file, with the domain name as the file name. E.g. "example.com.ca".
  - `csr` - Deploy the certificate signing request as a separate file, with the domain name as the file name. E.g. "example.com.csr".

  For example, setting `sh.acme.deploy` to "crt,key,ca" will deploy the certificate, key, and CA chain as separate files, with the domain name as the file name. E.g. "example.com.crt", "example.com.key", and "example.com.ca". The default value is "crt,key".

  (No matter what the file extension is, the certificate is always deployed in PEM format. If you want to use a different file type, you must convert the PEM file to the desired file type yourself.)

## Deployment

As this is a certificate manager for Docker, naturally, certificates are deployed to other containers that are running on the host machine. To do this, the certificate manager must be able to access the Docker socket. You can mount the host docker socket using volumes

```yaml
volumes:
  - /var/run/docker.sock:/var/run/docker.sock:ro
```

or via the CLI

```cli
docker run -v /var/run/docker.sock:/var/run/docker.sock:ro ...
```

## Services

The certificate manager is designed to be managed by docker compose, and will automatically issue, renew, and deploy certificates for all containers that have the "sh.acme.domains" label set.

Currently, the image has not been setup to allow the certificate manager to be used as a dependency (although this is planned to be the default way of using this image in a future release), and as such, the certificate manager must be setup to depend upon the containers that it will be managing certificates for. This is because the certificate manager will not be able to access the Docker socket until the containers that it will be managing certificates for have been started. For example:

```yaml
services:
  apache:
    ...
    labels:
      sh.acme.domains: example.com,www.example.com
      sh.acme.reload_command: docker compose restart apache

  mariadb:
    ...
    labels:
      sh.acme.domains: db.example.com
      sh.acme.reload_command: docker compose restart mariadb

  acme-certificate-manager:
    ...
    depends_on:
      - apache
      - mariadb
```

## CLI

The certificate manager can also be managed via the CLI. Currently, the CLI is missing most functionality, but the following documentation is provided for future reference and is unlikely to change.

### Usage

```cli
certificate-manager <command> [options]
```

### Commands

command | description
--- | ---
**start** | start the certificate manager service
**stop** | stop the certificate manager service [not implemented yet]
**restart** | restart the certificate manager service [not implemented yet]
**status** | check the status of the certificate manager [not implemented yet]
**help** | show CLI usage information
**list** | list certificates that are managed by the certificate manager
**update** | issue/renew certificates and deploy them to the containers
**deploy** | deploy certificates to the containers
**revoke** | revoke certificates for domains that are no longer managed by the certificate manager
**issue** | issue certificates for domains that don't have a certificate yet
**renew** | renew certificates for domains that have a certificate that is about to expire

### Options

option | description
--- | ---
**-h, --help** | show CLI usage information
**--version** | show CLI version information
**-v, --verbose** | enable debug mode [not implemented yet]
**-q, --quiet** | enable quiet mode [not implemented yet]

## Files/Directories

Certificate Manager only uses two files/directories for itself:
	- "/certificate-manager.sh": the script responsible for managing certificates.
	- "/etc/environment": the file that contains the environment variables that are used by crond.

Certificate Manager also uses [acme.sh]() internally for all its ACME needs, and in fact, Certificate Manager is just a wrapper around acme.sh. acme.sh stores all its binaries/libraries in the "/root/.acme.sh" directory, and all its config/certificate files in the "/acme.sh" directory. These are the default directories used by acme.sh. Certificate Manager also uses these directories.

The "/acme.sh" directory is the only directory that should be mounted.

## Current Roadmap

- [ ] Allow other containers to depend on the certificate manager, so that the certificate manager can be used as a dependency.
- [ ] Implement a propper healthcheck.
- [ ] Implement a proper CLI for service management.
- [ ] Instead of using the acme.sh DNS prefixes for storing credentials for the DNS providers, (CF_*, VULTR_*, etc), it would be better to use docker secrets, or a more uniform naming scheme for the environment variables (ACME_DNS_CREDENTIALS).
- [ ] While having nothing to do with the ACME protocol, it would be nice to have a way to manage certificates for non-ACME domains, such as self-signed certificates, or certificates from a private CA. (This would still be within the scope of the certificate manager, as it would still be managing certificates for docker containers.)
- [ ] Add support to issue certificates using the docker hostname and domainname configuration of docker compose services.
- [ ] Allow customisation of the certificate manager's home directory, and the location of the acme.sh script.
- [ ] `docker deploy` (cluster/swarm) support.
- [ ] Ability to control logging verbosity.
- [ ] Better directory structure. The plan is to use the same directory structure as acme.sh, but this is not yet implemented.

## Things that are not planned

The certificate manager is designed to be managed by docker compose and to be done as autonomously as possible. As such, there are some things that are not planned to be implemented:

- A web interface for managing certificates, either manually or automatically.
- Configuration files for the certificate manager.
- HTTP-01 challenge support.
- TLS-SNI-01 challenge support.
- Wildcard certificate support.
- CLI commands for individual certificate management. (Use acme.sh directly for this.)
- Support for other ACME clients.

## Contributing

Please read [CONTRIBUTING.md](CONTRIBUTING.md) for details on our code of conduct, and the process for submitting pull requests to us.

## Authors/Significant Contributors

- Everyone who has [contributed to acme.sh](https://github.com/acmesh-official/acme.sh/graphs/contributors) has indirectly contributed to this project.
- [@nbish11]() - Initial work

## License

This project is licensed under the MIT License - see the [LICENSE.md](LICENSE.md) file for details.
