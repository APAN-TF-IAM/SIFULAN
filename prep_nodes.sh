# /bin/bash

# This script prepares a server for inclusion in a Kuberneties cluster. It will
# perform the following tasks:
#    * Create a user the cluster will use (default "ifirexman") -u to override
#    * Create an ssh key pair (controller server only) -c
#    * Create a set of scripts to run on each member of the cluster
#
version="0.0.1"
cluster_user="ifirexman"
cluster_nodes="./cluster.members"
cluster_scripts="./cluster"
create_keypair=0

# help function
help()
{
    # Display Help
    echo "Usage:"
    echo " prepare [options]... -f <file>... -d <dir>..."
    echo
    echo "Initial k9s server prepartion"
    echo
    echo "Options:"
    echo " -c    Create an ssh key pair (controller server)"
    echo " -u    Set the cluser username default=ifirexman"
    echo " -f    Name of file containing the list of cluster members [cluster.members]"
    echo " -d    Path where cluster member scripts are written [./cluster]"

    echo
    echo " -h    display this help"
    echo " -V    display version"
}

create_user()
{
  echo "Attempt to create user ${cluster_user}"
 
  useradd ${cluster_user} 

  status=$?

  if [ $status -eq 1 ]; then
    echo "Aborting: Unable to create user ${cluster_user}"
    exit 1
  fi
}

create_keypair()
{
  echo "Create Key Pair for user ${cluster_user}"

  sudo -u ${cluster_user} ssh-keygen -t ecdsa 

  status=$?

  if [ $status -eq 1 ]; then
    create_user
    if [ $status -ne 9 ]; then
      sudo -u ${cluster_user} ssh-keygen -t ecdsa 
    fi
  fi
}

docker_setup()
{
    echo "# Setup Docker Engine"  >> $out_file
    echo "yum remove -y docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-engine" >> $out_file
    echo "yum install -y yum-utils" >> $out_file
    echo "yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo"  >> $out_file
    echo "yum install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin" >> $out_file
    echo "systemctl start docker && systemctl enable docker" >> $out_file
    echo "systemctl start containerd && systemctl enable containerd" >> $out_file
    echo "usermod -aG docker ${cluster_user}" >> $out_file
    echo "" >> $out_file
}

prep_node()
{
    echo "# Setup the Cluster Account" >> $out_file
    echo "useradd ${cluster_user}" >> $out_file
    echo "mkdir -p /home/${cluster_user}/.ssh" >> $out_file
    echo "chown ${cluster_user}.${cluster_user} /home/${cluster_user}/.ssh" >> $out_file
    echo "chmod 0700 /home/${cluster_user}/.ssh" >> $out_file
    echo ""  >> $out_file

    echo "# Authorize the manger's key" >> $out_file
    echo "cat <<EOT >> /home/${cluster_user}/.ssh/authorized_keys" >> $out_file
    cat /home/${cluster_user}/.ssh/id_ecdsa.pub >> $out_file
    echo "EOT" >> $out_file
    echo "chown ${cluster_user}.${cluster_user} /home/${cluster_user}/.ssh/authorized_keys" >> $out_file
    echo "chmod 0700 /home/${cluster_user}/.ssh/authorized_keys" >> $out_file
    echo "" >> $out_file

    docker_setup

    echo "# Disable swap" >> $out_file
    echo "sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab" >> $out_file
    echo "swapoff -a" >> $out_file
    echo "" >> $out_file

    echo "# Disable Firewall" >> $out_file
    echo "systemctl stop firewalld" >> $out_file
    echo "systemctl disable firewalld" >> $out_file
    echo "" >>  $out_file

    echo "# Modify bridge adapter settings" >> $out_file
    echo "modprobe br_netfilter" >> $out_file
    echo "cat <<EOT > /etc/sysctl.d/kubernetes.conf" >> $out_file
    echo "net.bridge.bridge-nf-call-ip6tables = 1" >> $out_file
    echo "net.bridge.bridge-nf-call-iptables = 1" >> $out_file
    echo "net.ipv4.ip_forward = 1" >> $out_file
    echo "EOT" >> $out_file
    echo "" >> $out_file

    echo "# Disable Extra NetworkManager Config" >> $out_file
    echo "systemctl disable nm-cloud-setup.service nm-cloud-setup.timer" >> $out_file
    echo "echo" >> $out_file
    echo "echo 'Time to reboot $node_name'" >> $out_file
    echo "echo 'Once rebooted server $node_name will be prepared to join the cluster'" >> $out_file

}

login_node ()
{
    docker_setup

    echo "# Install git" >> $out_file
    echo "yum install -y git" >> $out_file
    echo "" >> $out_file

    echo "# Install kubectl" >> $out_file
    echo 'curl -Lo kubectl "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"' >> $out_file
    echo "chmod +x kubectl" >> $out_file
    echo "mv kubectl /usr/local/bin" >> $out_file
    echo "" >> $out_file

    echo "# Install kubectx and kubens" >> $out_file
    echo "git clone https://github.com/ahmetb/kubectx /opt/kubectx" >> $out_file
    echo "ln -s /opt/kubectx/kubectx /usr/local/bin/kubectx" >> $out_file
    echo "ln -s /opt/kubectx/kubens /usr/local/bin/kubens" >> $out_file
    echo "" >> $out_file
}


####################################################
# Main program

# Get the options

while getopts ":cu:f:d:hV" option; do
  case "${option}" in
    h)
      help
      exit 0
      ;;
    V)
     echo "prepare version: ${version}"
     echo
     exit 0
     ;;
    c)
     create_keypair=1
     ;;
    u)
     cluster_user="${OPTARG}"
     ;;
    f)
     echo "Set the cluster nodes file"
     cluster_nodes="${OPTARG}"
     ;;
    d)
     echo "Set the output directory"
     cluster_scripts="${OPTARG}"
     ;;
   esac
done

if [ $USER != "root" -a $USER != $cluster_user ]; then
  echo "Not running as root or the user ${cluster_user}"
  exit 1
fi

if [[ $create_keypair -eq 1 ]]
then
  create_keypair
else
  echo "Prepare cluster using:"
  echo "  Cluster User:    ${cluster_user}"
  echo "  Cluster nodes:   ${cluster_nodes}"
  echo "  Cluster scripts: ${cluster_scripts}"

  if [ ! -f "${cluster_nodes}" ]; then
    echo "Error: Cluster Nodes file '${cluster_nodes}' does not exists. Existing"
    echo
    exit -1
  fi

  if [ ! -d "${cluster_scripts}" ]; then
    echo "Error: Cluster scrtipts directory '${cluster_scripts}' does not exists. Existing"
    echo
    exit -1
  fi
  
  node_type=""

  while read -r node_name 
  do
    if [[ ! "$node_name" = "" && ! "$node_name" = \#* ]] ; then

      if [[ "$node_name" = *: ]] ; then
        node_type=$node_name
      else

        if [[ "$node_type" = "" ]] ; then
          echo "Unable to process $node_name, type unknown"
        else
          echo "Process $node_name of $node_type"
          out_file=${cluster_scripts}/$node_name

          echo "# /bin/bash" > $out_file
      
          echo "#" >> $out_file
      
          echo "# $node_name is a $node_type server" >> $out_file

          echo "" >> $out_file

          echo "echo" >> $out_file

          if [[ "$node_type" == "login:" ]] ; then
            login_node
          else
            prep_node
          fi
        fi
      fi
    fi

  done < "${cluster_nodes}"
fi
