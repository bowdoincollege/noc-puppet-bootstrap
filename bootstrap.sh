#!/bin/bash
#
# bootstrap a new puppet server
#
# this is not entirely automated
# as there are manual steps related to ssh and eyaml keys
#
# jlavoie@bowdoin.edu Tue 30 Mar 2021

set -e

PATH="$PATH:/opt/puppetlabs/bin"
REMOTE="git@git.bowdoin.edu:/noc/puppet"
MODPATH=/root/bootstrap/modules
source /etc/os-release

echo "Purging old puppet agent..."
if [ "$(dpkg-query --show --showformat='${db:Status-Status}\n' puppet)" == "installed" ] ; then
  DEBIAN_FRONTEND=noninteractive apt-get purge -yq puppet
  DEBIAN_FRONTEND=noninteractive apt-get --purge -yq autoremove
fi

echo "Installing puppetserver..."
RELEASE="puppet6-release"
if [ "$(dpkg-query --show --showformat='${db:Status-Status}\n' $RELEASE)" != "installed" ] ; then
  wget https://apt.puppet.com/${RELEASE}-${VERSION_CODENAME}.deb
  dpkg -i ${RELEASE}-${VERSION_CODENAME}.deb
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -yq puppetserver
fi

echo "Installing any additional packages..."
for package in git ruby ; do
  if [ "$(dpkg-query --show --showformat='${db:Status-Status}\n' $package)" != "installed" ] ; then
    DEBIAN_FRONTEND=noninteractive apt-get install -yq $package
  fi
done

echo "Setting puppet user shell"
chsh -s /bin/bash puppet

# generate deploy key
SSHDIR=~puppet/.ssh
KEYFILE="${SSHDIR}/r10k"
if [ ! -d ${SSHDIR} ] ; then
  echo "Creating ${SSHDIR}"
  mkdir -p ${SSHDIR}
  chown puppet:puppet $SSHDIR
  chmod 700 ${SSHDIR}
fi
[[ $REMOTE =~ @([^/:]+)[/:] ]] && HOST="${BASH_REMATCH[1]}"
HOSTS="$HOST ${HOST%%.*}"
if [ -z "$HOST" ] ; then
  echo "Cannot parse host from remote, use 'git@git.example.com:/org/puppet' format.  Exiting."
  exit 1
fi
KNOWN_HOSTS="${SSHDIR}/known_hosts"
if [ ! -f $KNOWN_HOSTS ] || ! diff -q \
             <(sort <(ssh-keyscan $HOSTS 2>/dev/null) $KNOWN_HOSTS | uniq) \
             <(sort $KNOWN_HOSTS /dev/null | uniq) ; then
  echo "Adding host keys for $HOST to known_hosts..."
  ssh-keyscan $HOSTS >> "${SSHDIR}/known_hosts"
  chown puppet:puppet "${SSHDIR}/known_hosts"
fi

echo "Generating r10k ssh key..."
if [ -r "${KEYFILE}.pub" ] ; then
  echo "Key exists, checking..."
  ssh-keygen -l -f "${KEYFILE}.pub" || (echo "Invalid pubkey ${KEYFILE}.pub." >&2; exit 1)
else
  ssh-keygen -q -N '' -t rsa -b 4096 -C r10k -f ${KEYFILE}
  chown puppet:puppet "$KEYFILE" "${KEYFILE}.pub"
  chmod 600 "$KEYFILE"
  chmod 644 "${KEYFILE}.pub"
fi

SSH_CONFIG="${SSHDIR}/config"
for host in $HOSTS ; do
  if [ ! -f $SSH_CONFIG ] || ! grep -qi "user git$" <(ssh -F $SSH_CONFIG -G $host) ; then
    echo "Adding key to ${SSH_CONFIG} for $host..."
    cat >> "$SSH_CONFIG" <<EOM
Host $host
  HostName $HOST
  User git
  IdentityFile $KEYFILE
EOM
  chown puppet:puppet $SSH_CONFIG
  chmod 600 $SSH_CONFIG
  fi
done

echo "Give the following pubkey RO access to the repo, then hit <enter>."
cat "${KEYFILE}.pub"
read

EYAML_DIR="/etc/puppetlabs/puppet/keys"
if [ ! -d "$EYAML_DIR" ] ; then
  mkdir "$EYAML_DIR"
  chown puppet:puppet "$EYAML_DIR"
fi
if [ ! -r "${EYAML_DIR}/public_key.pkcs7.pem" ] ; then
  echo "Install eyaml keys in ${EYAML_DIR}, then hit <enter>."
  read
  chown puppet:puppet "${EYAML_DIR}/public_key.pkcs7.pem"
  chmod 644 "${EYAML_DIR}/public_key.pkcs7.pem"
  chown puppet:puppet "${EYAML_DIR}/private_key.pkcs7.pem"
  chmod 600 "${EYAML_DIR}/private_key.pkcs7.pem"
fi

echo "Installing puppet bootstrap modules in $MODPATH..."
puppet module install --modulepath "$MODPATH" puppet-hiera --version 4.0.0
puppet module install --modulepath "$MODPATH" puppet-r10k --version 9.0.0

echo "Initial puppet apply..."
FACTER_remote="$REMOTE" puppet apply --modulepath="$MODPATH" ./puppetserver.pp 

echo "Complete.  Now run the puppet agent against this host and restart the puppetserver."
