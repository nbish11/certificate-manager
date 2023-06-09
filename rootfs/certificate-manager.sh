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
SUPPORTED_DEPLOYMENT_TYPES="crt key pem ca csr"

# Do not let acme.sh auto-upgrade itself
AUTO_UPGRADE=0

silence_output=false
verbose=false

# statuses:
# 	deployed: certificate is valid and deployed to the correct containers
# 	valid: certificate is valid and up to date, but has not been deployed to required containers
# 	unused: certificate is valid but not used by any containers
# 	expired: certificate has expired
# 	missing: certificate has not been issued
get_certificate_status() {
	domain="$1"
    certs_list=$(acme.sh --server "$ACME_CA" --list | tail -n +2)
	status="missing"

	# parse acme.sh's cert list to generate our own
    while read -r main_domain key_length san_domains ca created_date renew_date; do
		if [ "$main_domain" != "$domain" ]; then
			continue
		fi

		current_date=$(date +%Y-%m-%dT%H:%M:%SZ)

		# domain has a valid certificate
		if [ "$current_date" \> "$created_date" ] && [ "$current_date" \< "$renew_date" ]; then
			status="valid"

			# but is not in our list of domains, so is unused
			if ! echo "$domains" | grep -qw "$domain"; then
				status="unused"
			fi
		# domain has an expired certificate or certificate about to expire
		elif [ "$current_date" \> "$renew_date" ]; then
			status="expired"
		fi

		break
    done < <(echo "$certs_list")

	echo "$status"
}

ensure_all_deployment_types_exist_locally() {
	domain="$1"
	acme_cert_dir="/acme.sh/${domain}_ecc"
	# "csr" and "key" deployment types already have the correct filenames

	# make sure the "crt" deployment type is always available
	if ! test -f "$acme_cert_dir/$domain.crt"; then
		cp "$acme_cert_dir/$domain.cer" "$acme_cert_dir/$domain.crt"
	fi

	# make sure the "pem" deployment type is always available
	if ! test -f "$acme_cert_dir/$domain.pem"; then
		cp "$acme_cert_dir/$domain.key" "$acme_cert_dir/$domain.pem"
		cat "$acme_cert_dir/$domain.cer" >> "$acme_cert_dir/$domain.pem"
		cat "$acme_cert_dir/ca.cer" >> "$acme_cert_dir/$domain.pem"
	fi

	# make sure the "ca" deployment type is always available
	if ! test -f "$acme_cert_dir/$domain.ca"; then
		cp "$acme_cert_dir/ca.cer" "$acme_cert_dir/$domain.ca"
	fi
}

issue_certificate() {
	domain="$1"

	# revoke any previous certificates for domain if they exist
	revoke_certificate "$domain" > /dev/null 2>&1
	call_acme "issue" "$domain"
	ensure_all_deployment_types_exist_locally "$domain"
}

# 	Renew a certificate for the given domain. Certificates are renewed by
# 	using the ACME protocol with the DNS-01 challenge to request a new
#	certificate from the CA.
renew_certificate() {
	domain="$1"

	echo "Renewing certificate for $domain"
	call_acme "renew" "$domain"
	ensure_all_deployment_types_exist_locally "$domain"
}

configure_acme() {
	options="--server $ACME_CA"

	if [ "$ACME_STAGING" == "true" ]; then
		options="$options --staging"
	fi

	acme.sh --set-default-ca $options
	acme.sh --uninstall-cronjob $options
	acme.sh --register-account -m "$ACME_EMAIL" $options
}

call_acme() {
	dns_provider="dns_${ACME_DNS_PROVIDER}"
	cmd="acme.sh --$1 --domain $2 --dns $dns_provider --debug 0 --force --server $ACME_CA"

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
	find /acme.sh -type d -name "${domain}_ecc" -exec rm -rf {} \; > /dev/null 2>&1

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
# 1: at least one certificate has expired or is missing
check_certificates() {
	domains=$(list_domains)

	for domain in $domains; do
		status=$(get_certificate_status "$domain")

		if [ "$status" == "expired" ] || [ "$status" == "missing" ]; then
			return 1
		fi
	done

	return 0
}

deploy_certificate() {
	domain="$1"
	container="$2"
	acme_cert_dir="/acme.sh/${domain}_ecc"
	container_cert_dir=$(get_container_certificate_store "$container")
	expected_deployment_types=$(get_docker_label "$container" "$DEPLOY_DOCKER_LABEL" | tr ',' ' ')
	some_certs_deployed=0

	if ! test -d "$acme_cert_dir"; then
		echo "A certificate has not been issued for $domain. Cannot deploy..."
		return 1
	fi

	if ! docker exec "$container" test -d "$container_cert_dir"; then
		echo "Certificate directory $container_cert_dir in $container does not exist. Creating it..."
		docker exec -u root "$container" mkdir -p "$container_cert_dir"
	fi

	for deployment_type in $SUPPORTED_DEPLOYMENT_TYPES; do
		local_cert_file="$acme_cert_dir/$domain.$deployment_type"
		container_cert_file="$container_cert_dir/$domain.$deployment_type"

		# if certificate should not be deployed...
		if ! echo "$expected_deployment_types" | grep -q "$deployment_type"; then

			# and exists in container when it shouldn't
			if docker exec "$container" test -f "$container_cert_file"; then
				echo "Unused certificate $container_cert_file found. Deleting..."
				docker exec -u root "$container" rm -f "$container_cert_file"
			fi

			# no need to run reload command since the certificate is not used
			continue
		fi

		# certificate should be deployed and does not exist in container
		if ! docker exec "$container" test -f "$container_cert_file"; then
			echo "Certificate $container_cert_file not found. Copying over..."
			some_certs_deployed=1
			docker cp "$local_cert_file" "$container:$container_cert_file"
			continue
		fi

		# certificate should be deployed and exists in container, but is different
		if ! diff -q "$local_cert_file" <(docker exec "$container" cat "$container_cert_file") >/dev/null 2>&1; then
			echo "Certificate $container_cert_file is different. Replacing..."
			some_certs_deployed=1
			docker cp "$local_cert_file" "$container:$container_cert_file"
			continue
		fi
	done

	if [ "$some_certs_deployed" -eq 1 ]; then
		run_reload_command "$container"
	fi

	return 0
}

# ----------------
# "issue" action
# ----------------

issue() {
	domains=""

	if echo "$@" | grep -qE -- "-f|--force"; then
		echo "Re-issuing certificates for all domains..."
		domains=$(list -H --fields=domain)
	else
		echo "Issuing certificates for missing domains..."
		domains=$(list -H --fields=domain --status=missing)
	fi

	if [ -z "$domains" ]; then
		echo "All required certificates have already been issued."
		return 0
	fi

	for domain in $domains; do
		issue_certificate "$domain"
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
	domains=""

	if [ "$1" == "-f" ] || [ "$1" == "--force" ]; then
		echo "Renewing certificates for all domains..."
		domains=$(list -H --fields=domain)
	else
		echo "Renewing certificates for domains that are about to expire or have already expired..."
		domains=$(list -H --fields=domain --status=expired)
	fi

	if [ -z "$domains" ]; then
		echo "All certificates are valid and up to date."
		return 0
	fi

	for domain in $domains; do
		renew_certificate "$domain"
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
	domains=""

	if [ "$1" == "-f" ] || [ "$1" == "--force" ]; then
		echo "Revoking certificates for all domains..."
		domains=$(list -H --fields=domain)
	else
		echo "Revoking certificates for domains that are no longer in use..."
		domains=$(list -H --fields=domain --status=unused)
	fi

	if [ -z "$domains" ]; then
		echo "No certificates to revoke - all are in use."
		return 0
	fi

	for domain in $domains; do
		revoke_certificate "$domain"
	done
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
		for domain in $(get_domain_list_for_container "$container"); do
			deploy_certificate "$domain" "$container"
		done
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
	domains=$(list_domains)

	# check if any of the arguments contain a field list option
	# where the field list is comma-separated
	if echo "$@" | grep -qE -- "--fields=[^ ]+" ; then
		fields=$(echo "$@" | grep -oE -- "--fields=[^ ]+" | cut -d= -f2 | tr ',' ' ')
	else
		fields="domain status sans"
	fi

	# Add header to output unless it's not wanted
    if ! echo "$@" | grep -qE -- "-H|--no-header" ; then
		header_line=""

		if echo "$fields" | grep -qE -- "domain" ; then
			header_line="${header_line} Domain"
		fi

		if echo "$fields" | grep -qE -- "status" ; then
			header_line="${header_line} Status"
		fi

		if echo "$fields" | grep -qE -- "sans" ; then
			header_line="${header_line} SANs"
		fi

		# trim leading space
		echo "$header_line" | sed -E 's/^ //'
    fi

	# list domains and appropriate fields
	for domain in $domains; do
		status=$(get_certificate_status "$domain")
		line=""

		# check if filtering domains by status
		if echo "$@" | grep -qE -- "--status=[^ ]+" ; then
			status_filter=$(echo "$@" | grep -oE -- "--status=[^ ]+" | cut -d= -f2)

			if [ "$status_filter" != "$status" ]; then
				continue
			fi
		fi

		if echo "$fields" | grep -qE -- "domain" ; then
			line="${line} ${domain}"
		fi

		if echo "$fields" | grep -qE -- "status" ; then
			line="${line} ${status}"
		fi

		if echo "$fields" | grep -qE -- "sans" ; then
			line="${line} none"
		fi

		# trim leading space
		echo "$line" | sed -E 's/^ //'
	done;
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
	while read -r domain status sans; do
		if [ "$status" == "unused" ]; then
			revoke_certificate "$domain"
		elif [ "$status" == "expired" ]; then
			renew_certificate "$domain"
		elif [ "$status" == "missing" ]; then
			issue_certificate "$domain"
		fi
	done < <(list -H)

	deploy
	echo "All certificates are up to date and have been deployed correctly"
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

# arguments specific to the action
action_args=""

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
			# add to action_args for action to handle
			action_args="$action_args $1"
            ;;
    esac
    shift
done

# @todo: this should be done in a better way (maybe logfile)
if [ "$silence_output" == true ]; then
	exec > /dev/null 2>&1
fi

# @todo run this only if the certificate manager is not configured
configure_acme > /dev/null 2>&1

# Call the subcommand with any remaining arguments/options
"${action}" "$action_args"
