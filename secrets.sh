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
  clean         Clean all Decrypted files in specified directory
  view   	Print secrets decrypted
  edit   	Edit secrets file and encrypt afterwards
  install	wrapper that decrypts secrets[.*].yaml files before running helm install
  upgrade	wrapper that decrypts secrets[.*].yaml files before running helm upgrade

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

clean_usage() {
    cat <<EOF
Clean all decrypted files if any exist

It removes all decrypted .dec.yaml files in the specified directory
(recursively) if they exist.

Example:
  $ helm secrets clean <dir with secrets>

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

is_help() {
    case "$1" in
	"-h"|"--help"|"help")
	    return 0
	    ;;
	*)
	    return 1
	    ;;
    esac
}

sops_config() {
    #HELM_HOME=$(helm home)
    DEC_SUFFIX=".dec.yaml"
    SOPS_CONF_FILE=".sops.yaml"
}

encrypt_helper() {
    local dir=$(dirname "$1")
    local yml=$(basename "$1")
    cd "$dir"
    [[ -e "$yml" ]] || (echo "File does not exist: $dir/$yml" && exit 1)
    sops_config
    local ymldec=$(sed -e "s/\\.yaml$/${DEC_SUFFIX}/" <<<"$yml")
    if [[ ! -e $ymldec ]]
    then
	ymldec="$yml"
    fi
    
    if [[ $(grep -C10000 'sops:' "$ymldec" | grep -c 'version:') -gt 0 ]]
    then
	echo "Already encrypted: $ymldec"
	return
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

decrypt_helper() {
    local yml="$1" __ymldec __decrypted=0
    [[ -e "$yml" ]] || (echo "File does not exist: $yml" && exit 1)
    if [[ $(grep -C10000 'sops:' "$yml" | grep -c 'version:') -eq 0 ]]
    then
	echo "Not encrypted: $yml"
	__ymldec="$yml"
    else
	sops_config
	__ymldec=$(sed -e "s/\\.yaml$/${DEC_SUFFIX}/" <<<"$yml")
	if [[ -e $__ymldec && $__ymldec -nt $yml ]]
	then
	    echo "$__ymldec is newer than $yml"
	else
	    sops -d "$yml" > "$__ymldec"
	    __decrypted=1
	fi
    fi
    # if a return variable was specified, return decrypted file
    if [[ $# -ge 2 ]]
    then
	eval $2="'$__ymldec'"
    fi
    # if a return variable was specified, return if the file was decrypted on-the-fly
    if [[ $# -ge 3 ]]
    then
	eval $3="'$__decrypted'"
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

view_helper() {
    local yml="$1"
    [[ -e "$yml" ]] || (echo "File does not exist: $yml" && exit 1)
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
    [[ -e "$yml" ]] || (echo "File does not exist: $yml" && exit 1)
    sops_config
    exec sops "$yml" < /dev/tty
}

edit() {
    local yml="$1"
    edit_helper "$yml"
}

install_wrapper() {
    if is_help "$1"
    then
	install_usage
	return
    fi
    local options='n:f:'
    local longoptions='ca-file:,cert-file:,dep-up,devel,dry-run,key-file:,keyring:,name:,name-template:,namespace:,no-hooks,replace,repo:,set:,timeout:,tls,tls-ca-cert:,tls-cert:,tls-key:,tls-verify,values:,verify,version:,wait,debug,home:,kube-context:,tiller-connection-timeout:,tiller-namespace:'
    local parsed=$(getopt --options=$options --longoptions=$longoptions --name 'helm install' -- "$@")
    if [[ $? -ne 0 ]]
    then
	# e.g. $? == 1
	#  then getopt has complained about wrong arguments to stdout
	exit 2
    fi

    local -a allargs decfiles=()
    eval allargs=("$parsed")
    local i=0 yml ymldec decrypted
    while [[ $i -lt ${#allargs[@]} ]]
    do
	case "${allargs[$i]}" in
            -f|--values)
		i=$((i+1))
		yml="${allargs[$i]}"
		if [[ $yml =~ ^(.*/)?secrets(\.[^.]+)\.yaml$ ]]
		then
		    decrypt_helper $yml ymldec decrypted
		    allargs[$i]="$ymldec"
		    if [[ $decrypted -eq 1 ]]
		    then
			decfiles+=( $ymldec )
		    fi
		fi
		;;
	    *)
		;;
	esac
	i=$((i+1))
    done

    # expecting to find ("--" "chart") at end of parsed args
    if [[ ${allargs[-2]} != '--' ]]
    then
	echo "Expecting chart as argument"
	exit 4
    fi

    # re-order args and run helm command
    local -a args=("${allargs[-1]}")
    unset allargs[-1]
    unset allargs[-1]
    allargs=("${args[@]}" "${allargs[@]}")
    helm install "${allargs[@]}"

    # cleanup on-the-fly decrypted files
    if [[ ${#decfiles[@]} -gt 0 ]]
    then
	rm -v "${decfiles[@]}"
    fi
}

upgrade_wrapper() {
    if is_help "$1"
    then
	upgrade_usage
	return
    fi
    local options='if:'
    local longoptions='ca-file:,cert-file:,devel,dry-run,install,key-file:,keyring:,namespace:,no-hooks,recreate-pods,repo:,reset-values,reuse-values,set:,timeout:,tls,tls-ca-cert:,tls-cert:,tls-key:,tls-verify,values:,verify,version:,wait,debug,home:,kube-context:,tiller-connection-timeout:,tiller-namespace:'
    local parsed=$(getopt --options=$options --longoptions=$longoptions --name 'helm upgrade' -- "$@")
    if [[ $? -ne 0 ]]
    then
	# e.g. $? == 1
	#  then getopt has complained about wrong arguments to stdout
	exit 2
    fi

    local -a allargs decfiles=()
    eval allargs=("$parsed")
    local i=0 yml ymldec decrypted
    while [[ $i -lt ${#allargs[@]} ]]
    do
	case "${allargs[$i]}" in
            -f|--values)
		i=$((i+1))
		yml="${allargs[$i]}"
		if [[ $yml =~ ^(.*/)?secrets(\.[^.]+)\.yaml$ ]]
		then
		    decrypt_helper $yml ymldec decrypted
		    allargs[$i]="$ymldec"
		    if [[ $decrypted -eq 1 ]]
		    then
			decfiles+=( $ymldec )
		    fi
		fi
		;;
	esac
	i=$((i+1))
    done

    # expecting to find ("--" "release" "chart") at end of parsed args
    if [[ ${allargs[-3]} != '--' ]]
    then
	echo "Expecting release and chart as arguments"
	exit 4
    fi

    # re-order args and run helm command
    local -a args=("${allargs[-2]}" "${allargs[-1]}")
    unset allargs[-1]
    unset allargs[-1]
    unset allargs[-1]
    allargs=("${args[@]}" "${allargs[@]}")
    helm upgrade "${allargs[@]}"

    # cleanup on-the-fly decrypted files
    if [[ ${#decfiles[@]} -gt 0 ]]
    then
	rm -v "${decfiles[@]}"
    fi
}

if [[ $# -lt 1 ]]
then
    usage
    exit 1
fi

case "${1:-"help"}" in
    "enc"):
	  if [[ $# -lt 2 ]]
	  then
	      enc_usage
	      echo "Error: Chart package required."
	      exit 1
	  fi
	  enc "$2"
	  shift
	  ;;
    "dec"):
	  if [[ $# -lt 2 ]]
	  then
	      dec_usage
	      echo "Error: Chart package required."
	      exit 1
	  fi
	  dec "$2"
	  ;;
    "clean"):
	    if [[ $# -lt 2 ]]
	    then
		clean_usage
		echo "Error: Chart package required."
		exit 1
	    fi
	    clean "$2"
	    ;;
    "view"):
	   if [[ $# -lt 2 ]]
	   then
	       view_usage
	       echo "Error: Chart package required."
	       exit 1
	   fi
	   view "$2"
	   ;;
    "edit"):
	   if [[ $# -lt 2 ]]
	   then
	       edit_usage
	       echo "Error: Chart package required."
	       exit 1
	   fi
	   edit "$2"
	   shift
	   ;;
    "install"):
	      if [[ $# -lt 2 ]]
	      then
		  install_usage
		  echo "Error: helm install parameters required."
		  exit 1
	      fi
	      shift
	      install_wrapper "$@"
	      ;;
    "upgrade"):
	      if [[ $# -lt 2 ]]
	      then
		  upgrade_usage
		  echo "Error: helm upgrade parameters required."
		  exit 1
	      fi
	      shift
	      upgrade_wrapper "$@"
	      ;;
    "--help"|"help"|"-h")
	usage
	;;
    *)
	usage
	exit 1
	;;
esac

exit 0
