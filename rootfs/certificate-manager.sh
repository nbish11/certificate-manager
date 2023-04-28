#!/bin/sh

set +e
set -u

# ACME-specific required configuration
if [ -z "$ACME_MAIN_DOMAIN" ]; then
	echo "ACME_MAIN_DOMAIN is not set"
	exit 1
fi

if [ -z "$ACME_EMAIL" ]; then
	echo "ACME_EMAIL is not set"
	exit 1
fi

if [ -z "$ACME_DNS_PROVIDER" ]; then
	echo "ACME_DNS_PROVIDER is not set"
	exit 1
fi

# ACME-specific optional configuration
ACME_STAGING=${ACME_STAGING:-"false"}
ACME_CA=${ACME_CA:-"letsencrypt"}

# Script information
SCRIPT_NAME="Certificate Manager"
SCRIPT_VERSION="0.1.0"
SCRIPT_DESCRIPTION="Manage certificates for Docker containers automatically, issuing and renewing them via the ACME protocol (Let's Encrypt)."

# library-specific optional configuration
DOMAINS_DOCKER_LABEL=${DOMAINS_DOCKER_LABEL:-"sh.acme.domains"}
CERTIFICATE_PATH_DOCKER_LABEL=${CERTIFICATE_PATH_DOCKER_LABEL:-"sh.acme.certificate_path"}
RELOAD_COMMAND_DOCKER_LABEL=${RELOAD_COMMAND_DOCKER_LABEL:-"sh.acme.reload_command"}
DEPLOY_DOCKER_LABEL=${DEPLOY_DOCKER_LABEL:-"sh.acme.deploy"}
DEFAULT_CONTAINER_CERTIFICATE_STORE=${DEFAULT_CONTAINER_CERTIFICATE_STORE:-"/certs"}
DEFAULT_CERTIFICATE_DEPLOYMENT=${DEFAULT_CERTIFICATE_DEPLOYMENT:-"crt,key"}

silence_output=false
verbose=false

# Return status codes:
# 0: certificate is valid and up to date
# 1: certificate has expired
# 2: certificate has not been issued
get_certificate_status() {
  domain="$1"

  echo "Checking certificate status for $domain"

  while IFS='|' read -r common_name expired sans; do
	if [ "$common_name" == "$domain" ]; then
		if [ "$expired" == "no" ]; then
			echo "Certificate for $domain is valid and up to date"
			return 0
		fi

		echo "Certificate for $domain has expired"
		return 1
	fi
  done < <(list)

  echo "Certificate has not been issued for $domain"
  return 2
}

issue_certificate() {
	domain="$1"

	# revoke any previous certificates for domain if they exist
	revoke_certificate "$domain" >/dev/null 2>&1
	call_acme "issue" "$domain"
	# acme.sh --issue --domain "$domain" --dns "dns_${ACME_DNS_PROVIDER}""$ACME_STAGING" --debug 0 --force
}

# 	Renew a certificate for the given domain. Certificates are renewed by
# 	using the ACME protocol with the DNS-01 challenge to request a new
#	certificate from the CA.
renew_certificate() {
	domain="$1"

	echo "Renewing certificate for $domain"
	call_acme "renew" "$domain"
}

call_acme() {
	subcommand="--$1"
	domain="--domain $2"
	dns="--dns dns_${ACME_DNS_PROVIDER}"
	cmd="acme.sh $subcommand $domain $dns --debug 0 --force"

	if [ "$ACME_STAGING" == "true" ]; then
		cmd="$cmd --staging"
	fi

	# remove the first two arguments
	shift 2

	# append any additional arguments
	eval "$cmd" "$@"
}

# 	Revokes a certificate for a given domain. The main domain
#	cannot be removed.
revoke_certificate() {
	domain="$1"

	# do not revoke the main certificate
	if [ "$domain" == "$ACME_MAIN_DOMAIN" ]; then
		return 0
	fi

	echo "Revoking certificate for $domain"
	call_acme "revoke" "$domain" --remove
	# acme.sh --revoke --remove --domain "$domain" --force >/dev/null 2>&1
	find /acme.sh -type d -name "${domain}_ecc" -exec rm -rf {} \; >/dev/null 2>&1

	return 0
}

get_docker_label() {
	container="$1"
	label="$2"

	docker inspect --format "{{index .Config.Labels \"$label\"}}" "$container"
}

get_containers() {
	docker ps --format "{{.ID}}" --filter "label=$DOMAINS_DOCKER_LABEL"
}

get_domain_list_for_container() {
	container="$1"

	get_docker_label "$container" "$DOMAINS_DOCKER_LABEL" | tr ',' ' '
}

get_container_certificate_store() {
	container="$1"
	store=$(get_docker_label "$container" "$CERTIFICATE_PATH_DOCKER_LABEL")

	if [ -z "$store" ]; then
		store="$DEFAULT_CONTAINER_CERTIFICATE_STORE"
	fi

	echo "$store"
}

run_reload_command() {
	container="$1"
	cmd=$(get_docker_label "$container" "$RELOAD_COMMAND_DOCKER_LABEL")

	if [ -n "$cmd" ]; then
		# strip leading and trailing quotes from command
		cmd=$(echo "$cmd" | sed -e 's/^"//g' -e 's/"$//g' -e "s/^'//g" -e "s/'$//g")

		# if command starts with "docker", then append container name and execute directly
		if expr "$cmd" : '^docker' >/dev/null; then
			echo "Executing command \`$cmd $container\`"
			eval "$cmd $container"

		# otherwise, execute it inside the container
		else
			echo "Executing command \`sh -c \"$cmd\"\` in container $container"
			docker exec "$container" sh -c "$cmd"
		fi
	fi
}

# 	list all domains that each container requires as a
# 	unique list, with the main domain coming first. This will
# 	always return the main domain at a minimum.
list_domains() {
	domains="$ACME_MAIN_DOMAIN"

	for container in $(get_containers); do
		container_domains=$(get_domain_list_for_container "$container")

		if [ -n "$container_domains" ]; then
			domains="$domains $container_domains"
		fi
	done

	# sort domains, remove duplicates, and make sure main domain comes first
	domains=$(echo "$domains" | tr ' ' '\n' | sort -u | awk '{print length, $0}' | sort -n | cut -d' ' -f2- | tr '\n' ' ')

	echo "$domains"
	return 0;
}

# Return status codes:
# 0: all certificates are valid and up to date
# 1: at least one certificate has expired or has not been issued
check_certificates() {
	domains=$(list_domains)
	status=0

	for domain in $domains; do
		get_certificate_status "$domain"
		certificate_status=$?

		if [ "$certificate_status" -ne 0 ]; then
			status=1
		fi
	done

	return "$status"
}

is_certificate_deployed() {
	domain="$1"
	container="$2"
	acme_cert_dir="/acme.sh/${domain}_ecc"
	container_cert_dir=$(get_container_certificate_store "$container")

	if ! test -d "$acme_cert_dir"; then
		return 1
	fi

	if ! docker exec "$container" test -d "$container_cert_dir"; then
		return 1
	fi

	if ! docker exec "$container" test -f "$container_cert_dir/$domain.crt"; then
		return 1
	fi

	if ! docker exec "$container" test -f "$container_cert_dir/$domain.key"; then
		return 1
	fi

	# Check if the certificate files are different to the ones in the acme.sh directory
    if ! diff -q "$acme_cert_dir/$domain.cer" <(docker exec "$container" cat "$container_cert_dir/$domain.crt"); then
        return 1
    fi

    if ! diff -q "$acme_cert_dir/$domain.key" <(docker exec "$container" cat "$container_cert_dir/$domain.key"); then
        return 1
    fi

	return 0
}

deploy_certificate() {
	domain="$1"
	container="$2"
	acme_cert_dir="/acme.sh/${domain}_ecc"
	container_cert_dir=$(get_container_certificate_store "$container")

	if ! test -d "$acme_cert_dir"; then
		echo "Certificate has not been issued for $domain. Skipping..."
		return 1
	fi

	echo "Deploying certificate for $domain to $container"

	# if the container certificate directory does not exist, create it
	if ! docker exec "$container" test -d "$container_cert_dir"; then
		echo "Certificate directory $container_cert_dir in $container does not exist. Creating it..."
		docker exec -u root "$container" mkdir -p "$container_cert_dir"
	fi

	echo "Copying certificates for $domain to $container"

	docker cp "$acme_cert_dir/$domain.cer" "$container:$container_cert_dir/$domain.crt"
	docker cp "$acme_cert_dir/$domain.key" "$container:$container_cert_dir/$domain.key"
}

# ----------------
# "issue" action
# ----------------

issue() {
	domains=$(list_domains)

	for domain in $domains; do
		get_certificate_status "$domain"
		certificate_status=$?

		if [ "$certificate_status" -eq 2 ]; then
			issue_certificate "$domain"
		fi
	done
}

print_issue_help_description() {
	echo "Issue certificates for all domains that are defined for docker containers."
}

print_issue_help_options() {
	echo "-f, --force: reissue certificates even if they are valid and up to date"
}

# ----------------
# "renew" action
# ----------------

renew() {
	domains=$(list_domains)

	for domain in $domains; do
		get_certificate_status "$domain"
		certificate_status=$?

		if [ "$certificate_status" -eq 1 ]; then
			renew_certificate "$domain"
		fi
	done
}

print_renew_help_description() {
	echo "Renew certificates for domains that have a certificate that is about to expire."
}

print_renew_help_options() {
	echo "-f, --force: renew certificates even if they are valid and up to date"
}

# ----------------
# "revoke" action
# ----------------

revoke() {
	domains=$(list_domains)
	certs_revoked=0

	echo "Checking for unused certificates..."

	while IFS='|' read -r common_name expired; do
		if ! echo "$domains" | grep -qw "$common_name"; then
			echo "Certificate for $common_name is no longer in use."
			revoke_certificate "$common_name"
			certs_revoked=1
		fi
	done < <(list)

	if [ "$certs_revoked" -eq 0 ]; then
		echo "No unused certificates found."
	fi
}

print_revoke_help_description() {
	echo "Revoke certificates for domains that are no longer managed by the certificate manager."
}

print_revoke_help_options() {
	echo "-c, --confirm: actually revoke and remove the certificates. Without this option, only a dry run is performed."
	echo "--dont-remove: do not remove the certificates from the container's certificate store."
}

# ----------------
# "deploy" action
# ----------------

deploy() {
	for container in $(get_containers); do
		some_certs_deployed=0

		for domain in $(get_domain_list_for_container "$container"); do
			if is_certificate_deployed "$domain" "$container"; then
				echo "Certificate for $domain already deployed. Skipping deployment..."
				continue
			fi

			# otherwise, deploy certificate but don't reload container yet
			some_certs_deployed=1
			deploy_certificate "$domain" "$container"
		done

		if [ "$some_certs_deployed" -eq 0 ]; then
			echo "No certificates need to be deployed for container $container. Skipping reload..."
			continue
		fi

		# reload container if reload command is set
		# and at least one certificate was deployed
		run_reload_command "$container"
	done
}

print_deploy_help_description() {
	echo "Deploy certificates to their appropriate containers"
}

print_deploy_help_options() {
	echo "-f, --force: copy certificates over even if they have already been deployed"
}

# ----------------
# "stop" action
# ----------------

stop() {
	echo "[Not implemented]"
	return 1
}

print_stop_help_description() {
	echo "Stop the certificate manager service."
}

print_stop_help_options() {
	echo "-f, --force: force the certificate manager service to stop"
}

# ----------------
# "status" action
# ----------------

status() {
	echo "[Not implemented]"
	return 1
}

print_status_help_description() {
	echo "Check the status of the certificate manager service."
}

print_status_help_options() {
	echo "--simple: print the status of the certificate manager service as one word (started, running, stopping, stopped, unknown, restarting.)"
}

# ----------------
# "restart" action
# ----------------

restart() {
	echo "[Not implemented]"
	return 1
}

print_restart_help_description() {
	echo "Restart the certificate manager service."
}

# print_restart_help_options() {
# }

# ----------------
# "list" action
# ----------------

list() {
	acme.sh --list --listraw | tail -n +2 | awk -F "|" '{
		expired="no";
		renew_date=$6;
		cmd="date +%s -d\""renew_date"\"";
		cmd | getline renew_timestamp;
		close(cmd);
		current_timestamp=strftime("%s");
		if (renew_timestamp < current_timestamp) expired="yes";
		printf "%s|%s|%s\n", $1, expired, $3
	}'
}

print_list_help_description() {
	echo "List certificates that are managed by the certificate manager."
}

print_list_help_options() {
	echo "-H, --no-header: do not print the header row"
	echo "--json: print the list in JSON format. No header row is printed."
	echo "--csv: print the list in CSV format"
	echo "--fields=field1,field2,...: print only the specified fields"
	echo "--status=deployed,valid,unused,expired: list only the certificates with the specified status"
}

# ----------------
# "update" action
# ----------------

# - revoke and remove any certificates no longer in use.
# - issue certificates for domains that have no certificates.
# - renew certificates for domains that have expired certificates or about to expire.
# - deploy certificates to containers as needed.
update() {
	domains=$(list_domains)

	revoke

	for domain in $domains; do
		get_certificate_status "$domain"
		certificate_status=$?

		if [ "$certificate_status" -eq 2 ]; then
			issue_certificate "$domain"
		elif [ "$certificate_status" -eq 1 ]; then
			renew_certificate "$domain"
		fi
	done

	deploy
}

print_update_help_description() {
	echo "Issue/renew/revoke/deploy certificates to their containers - whatever is needed."
}

print_update_help_options() {
	echo "-D, --no-deploy: do not deploy certificates to their containers"
	echo "-R, --no-revoke: do not revoke unused certificates"
}

# ----------------
# "start" action
# ----------------

start() {

	# create a file with all environment variables
	# needed because cron does not inherit environment variables
	eval "$(printenv | awk -F= '{print "export " "\""$1"\"""=""\""$2"\"" }' >> /etc/environment)"

	# add cron job to update certificates if it does not exist
	if ! crontab -l | grep -q '/certificate-manager.sh'; then
		echo "0 0 * * * . /etc/environment; /certificate-manager.sh update > /proc/1/fd/1 2>/proc/1/fd/2" >> /etc/crontabs/root
	fi

	# make sure all certificates are valid before starting cron
	update

	echo "Press Ctrl+C to exit..."
	exec crond -f -s -m off
}

print_start_help_description() {
	echo "Start the certificate manager service."
}

print_start_help_options() {
	echo "--background: start the certificate manager service in the background"
	echo "--no-update: do not update certificates before starting the service"
	echo "-D, --no-deploy: do not deploy any certificates before starting the service"
	echo "-R, --no-revoke: do not revoke any unused certificates before starting the service"
}

# ----------------
# "help" action
# ----------------

help() {
	action=${1:-"<action>"}

	# print help header
	echo ""
	echo "$SCRIPT_NAME (v$SCRIPT_VERSION)"
	echo ""

	# print help description
	echo "Description:"
	if type "print_${action}_help_options" > /dev/null; then
		"print_${action}_help_description"
	else
		echo "    $SCRIPT_DESCRIPTION"
	fi
	echo ""

	# print help usage
	echo "Usage:"
	echo "    $0 $action [options]"
	echo ""

	# print help actions if no action specified
	if [ "$action" == "<action>" ]; then
		echo "Actions:"
		for action in $allowed_actions; do
			if type "print_${action}_help_description" > /dev/null; then
				echo "    $action: $(print_"${action}"_help_description)"
			fi
		done
		echo ""
	fi

	# print help options
	echo "Options:"
	if type "print_${action}_help_options" > /dev/null; then
		"print_${action}_help_options"
	else
		echo "        --version  Show the version of the certificate manager"
	fi
	echo "    -h, --help     Show this help message"
	echo "    -q, --quiet    Disable all output"
	echo "    -v, --verbose  Enable verbose output"
	echo ""

	# print help footer
	echo "Copyright (c) 2022 Nathan Bishop"
	echo "Licensed under the MIT License"
	echo ""

	return 0
}

allowed_actions="start stop restart list update status deploy revoke issue renew help"

if [ $# -eq 0 ]; then
	help
	exit 1
fi

action=$1
shift

# show global help
if [ "$action" == "-h" ] || [ "$action" == "--help" ]; then
	help
	exit 0
fi

# show version
if [ "$action" == "--version" ]; then
	echo "v$SCRIPT_VERSION"
	exit 0
fi

# unknown subcommand
if ! echo "$allowed_actions" | grep -qw "$action"; then
	echo "Unknown action: $action" >&2
	echo ""
	help
	exit 1
fi

# parse global options
while [ $# -gt 0 ]; do
    case $1 in
        -h|--help)
            help "$action"
			exit 0
            ;;
		-q|--quiet)
			silence_output=true
			;;
        *)
            # ignore any other options as they are passed directly to the action to handle
            ;;
    esac
    shift
done

# @todo: this should be done in a better way (maybe logfile)
if [ "$silence_output" == true ]; then
	exec > /dev/null 2>&1
fi

# set default CA server
acme.sh --set-default-ca --server "$ACME_CA" --uninstall-cronjob >/dev/null 2>&1

# register an account with the ACME server
acme.sh --register-account -m "$ACME_EMAIL" >/dev/null 2>&1

# Call the subcommand with any remaining arguments/options
"${action}" "$@"
