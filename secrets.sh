#!/usr/bin/env bash

getopt --test > /dev/null
if [[ $? -ne 4 ]]
then
    cat <<EOF
I’m sorry, "getopt --test" failed in this environment.

You may need to install enhanced getopt, e.g. on OSX using
"brew install gnu-getopt".
EOF
    exit 1
fi

REALPATH="realpath"

if [ $(uname) == "Darwin" ] ; then
    REALPATH="grealpath"
fi

set -ueo pipefail

usage() {
    cat <<EOF
GnuPG secrets encryption in Helm Charts

This plugin provides ability to encrypt/decrypt secrets files
to store in less secure places, before they are installed using
Helm.

To decrypt/encrypt/edit you need to initialize/first encrypt secrets with
sops - https://github.com/mozilla/sops

Available Commands:
  enc    	Encrypt secrets file
  dec    	Decrypt secrets file
  view   	Print secrets decrypted
  edit   	Edit secrets file and encrypt afterwards
  clean         Clean all Decrypted files in specified directory
  deploy        wrapper that searches for values and secrets from a leaf directory
  install	wrapper that decrypts secrets[.*].yaml files before running helm install
  upgrade	wrapper that decrypts secrets[.*].yaml files before running helm upgrade
  lint		wrapper that decrypts secrets[.*].yaml files before running helm lint
  diff		wrapper that decrypts secrets[.*].yaml files before running helm diff
                  (diff is a helm plugin)

EOF
}

enc_usage() {
    cat <<EOF
Encrypt secrets

It uses your gpg credentials to encrypt .yaml file. If the file is already
encrypted, look for a decrypted .dec.yaml file and encrypt that to .yaml.
This allows you to first decrypt the file, edit it, then encrypt it again.

You can use plain sops to encrypt - https://github.com/mozilla/sops

Example:
  $ helm secrets enc <SECRET_FILE_PATH>
  $ git add <SECRET_FILE_PATH>
  $ git commit
  $ git push

EOF
}

dec_usage() {
    cat <<EOF
Decrypt secrets

It uses your gpg credentials to decrypt previously encrypted .yaml file.
Produces .dec.yaml file.

You can use plain sops to decrypt specific files - https://github.com/mozilla/sops

Example:
  $ helm secrets dec <SECRET_FILE_PATH>

Typical usage:
  $ helm secrets dec secrets/myproject/secrets.yaml
  $ vim secrets/myproject/secrets.yaml.dec

EOF
}

view_usage() {
    cat <<EOF
View specified secrets[.*].yaml file

Example:
  $ helm secrets view <SECRET_FILE_PATH>

Typical usage:
  $ helm secrets view secrets/myproject/nginx/secrets.yaml | grep basic_auth

EOF
}

edit_usage() {
    cat <<EOF
Edit encrypted secrets

Decrypt encrypted file, edit and then encrypt

You can use plain sops to edit - https://github.com/mozilla/sops

Example:
  $ helm secrets edit <SECRET_FILE_PATH>
  or $ sops <SECRET_FILE_PATH>
  $ git add <SECRET_FILE_PATH>
  $ git commit
  $ git push

EOF
}

clean_usage() {
    cat <<EOF
Clean all decrypted files if any exist

It removes all decrypted .dec.yaml files in the specified directory
(recursively) if they exist.

Example:
  $ helm secrets clean <dir with secrets>

EOF
}

install_usage() {
    cat <<EOF
Install a chart

This is a wrapper for the "helm install" command. It will detect -f and
--values options, and decrypt any secrets.*.yaml files before running "helm
install".

Example:
  $ helm secrets install <HELM INSTALL OPTIONS>

Typical usage:
  $ helm secrets install -n i1 stable/nginx-ingress -f values.test.yaml -f secrets.test.yaml

EOF
}

upgrade_usage() {
    cat <<EOF
Upgrade a deployed release

This is a wrapper for the "helm upgrade" command. It will detect -f and
--values options, and decrypt any secrets.*.yaml files before running "helm
upgrade".

Example:
  $ helm secrets upgrade <HELM UPGRADE OPTIONS>

Typical usage:
  $ helm secrets upgrade i1 stable/nginx-ingress -f values.test.yaml -f secrets.test.yaml

EOF
}

lint_usage() {
    cat <<EOF
Run helm lint on a chart

This is a wrapper for the "helm lint" command. It will detect -f and
--values options, and decrypt any secrets.*.yaml files before running "helm
lint".

Example:
  $ helm secrets lint <HELM LINT OPTIONS>

Typical usage:
  $ helm secrets lint ./my-chart -f values.test.yaml -f secrets.test.yaml

EOF
}

diff_usage() {
    cat <<EOF
Run helm diff on a chart

"diff" is a helm plugin. This is a wrapper for the "helm diff" command. It
will detect -f and --values options, and decrypt any secrets.*.yaml files
before running "helm diff".

Example:
  $ helm secrets diff <HELM DIFF OPTIONS>

Typical usage:
  $ helm secrets diff upgrade i1 stable/nginx-ingress -f values.test.yaml -f secrets.test.yaml

EOF
}

deploy_usage() {
    cat <<EOF
Easily deploy a helm_vars leaf directory.
This wrapper collects all values.yaml and secrets.yaml files
until it reaches the current directory. This makes it easy to deploy to a specific
environment without a huge helm command line.


Usage:
  $ helm secrets deploy [install|upgrade] <project>/helm_vars/<type>/<dev|prod>

Typical usage:
  $ helm secrets deploy upgrade proxy/helm_vars/prometheus/dev

EOF
}

is_help() {
    case "$1" in
	-h|--help|help)
	    return 0
	    ;;
	*)
	    return 1
	    ;;
    esac
}

sops_config() {
    DEC_SUFFIX=".dec.yaml"
}

is_enc() {
    # check if a file is already encrypted
    if [[ $(grep -C10000 'sops:' "$1" | grep -c 'version:') -gt 0 ]]
    then
	return 0
    fi
    return 1
}

get_dec() {
    sops_config
    echo "$(sed -e "s/\\.yaml$/${DEC_SUFFIX}/" <<<"$1")"
}

encrypt_helper() {
    local yml="$1"
    [[ -e "$yml" ]] || { echo "File does not exist: $yml"; exit 1; }
    local ymldec=$(get_dec "$yml")
    [[ -e $ymldec ]] || ymldec="$yml"
    
    if [[ $(is_enc $ymldec) ]]
    then
	echo "Already encrypted: $ymldec"
        return 0
    fi

    if [[ $yml =~ secrets.*\.dec\.yaml$ ]]
    then
        echo "Not a secrets file."
        echo "To encrypt the secrets.yaml again, just use
helm secrets enc ${yml%%.*}.yaml
This file will be encrypted instead."
        return 1
    fi
    if [[ $yml == $ymldec ]]
    then
	sops -e -i "$yml"
	echo "Encrypted $yml"
    else
	sops -e "$ymldec" > "$yml"
	echo "Encrypted $ymldec to $yml"
    fi
}

enc() {
    if is_help "$1"
    then
	enc_usage
	return
    fi
    yml="$1"
    if [[ ! -f "$yml" ]]
    then
	echo "$yml doesn't exist."
    else
	echo "Encrypting $yml"
	encrypt_helper "$yml"
    fi
}

# Name references ("declare -n" and "local -n") are a Bash 4 feature.
# For previous versions, work around using eval.
decrypt_helper() {
    local yml="$1" __ymldec __dec

    if [[ ${BASH_VERSINFO[0]} -lt 4 ]]
    then
	local __ymldec_var=$2
	local __dec_var=$3
	[[ $__dec_var ]] && eval $__dec_var=0
    else
	[[ $# -ge 2 ]] && local -n __ymldec=$2
	[[ $# -ge 3 ]] && local -n __dec=$3
    fi

    __dec=0
    [[ -e "$yml" ]] || { echo "File does not exist: $yml"; exit 1; }
    if [[ $(is_enc $yml) ]]
    then
	echo "Not encrypted: $yml"
	__ymldec="$yml"
    else
        __ymldec=$(get_dec "$yml")
	if [[ -e $__ymldec && $__ymldec -nt $yml ]]
	then
	    echo "$__ymldec is newer than $yml"
	else
	    sops -d "$yml" > "$__ymldec" || { rm "$__ymldec"; exit 1; }
	    __dec=1
	fi
    fi

    if [[ ${BASH_VERSINFO[0]} -lt 4 ]]
    then
	[[ $__ymldec_var ]] && eval $__ymldec_var="'$__ymldec'"
	[[ $__dec_var ]] && eval $__dec_var="'$__dec'"
    fi
}


dec() {
    if is_help "$1"
    then
	dec_usage
	return
    fi
    yml="$1"
    if [[ ! -f "$yml" ]]
    then
	echo "$yml doesn't exist."
    else
	echo "Decrypting $yml"
	decrypt_helper "$yml"
    fi
}

view_helper() {
    local yml="$1"
    [[ -e "$yml" ]] || { echo "File does not exist: $yml"; exit 1; }
    sops_config
    sops -d "$yml"
}

view() {
    if is_help "$1"
    then
	view_usage
	return
    fi
    local yml="$1"
    view_helper "$yml"
}

edit_helper() {
    local yml="$1"
    [[ -e "$yml" ]] || { echo "File does not exist: $yml"; exit 1; }
    sops_config
    exec sops "$yml" < /dev/tty
}

edit() {
    local yml="$1"
    edit_helper "$yml"
}

clean() {
    if is_help "$1"
    then
	clean_usage
	return
    fi
    local basedir="$1"
    sops_config
    find "$basedir" -type f -name "*${DEC_SUFFIX}" -print0 | xargs -r0 rm -v
}


get_parent() {
    dirname "$1"
}

build_value_list() {
    # find values.yaml and secrets.yaml recursively
    local current_dir="$1"
    local max_dir="$PWD"
    local my_files=()
    
    if [[ "$($REALPATH "$current_dir")" == "$max_dir" ]]; then
        return
    fi

    if [[ -f "$current_dir/values.yaml" ]]; then
        my_files+=("$current_dir/values.yaml")
    fi

    if [[ -f "$current_dir/secrets.yaml" ]]; then
        my_files+=("$current_dir/secrets.yaml")
    fi

    eval $(build_value_list "$(get_parent "$current_dir")")
    helm_files+=("${my_files[@]}")
    declare -p helm_files
}

deploy_helper() {
    local mode="$1"
    local project="$2"
    local project_name="$(echo "$project" | cut -d"/" -f 1)"

    if ! [[ $mode =~ [install|upgrade] ]]
    then
        echo "$mode is not supported"
        return 1
    fi

    if [[ ! -d "$project" ]]; then
        echo "$project does not exist."
        return 1
    fi

    subdir_count=$(find "$project" -maxdepth 1 -type d | wc -l)

    if [[ ! $subdir_count -eq 1 ]]; then
        echo "$project has subdirectories."
        exit 1
    fi

    eval "$(build_value_list $project)"

    local helm_cmd=("$mode")

    for f in "${helm_files[@]}"; do
        helm_cmd+=("-f" "$f")
    done
        
    if [[ $mode == "install" ]]; then
        # -n release and directory
        helm_cmd+=("-n" "$project_name" "$project_name/")
    else
        # release and directory
        helm_cmd+=("$project_name" "$project_name/")
    fi

    helm_wrapper "${helm_cmd[@]}"
}

deploy() {
    if is_help "$1"
    then
	deploy_usage
	return
    fi
    deploy_helper "$@"
}

helm_wrapper() {
    local cmd="$1" subcmd='' cmd_version=''
    shift
    if [[ $cmd == diff ]]
    then
	subcmd="$1"
	shift
	cmd_version=$(helm diff version)
    fi

    # cache options for the helm command in a file so we don't need to parse the help each time
    local helm_version=$(helm version --client --short)
    local cur_options_version="${helm_version}${cmd_version:+ $cmd: }${cmd_version}"
    local optfile="$HELM_PLUGIN_DIR/helm.${cmd}${subcmd:+.}${subcmd}.options" options_version='' options='' longoptions=''
    [[ -f $optfile ]] && . "$optfile"

    if [[ $cur_options_version != $options_version ]]
    then
	local re='(-([a-zA-Z0-9]), )?--([-_a-zA-Z0-9]+)( ([a-zA-Z0-9]+))?' line
	options='' longoptions=''

	# parse the helm options and option args from the help output
	while read line
	do
	    if [[ $line =~ $re ]]
	    then
		local opt="${BASH_REMATCH[2]}" lopt="${BASH_REMATCH[3]}" optarg="${BASH_REMATCH[5]:+:}"
		[[ $opt ]] && options+="${opt}${optarg}"
		[[ $lopt ]] && longoptions+="${longoptions:+,}${lopt}${optarg}"
	    fi
	done <<<"$(helm "$cmd" $subcmd --help | sed -e '1,/^Flags:/d')"

	cat >"$optfile" <<EOF
options_version='$cur_options_version'
options='$options'
longoptions='$longoptions'
EOF
    fi
    
    # parse command line
    local parsed # separate line, otherwise the return value of getopt is ignored
    # if parsing fails, getopt returns non-0, and the shell exits due to "set -e"
    parsed=$(getopt --options="$options" --longoptions="$longoptions" --name="helm $cmd${subcmd:+ }$subcmd" -- "$@")

    # collect cmd options with optional option arguments
    local -a cmdopts=() decfiles=()
    local yml ymldec decrypted
    eval set -- "$parsed"
    while [[ $# -gt 0 ]]
    do
	case "$1" in
	    --)
		# skip --, and what remains are the cmd args
		shift 
		break
		;;
            -f|--values)
		cmdopts+=("$1")
		yml="$2"
		if [[ $yml =~ ^(.*/)?secrets.*\.yaml$ ]]
		then
		    decrypt_helper "$yml" ymldec decrypted
		    cmdopts+=("$ymldec")
		    [[ $decrypted -eq 1 ]] && decfiles+=("$ymldec")
		else
		    cmdopts+=("$yml")
		fi
		shift # to also skip option arg
		;;
	    *)
		cmdopts+=("$1")
		;;
	esac
	shift
    done

    # run helm command with args and opts in correct order
    set +e # ignore errors
    echo "executing: helm $cmd $subcmd" "$@" "${cmdopts[@]}"
    read -p "Are you sure? " -n 1 -r

    if [[ $REPLY =~ ^[Yy]$ ]]
    then
        helm "$cmd" "$subcmd" "$@" "${cmdopts[@]}"
    fi

    # cleanup on-the-fly decrypted files
    [[ ${#decfiles[@]} -gt 0 ]] && rm -v "${decfiles[@]}"
}

helm_command() {
    if [[ $# -lt 2 ]] || is_help "$2"
    then
	eval "${1}_usage"
	return
    fi
    helm_wrapper "$@"
}

case "${1:-help}" in
    enc)
	if [[ $# -lt 2 ]]
	then
	    enc_usage
	    echo "Error: secrets file required."
	    exit 1
	fi
	enc "$2"
	shift
	;;
    dec)
	if [[ $# -lt 2 ]]
	then
	    dec_usage
	    echo "Error: secrets file required."
	    exit 1
	fi
	dec "$2"
	;;
    view)
	if [[ $# -lt 2 ]]
	then
	    view_usage
	    echo "Error: secrets file required."
	    exit 1
	fi
	view "$2"
	;;
    edit)
	if [[ $# -lt 2 ]]
	then
	    edit_usage
	    echo "Error: secrets file required."
	    exit 1
	fi
	edit "$2"
	shift
	;;
    clean)
	if [[ $# -lt 2 ]]
	then
	    clean_usage
	    echo "Error: Chart package required."
	    exit 1
	fi
	clean "$2"
	;;
    deploy)
        if [[ $# -lt 3 ]]
        then
            deploy_usage
            echo "Error: helm_vars path required."
            exit 1
        fi
        shift
        deploy $@
        ;;
    install|upgrade|lint|diff)
	helm_command "$@"
	;;
    --help|-h|help)
	usage
	;;
    *)
	usage
	exit 1
	;;
esac

exit 0
