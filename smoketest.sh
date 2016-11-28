#!/usr/local/bin/bash
#
# This is a simple smoketest used to test an openstack deployment in PeZ.
# joey <jmcdonald@pivotal.io>

# Set this to your floating IP network in pez
NET_EXTERNAL='net04_ext'
PCF_NET='pcf-net'
MYVM='smoketest-rpub'
ROUTER='rpub'
SECGRP='pcf-admin'

function create_cirros() {

  echo -n "Checking for Cirros: "
  nova image-list | grep cirros | grep -q ACTIVE
  if [ $? != 0 ]; then
    echo "Installing"
    FILE='cirros-0.3.4-x86_64-disk.img'
    URL="http://download.cirros-cloud.net/0.3.4/$FILE"
    if [ ! -e images/$FILE ]; then
       wget $URL
    fi

    glance image-create --file $FILE --name 'cirros' \
      --disk-format qcow2 --container-format bare --progress
  else
    echo "Ok"
  fi
}

function create_xenial() {

  echo -n "Checking for Ubuntu Xenial: "
  glance image-list | grep ubuntu-xenial | grep -q ACTIVE
  if [ $? != 0 ]; then
    echo "Installing"
    FILE='xenial-server-cloudimg-amd64-disk1.img'
    URL="https://cloud-images.ubuntu.com/xenial/current/$FILE"
    if [ ! -e images/$FILE ]; then
       wget $URL
    fi
    glance image-create --file $FILE --name \
      'ubuntu-xenial' --disk-format qcow2 --container-format bare --progress
  else
    echo "Ok"
  fi
}

function create_networks() {

  echo -n "Checking for tenant networks: "
  neutron net-list | grep -q $PCF_NET
  if [ $? != 0 ]; then
    echo "Installing."
    neutron net-create $PCF_NET
    neutron subnet-create $PCF_NET 172.16.0.0/23 --name ${PCF_NET}-subnet \
      --dns-nameservers list=true 10.65.248.10 10.65.248.11
  else
    echo "Ok"
  fi
}

function create_secgroup() {

   echo -n "Checking for admin security group: "
   neutron security-group-list |grep -q $SECGRP
   if [ $? != 0 ]; then
     echo "Installing."
     # Create the admin group
     neutron security-group-create $SECGRP &> /dev/null
     # Allow ssh
     neutron security-group-rule-create --direction ingress --ethertype IPv4 \
         --protocol tcp --port-range-min 22 --port-range-max 22 $SECGRP &> /dev/null
     # Allow http
     neutron security-group-rule-create --direction ingress --ethertype IPv4 \
         --protocol tcp --port-range-min 80 --port-range-max 80 $SECGRP &> /dev/null
     # Allow 443
     neutron security-group-rule-create --direction ingress --ethertype IPv4 \
         --protocol tcp --port-range-min 443 --port-range-max 443 $SECGRP &> /dev/null
     # Allow ICMP
     neutron security-group-rule-create --direction ingress --ethertype IPv4 \
         --protocol icmp $SECGRP &> /dev/null
   else
     echo "Ok"
   fi
}


function create_router() {

  echo -n "Checking for network router: "
  neutron router-list | grep -q $ROUTER
  if [ $? != 0 ]; then
    echo "Installing."
    neutron router-create $ROUTER
    neutron router-gateway-set $ROUTER $NET_EXTERNAL
    neutron router-interface-add $ROUTER ${PCF_NET}-subnet
  else
    echo "Ok"
  fi
}

function create_ssh_key() {

   echo -n "Checking crypto keys: "
   if [ ! -f ~/.ssh/pcf_id_rsa.pub ]; then
      rm -f ~/.ssh/pcf_id_id_rsa*
      echo "Installing"
      ssh-keygen -N '' -f ~/.ssh/pcf_id_rsa 
      chmod 600 ~/.ssh/pcf_id_rsa
      nova keypair-add --pub-key ~/.ssh/pcf_id_rsa.pub pcf-key 
   else
      echo "Ok"
   fi
}

function boot_instance() {

  echo -n "Checking for $MYVM instance: "
  nova list | grep -q $MYVM
  if [ $? != 0 ]; then
    echo "Installing."
    nova boot $MYVM \
      --image $(glance image-list|grep ubuntu-xenial |awk '{print $2}') \
      --flavor $(nova flavor-list | grep m1.medium |  awk '{print $2}') \
      --nic net-id=$(neutron net-list | grep $PCF_NET | awk '{print $2}') \
      --key-name pcf-key \
      --security-groups $SECGRP &> /tmp/nova_boot.txt
  else
    echo "Ok"
  fi
}

function wait_for_running() {

   echo -n "Waiting for VM 'Running' status: "
   sleep 5

   # If we don't get this far, boot failure occured.
   nova list | grep -q $MYVM
   if [ $? -ne 0 ]; then
      echo "Failed to boot VM"
      exit 255
   fi

   for i in {1..30}; do
      nova list | grep $MYVM | grep -q ACTIVE
      if [ $? != 0 ]; then
         sleep 5
      else
         echo "Success"
         return
      fi
   done
   echo "Failed."
   exit 255
}

function assign_floating_ip() {

  echo -n "Associating Floating IP: "
  # Get a floating IP and assign it to our VM
  ID=$(neutron floatingip-create $NET_EXTERNAL | grep -w 'id'|awk '{print $4}')
  IP=$(nova show $MYVM |perl -lane 'print $1 if (/(172.16.*?)\s/)')
  PORT=$(neutron port-list |grep $IP | awk '{print $2}')
  neutron floatingip-associate $ID $PORT &>> /tmp/nova_boot.txt
  if [ $? != 0 ]; then
    echo "Failed"
  else
    echo "Ok"
  fi
}

function clean_up() {

   uuid_regexp='[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}'
   ip_regexp='\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}'
   floating_ip=$(nova list | perl -lane "print \$1 if /\s($ip_regexp)\s/")

   for uuid in `openstack server list |grep $MYVM |awk '{print $2}'`
   do
      nova delete $uuid
   done

   sleep 5

   for float in `neutron floatingip-list | grep $floating_ip \
      | perl -lane "print $1 if /\s($uuid_regexp)\s/" | awk '{print $2}'`
   do
      neutron floatingip-delete $float
   done

   for router in `neutron router-list | grep $ROUTER | awk '{print $2}'`
   do
     for subnet in `neutron router-port-list ${router} -c fixed_ips -f csv | egrep -o '[0-9a-z\-]{36}'`
       do
         neutron router-interface-delete ${router} ${subnet}
       done
     neutron router-gateway-clear ${router}
     neutron router-delete ${router}
   done

   for net in `neutron net-list|grep $PCF_NET |awk '{print $2}'`
   do
      neutron net-delete $net
   done

   for uuid in `neutron security-group-list | grep $SECGRP | awk '{print $2}'`
   do
      neutron security-group-delete $uuid
   done
   
   nova keypair-delete pcf-key 
   rm -f ~/.ssh/pcf_id_rsa* 
}

function start() {
   create_xenial
   create_networks
   create_router
   create_ssh_key
   create_secgroup
   boot_instance
   wait_for_running
   assign_floating_ip
}

function nuke_everything() {

   function purge_port() {
       for port in `neutron port-list -c id | egrep -v '\-\-|id' | awk '{print $2}'`
       do
           neutron port-delete ${port}
       done
   }
   function purge_router() {
       for router in `neutron router-list -c id | egrep -v '\-\-|id' | awk '{print $2}'`
       do
           for subnet in `neutron router-port-list ${router} -c fixed_ips -f csv | egrep -o '[0-9a-z\-]{36}'`
           do
               neutron router-interface-delete ${router} ${subnet} &> /dev/null
           done
           neutron router-gateway-clear ${router}
           neutron router-delete ${router}
       done
   }

   function purge_subnet() {
       for subnet in `neutron subnet-list -c id | egrep -v '\-\-|id' | awk '{print $2}'`
       do
           neutron subnet-delete ${subnet}
       done
   }

   function purge_net() {
       for net in `neutron net-list -c id | egrep -v '\-\-|id' | awk '{print $2}'`
       do
           neutron net-delete ${net}
       done
   }

   function purge_secgroup() {
       for secgroup in `nova secgroup-list|grep ssh|awk '{print $2}'`
       do
           neutron security-group-delete ${secgroup}
       done
   }

   function purge_floaters() {
      for floater in `neutron floatingip-list -c id | egrep -v '\-\-|id' | egrep -o '[0-9a-z\-]{36}'`
         do
            neutron floatingip-delete ${floater}
         done
   }


   function purge_instances() {
      echo -n "Stopping smoketest instances: "
      for inst in `nova list |grep $MYVM| egrep -o '[0-9a-z\-]{36}' | egrep -v '\-\-|id'`
         do
            nova delete ${inst} &> /dev/null
         done
      sleep 3;
      echo "Ok"
   }

   function delete_keys() {

      echo -n "Removing ssh keys: "
      nova keypair-delete pcf-key &> /dev/null
      rm -f ~/.ssh/pcf_id_rsa* &> /dev/null
      echo "Ok"
   }

   # Stop Instances
   purge_instances
   purge_floaters
   purge_router
   purge_port
   purge_subnet
   purge_net
   purge_secgroup
   delete_keys

}

case "$1" in
    start)
        start
        ;;
    stop)
        clean_up
        ;;
    *)
        echo $"Usage: $0 {start|stop}"
        RETVAL=3
esac
